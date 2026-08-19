#import "DSDeepSeekClient.h"
#import "DSConfig.h"
#import <CommonCrypto/CommonDigest.h>

static NSString * const DSErrorDomain = @"com.codex.douyin.deepseek.api";

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

- (void)performRequestWithMessages:(NSArray<NSDictionary<NSString *,NSString *> *> *)messages
                    conversationID:(NSString *)conversationID
                         completion:(DSDeepSeekCompletion)completion {
    DSConfig *config = [DSConfig shared];
    NSString *apiKey = [config.apiKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!apiKey.length) {
        NSError *error = [NSError errorWithDomain:DSErrorDomain code:401 userInfo:@{NSLocalizedDescriptionKey: @"还没填写 DeepSeek API Key。"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }

    NSURL *url = [NSURL URLWithString:config.baseURL];
    if (!url) {
        NSError *error = [NSError errorWithDomain:DSErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"API 地址无效。"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }

    NSDictionary *body = @{
        @"model": config.model,
        @"messages": messages,
        @"stream": @NO,
        @"max_tokens": @(config.maxReplyTokens),
        @"temperature": @0.7,
        @"thinking": @{ @"type": config.thinkingEnabled ? @"enabled" : @"disabled" },
        @"user_id": [self safeUserIDForConversation:conversationID],
    };

    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!bodyData) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, jsonError); });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:45];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];

    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sessionConfig.timeoutIntervalForRequest = 45;
    sessionConfig.timeoutIntervalForResource = 60;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfig];

    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        if (networkError) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, networkError); });
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSError *parseError = nil;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError] : nil;

        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString *message = [json valueForKeyPath:@"error.message"];
            if (!message.length) message = [NSString stringWithFormat:@"DeepSeek 请求失败（HTTP %ld）。", (long)http.statusCode];
            NSError *error = [NSError errorWithDomain:DSErrorDomain code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: message}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }

        if (parseError) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, parseError); });
            return;
        }

        NSString *reply = [json valueForKeyPath:@"choices.0.message.content"];
        reply = [reply stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!reply.length) {
            NSError *error = [NSError errorWithDomain:DSErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey: @"DeepSeek 返回成功，但回复正文为空。"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ completion(reply, nil); });
    }] resume];
}

@end

