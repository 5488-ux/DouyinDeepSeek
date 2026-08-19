#import "DSDeepSeekClient.h"
#import "DSConfig.h"
#import <CommonCrypto/CommonDigest.h>

static NSString * const DSErrorDomain = @"com.codex.douyin.deepseek.api";

static NSString *DSTrimmedString(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : nil;
}

// DeepSeek 官方响应是字符串，部分兼容网关会返回文本分段数组。
static NSString *DSTextFromContentValue(id value) {
    NSString *direct = DSTrimmedString(value);
    if (direct.length) return direct;

    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id part in (NSArray *)value) {
            NSString *text = DSTextFromContentValue(part);
            if (text.length) [parts addObject:text];
        }
        return parts.count ? [parts componentsJoinedByString:@"\n"] : nil;
    }

    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = (NSDictionary *)value;
        for (NSString *key in @[@"text", @"value", @"content"]) {
            id candidate = dictionary[key];
            if (candidate && candidate != value) {
                NSString *text = DSTextFromContentValue(candidate);
                if (text.length) return text;
            }
        }
    }

    return nil;
}

@interface DSDeepSeekClient ()

- (void)performRequestWithMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                    conversationID:(NSString *)conversationID
                   thinkingEnabled:(BOOL)thinkingEnabled
                         maxTokens:(NSInteger)maxTokens
                   allowEmptyRetry:(BOOL)allowEmptyRetry
                         completion:(DSDeepSeekCompletion)completion;

@end

@implementation DSDeepSeekClient

+ (instancetype)shared {
    static DSDeepSeekClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ client = [[self alloc] init]; });
    return client;
}

- (void)testConnection:(DSDeepSeekCompletion)completion {
    NSArray *messages = @[
        @{ @"role": @"system", @"content": @"只输出“连接成功”四个字。" },
        @{ @"role": @"user", @"content": @"测试 DeepSeek API。" },
    ];
    [self performRequestWithMessages:messages conversationID:@"connection-test" completion:completion];
}

- (void)generateReplyWithMessages:(NSArray<NSDictionary<NSString *,NSString *> *> *)messages
                   conversationID:(NSString *)conversationID
                        completion:(DSDeepSeekCompletion)completion {
    DSConfig *config = [DSConfig shared];
    NSMutableArray *payload = [NSMutableArray arrayWithObject:@{
        @"role": @"system",
        @"content": config.systemPrompt,
    }];
    [payload addObjectsFromArray:messages];
    [self performRequestWithMessages:payload conversationID:conversationID completion:completion];
}

- (NSString *)safeUserIDForConversation:(NSString *)conversationID {
    NSString *source = conversationID.length ? conversationID : @"unknown";
    NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return [@"douyin_" stringByAppendingString:hex];
}

- (void)finishWithReply:(NSString *)reply
                  error:(NSError *)error
             completion:(DSDeepSeekCompletion)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(reply, error);
    });
}

- (void)performRequestWithMessages:(NSArray<NSDictionary<NSString *,NSString *> *> *)messages
                    conversationID:(NSString *)conversationID
                         completion:(DSDeepSeekCompletion)completion {
    DSConfig *config = [DSConfig shared];
    [self performRequestWithMessages:messages
                     conversationID:conversationID
                    thinkingEnabled:config.thinkingEnabled
                          maxTokens:config.maxReplyTokens
                    allowEmptyRetry:YES
                          completion:completion];
}

