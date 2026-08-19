#import "DSRuntimeBridge.h"
#import "DSConfig.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const DSBridgeErrorDomain = @"com.codex.douyin.deepseek.bridge";

@implementation DSMessageSnapshot
@end

@implementation DSConversationSnapshot
@end

static id DSSafeValue(id object, NSArray<NSString *> *paths) {
    if (!object) return nil;
    for (NSString *path in paths) {
        @try {
            id value = [object valueForKeyPath:path];
            if (value && value != NSNull.null) return value;
        } @catch (__unused NSException *exception) {}

        SEL selector = NSSelectorFromString(path);
        if ([path rangeOfString:@"."].location == NSNotFound && [object respondsToSelector:selector]) {
            NSMethodSignature *signature = [object methodSignatureForSelector:selector];
            if (!signature || signature.numberOfArguments != 2 || signature.methodReturnLength == 0) continue;
            const char *returnType = signature.methodReturnType;
            if (returnType[0] != '@' && returnType[0] != '#') continue;
            id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id value = send(object, selector);
            if (value && value != NSNull.null) return value;
        }
    }
    return nil;
}

static NSString *DSStringValue(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

static NSString *DSTextValue(id value, NSInteger depth) {
    if (!value || value == NSNull.null || depth > 5) return nil;
    if ([value isKindOfClass:NSAttributedString.class]) value = [value string];
    if ([value isKindOfClass:NSData.class]) value = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];

    if ([value isKindOfClass:NSString.class]) {
        NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!text.length) return nil;
        if ([text hasPrefix:@"{"] || [text hasPrefix:@"["]) {
            NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *decoded = DSTextValue(json, depth + 1);
            if (decoded.length) return decoded;
        }
        return text;
    }

    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        for (NSString *key in @[@"text", @"contentText", @"content", @"messageText", @"msg_content", @"value"]) {
            NSString *text = DSTextValue(dictionary[key], depth + 1);
            if (text.length) return text;
        }
        return nil;
    }

    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            NSString *text = DSTextValue(item, depth + 1);
            if (text.length) [parts addObject:text];
        }
        return parts.count ? [parts componentsJoinedByString:@"\n"] : nil;
    }

    return nil;
}

static BOOL DSBoolValue(id object, NSArray<NSString *> *names, BOOL *found) {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) continue;
        NSMethodSignature *signature = [object methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != 2) continue;
        const char *returnType = signature.methodReturnType;
        if (strchr("BcCsSiIlLqQ", returnType[0]) == NULL) continue;
        BOOL (*send)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        if (found) *found = YES;
        return send(object, selector);
    }
    if (found) *found = NO;
    return NO;
}

static NSArray *DSArrayValue(id object, NSArray<NSString *> *paths) {
    id value = DSSafeValue(object, paths);
    if ([value isKindOfClass:NSArray.class]) return value;
    if ([value isKindOfClass:NSOrderedSet.class]) return [value array];
    if ([value isKindOfClass:NSSet.class]) return [value allObjects];
    return @[];
}

static id DSSharedInstanceForClass(Class targetClass) {
    if (!targetClass) return nil;
    for (NSString *name in @[@"sharedInstance", @"sharedManager", @"defaultManager", @"sharedUtility"]) {
        SEL selector = NSSelectorFromString(name);
        if (![targetClass respondsToSelector:selector]) continue;
        id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id instance = send(targetClass, selector);
        if (instance) return instance;
    }
    return nil;
}

@interface DSRuntimeBridge ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, DSConversationSnapshot *> *conversations;
@property (nonatomic, strong) NSHashTable *friendModels;
@property (nonatomic, strong) NSHashTable *messageControllers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *recentOutgoingTexts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *recentOutgoingDates;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@end

@implementation DSRuntimeBridge

+ (instancetype)shared {
    static DSRuntimeBridge *bridge;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ bridge = [[self alloc] initPrivate]; });
    return bridge;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _conversations = [NSMutableDictionary dictionary];
        _friendModels = [NSHashTable weakObjectsHashTable];
        _messageControllers = [NSHashTable weakObjectsHashTable];
        _recentOutgoingTexts = [NSMutableDictionary dictionary];
        _recentOutgoingDates = [NSMutableDictionary dictionary];
        _stateQueue = dispatch_queue_create("com.codex.douyin.deepseek.bridge", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)trackMessageController:(id)controller {
    if (!controller) return;
    @synchronized (self.messageControllers) {
        [self.messageControllers addObject:controller];
    }
}

