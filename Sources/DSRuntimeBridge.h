#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DSMessageDirection) {
    DSMessageDirectionUnknown = 0,
    DSMessageDirectionIncoming,
    DSMessageDirectionOutgoing,
};

@interface DSMessageSnapshot : NSObject
@property (nonatomic, copy) NSString *messageID;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *senderID;
@property (nonatomic, copy) NSString *senderName;
@property (nonatomic, assign) DSMessageDirection direction;
@property (nonatomic, assign) NSTimeInterval timestamp;
@end

@interface DSConversationSnapshot : NSObject
@property (nonatomic, copy) NSString *conversationID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSArray<DSMessageSnapshot *> *messages;
@property (nonatomic, weak, nullable) id controller;
@property (nonatomic, strong, nullable) id conversationObject;
@property (nonatomic, assign) BOOL directConversation;
@property (nonatomic, assign) BOOL groupConversation;
@property (nonatomic, assign) BOOL historyHydrated;
@end

typedef void (^DSSendCompletion)(BOOL success, NSError * _Nullable error);
typedef void (^DSHydrationCompletion)(DSConversationSnapshot * _Nullable conversation, NSError * _Nullable error);

@interface DSRuntimeBridge : NSObject

+ (instancetype)shared;
- (nullable DSConversationSnapshot *)captureMessageController:(id)controller;
- (NSArray<DSConversationSnapshot *> *)ingestRawMessages:(NSArray *)rawMessages
                                  belongingConversationMap:(nullable NSDictionary *)conversationMap;
- (void)trackMessageController:(id)controller;
- (void)trackFriendModel:(id)friendModel;
- (NSArray<DSConversationSnapshot *> *)knownConversations;
- (nullable DSConversationSnapshot *)conversationForID:(NSString *)conversationID;
- (void)hydrateConversation:(DSConversationSnapshot *)conversation completion:(DSHydrationCompletion)completion;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)apiMessagesForConversation:(DSConversationSnapshot *)conversation;
- (void)sendText:(NSString *)text toConversation:(DSConversationSnapshot *)conversation completion:(DSSendCompletion)completion;
- (void)sendText:(NSString *)text
  toConversation:(DSConversationSnapshot *)conversation
      operationID:(NSString *)operationID
       completion:(DSSendCompletion)completion;
- (NSArray<NSDictionary<NSString *, id> *> *)aiSendRecords;
- (void)clearAISendRecords;
- (NSString *)compatibilitySummary;
- (NSString *)diagnosticReportForConversation:(nullable DSConversationSnapshot *)conversation;

@end

NS_ASSUME_NONNULL_END
