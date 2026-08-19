#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DSDeepSeekCompletion)(NSString * _Nullable reply, NSError * _Nullable error);

@interface DSDeepSeekClient : NSObject

+ (instancetype)shared;
- (void)testConnection:(DSDeepSeekCompletion)completion;
- (void)generateReplyWithMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                   conversationID:(nullable NSString *)conversationID
                        completion:(DSDeepSeekCompletion)completion;

@end

NS_ASSUME_NONNULL_END