- (void)trackFriendModel:(id)friendModel {
    if (!friendModel) return;
    @synchronized (self.friendModels) {
        [self.friendModels addObject:friendModel];
    }

    NSString *conversationID = [self conversationIDFromObject:friendModel];
    if (!conversationID.length) return;
    NSString *name = [self displayNameFromObject:friendModel] ?: conversationID;

    @synchronized (self.conversations) {
        DSConversationSnapshot *snapshot = self.conversations[conversationID];
        if (!snapshot) {
            snapshot = [[DSConversationSnapshot alloc] init];
            snapshot.conversationID = conversationID;
            snapshot.messages = @[];
            self.conversations[conversationID] = snapshot;
        }
        if (name.length) snapshot.displayName = name;
    }
}

- (NSString *)conversationIDFromObject:(id)object {
    return DSStringValue(DSSafeValue(object, @[
        @"conversationID", @"conversationId", @"conversation.identifier",
        @"conversation.conversationID", @"conversation.conversationId",
        @"msg_conversationID", @"belongingConversationIdentifier",
        @"iesMessage.conversationID", @"iesMessage.belongingConversationIdentifier"
    ]));
}

- (NSString *)displayNameFromObject:(id)object {
    NSString *name = DSStringValue(DSSafeValue(object, @[
        @"displayName", @"nickname", @"nickName", @"name", @"title",
        @"user.nickname", @"imUser.nickname", @"conversation.conversationName"
    ]));
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString *)messageTextFromObject:(id)object {
    NSArray<NSString *> *paths = @[
        @"contentText", @"text", @"messageText", @"getContent", @"content",
        @"msg_content", @"messageContent", @"rawContentDict",
        @"iesMessage.contentText", @"iesMessage.content", @"message.content",
        @"content.text", @"content.contentText"
    ];
    NSString *text = nil;
    for (NSString *path in paths) {
        text = DSTextValue(DSSafeValue(object, @[path]), 0);
        if (text.length) break;
    }
    if (!text.length) {
        id ext = DSSafeValue(object, @[@"localExt", @"ext", @"extra"]);
        text = DSTextValue(ext, 0);
    }
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString *)messageIDFromObject:(id)object fallback:(NSString *)fallback {
    NSString *messageID = DSStringValue(DSSafeValue(object, @[
        @"messageID", @"messageId", @"msg_id", @"serverMessageID", @"clientMessageID",
        @"identifier", @"compatibleIdentifier", @"uniqueID", @"uuid",
        @"iesMessage.messageID", @"iesMessage.messageId", @"iesMessage.identifier"
    ]));
    return messageID.length ? messageID : fallback;
}

- (BOOL)messageIsOutgoing:(id)object {
    BOOL found = NO;
    BOOL outgoing = DSBoolValue(object, @[@"sendFromMe", @"realSendFromMe", @"sendFromMeOpt", @"isSelf", @"isSendByMe", @"isMine", @"isSelfMessage", @"isFromMe"], &found);
    if (found) return outgoing;

    id wrappedMessage = DSSafeValue(object, @[@"iesMessage", @"message", @"timMessage"]);
    if (wrappedMessage && wrappedMessage != object) {
        outgoing = DSBoolValue(wrappedMessage, @[@"sendFromMe", @"realSendFromMe", @"sendFromMeOpt", @"isSelf", @"isSendByMe", @"isMine", @"isSelfMessage", @"isFromMe"], &found);
        if (found) return outgoing;
    }

    id numeric = DSSafeValue(object, @[
        @"msg_isSelf", @"senderIsSelf", @"isSender",
        @"iesMessage.msg_isSelf", @"iesMessage.senderIsSelf", @"iesMessage.isSender",
        @"message.msg_isSelf", @"message.senderIsSelf"
    ]);
    if ([numeric respondsToSelector:@selector(boolValue)]) return [numeric boolValue];

    NSString *senderID = DSStringValue(DSSafeValue(object, @[
        @"senderID", @"senderId", @"sender", @"fromUid", @"fromUserID", @"fromUserId", @"msg_sender",
        @"sender.uid", @"sender.userID", @"iesMessage.senderID", @"iesMessage.senderId",
        @"iesMessage.sender", @"iesMessage.fromUid", @"iesMessage.fromUserID", @"iesMessage.sender.uid"
    ]));
    id sdkInstance = nil;
    Class instancesClass = objc_getClass("TIMXSDKInstancesManager");
    SEL instanceSelector = NSSelectorFromString(@"iesim_TIMXSDKInstance");
    if ([instancesClass respondsToSelector:instanceSelector]) {
        sdkInstance = ((id (*)(id, SEL))objc_msgSend)(instancesClass, instanceSelector);
    }
    NSString *currentUserID = DSStringValue(DSSafeValue(sdkInstance, @[
        @"context.currentUserManager.currentAccountID", @"context.currentUserImp.userID",
        @"context.currentUserImp.uid", @"context.userCredential.userID",
        @"context.userCredential.uid", @"context.currentAccountID"
    ]));
    if (senderID.length && currentUserID.length) return [senderID isEqualToString:currentUserID];
    return NO;
}

