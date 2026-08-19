#import "DSConfig.h"
#import <Security/Security.h>

static NSString * const DSDefaultsPrefix = @"DouyinDeepSeek.";
static NSString * const DSKeychainService = @"com.codex.douyin.deepseek";
static NSString * const DSKeychainAccount = @"api-key";

@implementation DSConfig

+ (instancetype)shared {
    static DSConfig *config;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        config = [[self alloc] init];
        [config registerDefaults];
    });
    return config;
}

- (void)registerDefaults {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        [DSDefaultsPrefix stringByAppendingString:@"enabled"]: @NO,
        [DSDefaultsPrefix stringByAppendingString:@"baseURL"]: @"https://api.deepseek.com/v1/chat/completions",
        [DSDefaultsPrefix stringByAppendingString:@"model"]: @"deepseek-v4-flash",
        [DSDefaultsPrefix stringByAppendingString:@"systemPrompt"]: @"你正在代替我回复抖音私信。请结合完整上下文自然、简洁地回答，保持我的口吻，不要提到自己是AI，不要编造上下文里没有的事实。只输出要发送的回复正文。",
        [DSDefaultsPrefix stringByAppendingString:@"contextLimit"]: @20,
        [DSDefaultsPrefix stringByAppendingString:@"cooldown"]: @15,
        [DSDefaultsPrefix stringByAppendingString:@"maxReplyTokens"]: @300,
        [DSDefaultsPrefix stringByAppendingString:@"thinkingEnabled"]: @NO,
    }];
}

- (id)valueForSetting:(NSString *)name {
    return [[NSUserDefaults standardUserDefaults] objectForKey:[DSDefaultsPrefix stringByAppendingString:name]];
}

- (void)setValue:(id)value forSetting:(NSString *)name {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:value forKey:[DSDefaultsPrefix stringByAppendingString:name]];
    [defaults synchronize];
}

- (BOOL)enabled { return [[self valueForSetting:@"enabled"] boolValue]; }
- (void)setEnabled:(BOOL)value { [self setValue:@(value) forSetting:@"enabled"]; }

- (NSString *)baseURL { return [self valueForSetting:@"baseURL"]; }
- (void)setBaseURL:(NSString *)value { [self setValue:value.length ? value : @"https://api.deepseek.com/v1/chat/completions" forSetting:@"baseURL"]; }

- (NSString *)model { return [self valueForSetting:@"model"]; }
- (void)setModel:(NSString *)value { [self setValue:value.length ? value : @"deepseek-v4-flash" forSetting:@"model"]; }

- (NSString *)systemPrompt { return [self valueForSetting:@"systemPrompt"]; }
- (void)setSystemPrompt:(NSString *)value { [self setValue:value.length ? value : @"请结合上下文自然回复，只输出回复正文。" forSetting:@"systemPrompt"]; }

- (NSInteger)contextLimit { return MAX(2, [[self valueForSetting:@"contextLimit"] integerValue]); }
- (void)setContextLimit:(NSInteger)value { [self setValue:@(MAX(2, MIN(100, value))) forSetting:@"contextLimit"]; }

- (NSTimeInterval)cooldown { return MAX(0, [[self valueForSetting:@"cooldown"] doubleValue]); }
- (void)setCooldown:(NSTimeInterval)value { [self setValue:@(MAX(0, MIN(3600, value))) forSetting:@"cooldown"]; }

- (NSInteger)maxReplyTokens { return MAX(32, [[self valueForSetting:@"maxReplyTokens"] integerValue]); }
- (void)setMaxReplyTokens:(NSInteger)value { [self setValue:@(MAX(32, MIN(4096, value))) forSetting:@"maxReplyTokens"]; }

- (BOOL)thinkingEnabled { return [[self valueForSetting:@"thinkingEnabled"] boolValue]; }
- (void)setThinkingEnabled:(BOOL)value { [self setValue:@(value) forSetting:@"thinkingEnabled"]; }

- (NSMutableDictionary *)keychainQuery {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: DSKeychainService,
        (__bridge id)kSecAttrAccount: DSKeychainAccount,
    } mutableCopy];
}

- (NSString *)apiKey {
    NSMutableDictionary *query = [self keychainQuery];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;

    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)setApiKey:(NSString *)apiKey {
    NSMutableDictionary *query = [self keychainQuery];
    SecItemDelete((__bridge CFDictionaryRef)query);

    if (!apiKey.length) return;
    query[(__bridge id)kSecValueData] = [apiKey dataUsingEncoding:NSUTF8StringEncoding];
    query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)query, NULL);
}

@end

