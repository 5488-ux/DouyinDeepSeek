#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSMessageSnapshot : NSObject
@property (nonatomic, copy) NSString *messageID;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) BOOL outgoing;
@property (nonatomic, assign) NSTimeInterval timestamp;
@end

@interface DSConversationSnapshot : NSObject
@property (nonatomic, copy) NSString *conversationID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSArray<DSMessageSnapshot *> *messages;
@property (nonatomic, weak, nullable) id controller;
@property (nonatomic, strong, nullable) id conversationObject;
@end

typedef void (^DSSendCompletion)(BOOL success, NSError * _Nullable error);

@interface DSRuntimeBridge : NSObject

+ (instancetype)shared;
- (nullable DSConversationSnapshot *)captureMessageController:(id)controller;
- (void)trackMessageController:(id)controller;
- (void)trackFriendModel:(id)friendModel;
- (NSArray<DSConversationSnapshot *> *)knownConversations;
- (nullable DSConversationSnapshot *)conversationForID:(NSString *)conversationID;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)apiMessagesForConversation:(DSConversationSnapshot *)conversation;
- (void)sendText:(NSString *)text toConversation:(DSConversationSnapshot *)conversation completion:(DSSendCompletion)completion;
- (NSString *)compatibilitySummary;

@end

NS_ASSUME_NONNULL_END