- (NSTimeInterval)messageTimestamp:(id)object fallback:(NSTimeInterval)fallback {
    id value = DSSafeValue(object, @[@"createTime", @"modifiedCreateTime", @"createdAt", @"serverCreatedAt", @"timestamp", @"msg_createTime", @"serverTime", @"iesMessage.createTime"]);
    if ([value isKindOfClass:NSDate.class]) return [(NSDate *)value timeIntervalSince1970];
    if (![value respondsToSelector:@selector(doubleValue)]) return fallback;
    NSTimeInterval timestamp = [value doubleValue];
    if (timestamp > 1000000000000.0) timestamp /= 1000.0;
    return timestamp > 0 ? timestamp : fallback;
}

- (DSConversationSnapshot *)captureMessageController:(id)controller {
    if (!controller) return nil;
    [self trackMessageController:controller];

    id conversation = DSSafeValue(controller, @[@"msg_conversation", @"currentConversation", @"conversation", @"listViewModel.conversation", @"messageViewModel.conversation", @"viewModel.conversation"]);
    NSString *conversationID = [self conversationIDFromObject:controller];
    if (!conversationID.length) conversationID = [self conversationIDFromObject:conversation];

    NSArray *rawMessages = DSArrayValue(controller, @[
        @"msg_messages", @"messages", @"listViewModel.messages",
        @"messageViewModel.messages", @"viewModel.messages", @"messageList",
        @"dataSource.messages", @"messageViewModel.messageList"
    ]);
    if (!rawMessages.count) {
        rawMessages = DSArrayValue(conversation, @[@"messages", @"messageList", @"allMessages"]);
    }
    if (!conversationID.length && rawMessages.count) conversationID = [self conversationIDFromObject:rawMessages.lastObject];
    if (!conversationID.length) return nil;

    NSString *displayName = [self displayNameFromObject:controller];
    if (!displayName.length) displayName = [self displayNameFromObject:conversation];
    if (!displayName.length && [controller isKindOfClass:UIViewController.class]) {
        displayName = ((UIViewController *)controller).navigationItem.title ?: ((UIViewController *)controller).title;
    }
    if (!displayName.length) displayName = conversationID;

    NSMutableArray<DSMessageSnapshot *> *messages = [NSMutableArray array];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    [rawMessages enumerateObjectsUsingBlock:^(id raw, NSUInteger index, BOOL *stop) {
        NSString *text = [self messageTextFromObject:raw];
        if (!text.length) return;
        DSMessageSnapshot *message = [[DSMessageSnapshot alloc] init];
        message.text = text;
        message.outgoing = [self messageIsOutgoing:raw];
        message.timestamp = [self messageTimestamp:raw fallback:now + index / 1000.0];
        NSString *fallback = [NSString stringWithFormat:@"%@-%lu-%lu", conversationID, (unsigned long)index, (unsigned long)text.hash];
        message.messageID = [self messageIDFromObject:raw fallback:fallback];
        [messages addObject:message];
    }];

    [messages sortUsingComparator:^NSComparisonResult(DSMessageSnapshot *a, DSMessageSnapshot *b) {
        if (a.timestamp < b.timestamp) return NSOrderedAscending;
        if (a.timestamp > b.timestamp) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    DSConversationSnapshot *snapshot;
    @synchronized (self.conversations) {
        snapshot = self.conversations[conversationID] ?: [[DSConversationSnapshot alloc] init];
        snapshot.conversationID = conversationID;
        snapshot.displayName = displayName;
        snapshot.messages = messages;
        snapshot.controller = controller;
        if (conversation) snapshot.conversationObject = conversation;
        self.conversations[conversationID] = snapshot;
    }
    return snapshot;
}

- (id)conversationForID:(NSString *)conversationID inMap:(NSDictionary *)conversationMap {
    if (!conversationID.length || ![conversationMap isKindOfClass:NSDictionary.class]) return nil;
    id direct = conversationMap[conversationID];
    if (direct && direct != NSNull.null) return direct;

    for (id value in conversationMap.allValues) {
        if ([[self conversationIDFromObject:value] isEqualToString:conversationID]) return value;
    }
    return nil;
}

- (NSArray<DSConversationSnapshot *> *)ingestRawMessages:(NSArray *)rawMessages
                                  belongingConversationMap:(NSDictionary *)conversationMap {
    if (![rawMessages isKindOfClass:NSArray.class] || !rawMessages.count) return @[];

    NSMutableSet<NSString *> *changedConversationIDs = [NSMutableSet set];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    @synchronized (self.conversations) {
        [rawMessages enumerateObjectsUsingBlock:^(id raw, NSUInteger index, BOOL *stop) {
            NSString *conversationID = [self conversationIDFromObject:raw];
            if (!conversationID.length) return;

            NSString *text = [self messageTextFromObject:raw];
            if (!text.length) return;

            NSString *fallback = [NSString stringWithFormat:@"%@-push-%lu-%lu", conversationID, (unsigned long)index, (unsigned long)text.hash];
            NSString *messageID = [self messageIDFromObject:raw fallback:fallback];
            DSConversationSnapshot *snapshot = self.conversations[conversationID] ?: [[DSConversationSnapshot alloc] init];
            NSMutableArray<DSMessageSnapshot *> *messages = [snapshot.messages mutableCopy] ?: [NSMutableArray array];

            BOOL duplicate = NO;
            for (DSMessageSnapshot *existing in messages) {
                if ([existing.messageID isEqualToString:messageID]) {
                    duplicate = YES;
                    break;
                }
            }
            if (duplicate) return;

            DSMessageSnapshot *message = [[DSMessageSnapshot alloc] init];
            message.messageID = messageID;
            message.text = text;
            message.outgoing = [self messageIsOutgoing:raw];
            message.timestamp = [self messageTimestamp:raw fallback:now + index / 1000.0];
            NSString *recentText = self.recentOutgoingTexts[conversationID];
            NSDate *recentDate = self.recentOutgoingDates[conversationID];
            if (!message.outgoing && recentText.length && [recentText isEqualToString:text] &&
                recentDate && -recentDate.timeIntervalSinceNow < 120) {
                message.outgoing = YES;
                [self.recentOutgoingTexts removeObjectForKey:conversationID];
                [self.recentOutgoingDates removeObjectForKey:conversationID];
            }
            [messages addObject:message];
            [messages sortUsingComparator:^NSComparisonResult(DSMessageSnapshot *a, DSMessageSnapshot *b) {
                if (a.timestamp < b.timestamp) return NSOrderedAscending;
                if (a.timestamp > b.timestamp) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            if (messages.count > 100) {
                [messages removeObjectsInRange:NSMakeRange(0, messages.count - 100)];
            }

            id conversation = [self conversationForID:conversationID inMap:conversationMap];
            snapshot.conversationID = conversationID;
            snapshot.messages = messages;
            if (conversation) snapshot.conversationObject = conversation;
            NSString *displayName = [self displayNameFromObject:conversation];
            if (!displayName.length) displayName = [self displayNameFromObject:raw];
            if (displayName.length) snapshot.displayName = displayName;
            if (!snapshot.displayName.length) snapshot.displayName = conversationID;
            self.conversations[conversationID] = snapshot;
            [changedConversationIDs addObject:conversationID];
        }];

        NSMutableArray<DSConversationSnapshot *> *changed = [NSMutableArray array];
        for (NSString *conversationID in changedConversationIDs) {
            DSConversationSnapshot *snapshot = self.conversations[conversationID];
            if (snapshot) [changed addObject:snapshot];
        }
        return changed;
    }
}

- (NSArray<DSConversationSnapshot *> *)knownConversations {
    @synchronized (self.conversations) {
        NSArray *values = self.conversations.allValues;
        return [values sortedArrayUsingComparator:^NSComparisonResult(DSConversationSnapshot *a, DSConversationSnapshot *b) {
            NSTimeInterval at = a.messages.lastObject.timestamp;
            NSTimeInterval bt = b.messages.lastObject.timestamp;
            if (at > bt) return NSOrderedAscending;
            if (at < bt) return NSOrderedDescending;
            return [a.displayName compare:b.displayName];
        }];
    }
}

- (DSConversationSnapshot *)conversationForID:(NSString *)conversationID {
    if (!conversationID.length) return nil;
    @synchronized (self.conversations) { return self.conversations[conversationID]; }
}

- (NSArray<NSDictionary<NSString *,NSString *> *> *)apiMessagesForConversation:(DSConversationSnapshot *)conversation {
    NSInteger limit = [DSConfig shared].contextLimit;
    NSArray<DSMessageSnapshot *> *all = conversation.messages ?: @[];
    NSUInteger start = all.count > limit ? all.count - limit : 0;
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger i = start; i < all.count; i++) {
        DSMessageSnapshot *message = all[i];
        if (!message.text.length) continue;
        [result addObject:@{
            @"role": message.outgoing ? @"assistant" : @"user",
            @"content": message.text,
        }];
    }
    return result;
}

- (void)sendText:(NSString *)text toConversation:(DSConversationSnapshot *)conversation completion:(DSSendCompletion)completion {
    if (!text.length || !conversation.conversationID.length) {
        completion(NO, [NSError errorWithDomain:DSBridgeErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"发送内容或会话 ID 为空。"}]);
        return;
    }

    id controller = conversation.controller;
    id messageObject = [self messageObjectForText:text];
    SEL directSelector = NSSelectorFromString(@"sendMessage:");
    if (controller && messageObject && [controller respondsToSelector:directSelector]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, directSelector, messageObject);
            self.recentOutgoingTexts[conversation.conversationID] = text;
            self.recentOutgoingDates[conversation.conversationID] = NSDate.date;
            completion(YES, nil);
            return;
        } @catch (__unused NSException *exception) {}
    }

    id sendController = DSSafeValue(controller, @[@"sendMessageController", @"inputViewController.sendMessageController", @"messageViewModel.sendMessageController"]);
    if (!sendController) sendController = DSSharedInstanceForClass(objc_getClass("AWEIMSendMessageController"));
    id conversationObject = conversation.conversationObject ?: DSSafeValue(controller, @[@"msg_conversation", @"currentConversation", @"conversation"]);
    if ([self invokeSendController:sendController text:text conversation:conversationObject]) {
        self.recentOutgoingTexts[conversation.conversationID] = text;
        self.recentOutgoingDates[conversation.conversationID] = NSDate.date;
        completion(YES, nil);
        return;
    }

    [self fetchConversation:conversation.conversationID completion:^(id fetchedConversation) {
        if (fetchedConversation) conversation.conversationObject = fetchedConversation;
        Class senderClass = objc_getClass("AWEIMSendMessageController");
        id sender = DSSharedInstanceForClass(senderClass);
        BOOL sent = [self invokeSendController:sender text:text conversation:fetchedConversation];
        if (sent) {
            self.recentOutgoingTexts[conversation.conversationID] = text;
            self.recentOutgoingDates[conversation.conversationID] = NSDate.date;
            completion(YES, nil);
        } else {
            NSString *message = @"没找到当前抖音版本的发信方法。请先打开目标聊天，再点一次测试发话；仍失败就是私有 API 已变。";
            completion(NO, [NSError errorWithDomain:DSBridgeErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey: message}]);
        }
    }];
}