- (void)performRequestWithMessages:(NSArray<NSDictionary<NSString *,NSString *> *> *)messages
                    conversationID:(NSString *)conversationID
                   thinkingEnabled:(BOOL)thinkingEnabled
                         maxTokens:(NSInteger)maxTokens
                   allowEmptyRetry:(BOOL)allowEmptyRetry
                         completion:(DSDeepSeekCompletion)completion {
    DSConfig *config = [DSConfig shared];
    NSString *apiKey = [config.apiKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!apiKey.length) {
        NSError *error = [NSError errorWithDomain:DSErrorDomain code:401 userInfo:@{NSLocalizedDescriptionKey: @"还没填写 DeepSeek API Key。"}];
        [self finishWithReply:nil error:error completion:completion];
        return;
    }

    NSURL *url = [NSURL URLWithString:config.baseURL];
    if (!url || !url.scheme.length || !url.host.length) {
        NSError *error = [NSError errorWithDomain:DSErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"API 地址无效。"}];
        [self finishWithReply:nil error:error completion:completion];
        return;
    }

    NSInteger requestMaxTokens = thinkingEnabled ? MAX(maxTokens, 1024) : MAX(maxTokens, 32);
    NSMutableDictionary *body = [@{
        @"model": config.model,
        @"messages": messages,
        @"stream": @NO,
        @"max_tokens": @(requestMaxTokens),
        @"thinking": @{ @"type": thinkingEnabled ? @"enabled" : @"disabled" },
        @"user_id": [self safeUserIDForConversation:conversationID],
    } mutableCopy];
    if (!thinkingEnabled) body[@"temperature"] = @0.7;

    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!bodyData) {
        [self finishWithReply:nil error:jsonError completion:completion];
        return;
    }

    NSTimeInterval requestTimeout = thinkingEnabled ? 90 : 60;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:requestTimeout];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];

    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sessionConfig.timeoutIntervalForRequest = requestTimeout;
    sessionConfig.timeoutIntervalForResource = requestTimeout + 30;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfig];

    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        if (networkError) {
            [self finishWithReply:nil error:networkError completion:completion];
            return;
        }

        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSError *parseError = nil;
        id jsonObject = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError] : nil;
        NSDictionary *json = [jsonObject isKindOfClass:NSDictionary.class] ? jsonObject : nil;

        if (!http) {
            NSError *error = [NSError errorWithDomain:DSErrorDomain code:-3 userInfo:@{NSLocalizedDescriptionKey: @"DeepSeek 没有返回有效的 HTTP 响应。"}];
            [self finishWithReply:nil error:error completion:completion];
            return;
        }

        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSDictionary *apiError = [json[@"error"] isKindOfClass:NSDictionary.class] ? json[@"error"] : nil;
            NSString *message = DSTrimmedString(apiError[@"message"]);
            if (!message.length) message = [NSString stringWithFormat:@"DeepSeek 请求失败（HTTP %ld）。", (long)http.statusCode];
            NSError *error = [NSError errorWithDomain:DSErrorDomain code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: message}];
            [self finishWithReply:nil error:error completion:completion];
            return;
        }

        if (parseError) {
            [self finishWithReply:nil error:parseError completion:completion];
            return;
        }
        if (!json) {
            NSError *error = [NSError errorWithDomain:DSErrorDomain code:-4 userInfo:@{NSLocalizedDescriptionKey: @"DeepSeek 返回了 200，但响应不是 JSON 对象。"}];
            [self finishWithReply:nil error:error completion:completion];
            return;
        }

        NSArray *choices = [json[@"choices"] isKindOfClass:NSArray.class] ? json[@"choices"] : nil;
        NSDictionary *choice = choices.count && [choices.firstObject isKindOfClass:NSDictionary.class] ? choices.firstObject : nil;
        NSDictionary *message = [choice[@"message"] isKindOfClass:NSDictionary.class] ? choice[@"message"] : nil;

        NSString *reply = DSTextFromContentValue(message[@"content"]);
        if (!reply.length) reply = DSTextFromContentValue(choice[@"text"]);
        if (!reply.length) reply = DSTextFromContentValue(json[@"output_text"]);
        if (reply.length) {
            [self finishWithReply:reply error:nil completion:completion];
            return;
        }

        NSString *reasoning = DSTextFromContentValue(message[@"reasoning_content"]);
        NSString *finishReason = DSTrimmedString(choice[@"finish_reason"]) ?: @"unknown";
        NSDictionary *usage = [json[@"usage"] isKindOfClass:NSDictionary.class] ? json[@"usage"] : nil;
        NSNumber *completionTokens = [usage[@"completion_tokens"] isKindOfClass:NSNumber.class] ? usage[@"completion_tokens"] : nil;

        // 思考过程可能先吃光 max_tokens。只自动重试一次，绝不把思考内容发给联系人。
        BOOL blockedByFilter = [finishReason isEqualToString:@"content_filter"];
        if (allowEmptyRetry && !blockedByFilter) {
            NSLog(@"[DouyinDeepSeek] empty content, retrying without thinking (finish=%@, reasoning=%@)", finishReason, reasoning.length ? @"yes" : @"no");
            [self performRequestWithMessages:messages
                             conversationID:conversationID
                            thinkingEnabled:NO
                                  maxTokens:MAX(maxTokens, 1024)
                            allowEmptyRetry:NO
                                  completion:completion];
            return;
        }

        NSMutableArray<NSString *> *details = [NSMutableArray arrayWithObject:[@"finish_reason=" stringByAppendingString:finishReason]];
        if (completionTokens) [details addObject:[NSString stringWithFormat:@"completion_tokens=%@", completionTokens]];
        [details addObject:[NSString stringWithFormat:@"reasoning_content=%@", reasoning.length ? @"有" : @"无"]];
        NSString *description = [NSString stringWithFormat:@"DeepSeek 返回 200，但 content 为空（%@）。%@",
                                 [details componentsJoinedByString:@"，"],
                                 blockedByFilter ? @"内容被模型过滤。" : @"已自动关闭思考模式重试一次，仍未得到正文。"];
        NSError *error = [NSError errorWithDomain:DSErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey: description}];
        [self finishWithReply:nil error:error completion:completion];
    }] resume];
}

@end
