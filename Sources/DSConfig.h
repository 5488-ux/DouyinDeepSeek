#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSConfig : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy) NSString *model;
@property (nonatomic, copy) NSString *systemPrompt;
@property (nonatomic, assign) NSInteger contextLimit;
@property (nonatomic, assign) NSTimeInterval cooldown;
@property (nonatomic, assign) NSInteger maxReplyTokens;
@property (nonatomic, assign) BOOL thinkingEnabled;

@property (nonatomic, copy, nullable) NSString *apiKey;

@end

NS_ASSUME_NONNULL_END