- (id)messageObjectForText:(NSString *)text {
    NSArray<NSString *> *classNames = @[@"AWEIMShareMessageCreater", @"AWEIMShareMessageCreator"];
    for (NSString *className in classNames) {
        Class creatorClass = objc_getClass(className.UTF8String);
        if (!creatorClass) continue;
        SEL selector = NSSelectorFromString(@"sendTextMessageWithContent:");
        id creator = DSSharedInstanceForClass(creatorClass);
        if (creator && [creator respondsToSelector:selector]) {
            id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id message = send(creator, selector, text);
            if (message) return message;
        }
        if ([creatorClass respondsToSelector:selector]) {
            id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id message = send(creatorClass, selector, text);
            if (message) return message;
        }
    }
    return nil;
}

- (BOOL)invokeSendController:(id)sender text:(NSString *)text conversation:(id)conversation {
    if (!sender || !conversation) return NO;
    id message = [self messageObjectForText:text];
    if (!message) return NO;
    SEL selector = NSSelectorFromString(@"sendMessage:conversation:forwardMessage:mentionUsers:");
    @try {
        if ([sender respondsToSelector:selector]) {
            ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(sender, selector, message, conversation, nil, nil);
            return YES;
        }

        selector = NSSelectorFromString(@"sendMessage:conversation:forwardMessage:mentionUsers:enterFrom:");
        if ([sender respondsToSelector:selector]) {
            ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(sender, selector, message, conversation, nil, nil, @"DouyinDeepSeek");
            return YES;
        }

        selector = NSSelectorFromString(@"sendMessage:conversation:");
        if ([sender respondsToSelector:selector]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(sender, selector, message, conversation);
            return YES;
        }

        selector = NSSelectorFromString(@"sendMessage:");
        if ([sender respondsToSelector:selector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(sender, selector, message);
            return YES;
        }
    } @catch (__unused NSException *exception) {}
    return NO;
}

- (void)fetchConversation:(NSString *)conversationID completion:(void (^)(id _Nullable))completion {
    Class utilityClass = objc_getClass("IESIMConversationUtility");
    if (!utilityClass) { completion(nil); return; }

    id sharedUtility = DSSharedInstanceForClass(utilityClass);
    SEL syncSelector = NSSelectorFromString(@"conversationForIdentifier:");
    for (id target in @[utilityClass, sharedUtility ?: NSNull.null]) {
        if (target == NSNull.null || ![target respondsToSelector:syncSelector]) continue;
        id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id conversation = send(target, syncSelector, conversationID);
        if (conversation) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(conversation); });
            return;
        }
    }

    SEL selector = NSSelectorFromString(@"asyncGetConversationForIdentifier:completion:");
    id target = [utilityClass respondsToSelector:selector] ? utilityClass : sharedUtility;
    if (!target || ![target respondsToSelector:selector]) { completion(nil); return; }

    void (^callback)(id) = ^(id fetched) { dispatch_async(dispatch_get_main_queue(), ^{ completion(fetched); }); };
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    id identifier = conversationID;
    id block = [callback copy];
    [invocation setArgument:&identifier atIndex:2];
    [invocation setArgument:&block atIndex:3];
    [invocation invoke];
}

- (NSString *)compatibilitySummary {
    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject:objc_getClass("AWESettingBaseViewController") ? @"设置入口✓" : @"设置入口✗"];
    [parts addObject:objc_getClass("AWEIMMessageListViewController") ? @"消息列表✓" : @"消息列表✗"];
    Class notifierClass = objc_getClass("TIMXOMessageNotifier");
    BOOL notifierReady = class_getInstanceMethod(notifierClass, NSSelectorFromString(@"onMessagesCreated:belongingConversationMap:reason:context:")) != NULL;
    [parts addObject:notifierReady ? @"全局收信✓" : @"全局收信✗"];
    id creator = DSSharedInstanceForClass(objc_getClass("AWEIMShareMessageCreater"));
    BOOL creatorReady = [creator respondsToSelector:NSSelectorFromString(@"sendTextMessageWithContent:")];
    [parts addObject:creatorReady ? @"消息创建器✓" : @"消息创建器✗"];
    id sender = DSSharedInstanceForClass(objc_getClass("AWEIMSendMessageController"));
    BOOL senderReady = [sender respondsToSelector:NSSelectorFromString(@"sendMessage:conversation:forwardMessage:mentionUsers:")] ||
                       [sender respondsToSelector:NSSelectorFromString(@"sendMessage:conversation:forwardMessage:mentionUsers:enterFrom:")] ||
                       [sender respondsToSelector:NSSelectorFromString(@"sendMessage:conversation:")] ||
                       [sender respondsToSelector:NSSelectorFromString(@"sendMessage:")];
    [parts addObject:senderReady ? @"发信器✓" : @"发信器✗"];
    [parts addObject:objc_getClass("IESIMConversationUtility") ? @"会话工具✓" : @"会话工具✗"];
    return [parts componentsJoinedByString:@"  "];
}

@end
