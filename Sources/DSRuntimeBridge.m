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

static id DSUnwrappedConversation(id conversation) {
    if (!conversation) return nil;
    id sdkConversation = DSSafeValue(conversation, @[@"con"]);
    return sdkConversation ?: conversation;
}

@interface DSRuntimeBridge ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, DSConversationSnapshot *> *conversations;
@property (nonatomic, strong) NSHashTable *friendModels;
@property (nonatomic, strong) NSHashTable *messageControllers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *recentOutgoingTexts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *recentOutgoingDates;
@property (nonatomic, strong) NSMutableArray<NSString *> *diagnosticEvents;
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
        _diagnosticEvents = [NSMutableArray array];
        _stateQueue = dispatch_queue_create("com.codex.douyin.deepseek.bridge", DISPATCH_QUEUE_SERIAL);
        [self recordDiagnostic:@"插件运行桥初始化完成"];
    }
    return self;
}

- (void)recordDiagnostic:(NSString *)message {
    if (!message.length) return;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [formatter stringFromDate:NSDate.date], message];
    @synchronized (self.diagnosticEvents) {
        [self.diagnosticEvents addObject:line];
        if (self.diagnosticEvents.count > 60) {
            [self.diagnosticEvents removeObjectsInRange:NSMakeRange(0, self.diagnosticEvents.count - 60)];
        }
    }
    NSLog(@"[DouyinDeepSeek] %@", message);
}

- (void)trackMessageController:(id)controller {
    if (!controller) return;
    @synchronized (self.messageControllers) {
        [self.messageControllers addObject:controller];
    }
    [self recordDiagnostic:[NSString stringWithFormat:@"发现消息控制器：%@", NSStringFromClass([controller class])]];
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
    if (!conversationID.length) {
        [self recordDiagnostic:[NSString stringWithFormat:@"控制器捕获失败：%@ 未解析到会话 ID，原始消息=%lu",
                                NSStringFromClass([controller class]), (unsigned long)rawMessages.count]];
        return nil;
    }

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
        if (conversation) snapshot.conversationObject = DSUnwrappedConversation(conversation);
        self.conversations[conversationID] = snapshot;
    }
    [self recordDiagnostic:[NSString stringWithFormat:@"会话捕获：ID=%@ 控制器=%@ 会话对象=%@ 原始=%lu 文本=%lu",
                            conversationID,
                            NSStringFromClass([controller class]),
                            conversation ? [NSString stringWithFormat:@"%@ -> %@",
                                            NSStringFromClass([conversation class]),
                                            NSStringFromClass([DSUnwrappedConversation(conversation) class])] : @"nil",
                            (unsigned long)rawMessages.count,
                            (unsigned long)messages.count]];
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
    if (![rawMessages isKindOfClass:NSArray.class] || !rawMessages.count) {
        [self recordDiagnostic:[NSString stringWithFormat:@"全局收信回调无可用数组：实际类型=%@",
                                rawMessages ? NSStringFromClass([rawMessages class]) : @"nil"]];
        return @[];
    }

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
            if (conversation) snapshot.conversationObject = DSUnwrappedConversation(conversation);
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
        [self recordDiagnostic:[NSString stringWithFormat:@"全局收信：原始=%lu 解析会话=%lu map=%@",
                                (unsigned long)rawMessages.count,
                                (unsigned long)changed.count,
                                conversationMap ? NSStringFromClass([conversationMap class]) : @"nil"]];
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
    DSConfig *config = [DSConfig shared];
    NSInteger limit = config.contextLimit;
    NSArray<DSMessageSnapshot *> *all = conversation.messages ?: @[];
    NSUInteger start = all.count > limit ? all.count - limit : 0;
    NSMutableArray *result = [NSMutableArray array];
    NSString *ownerName = config.ownerName.length ? config.ownerName : @"我";
    NSString *contactName = conversation.displayName.length ? conversation.displayName : @"对方";
    NSString *identityInstruction = [NSString stringWithFormat:
        @"这是账号主人“%@”与联系人“%@”的一对一私信。历史记录中，role=assistant 和【%@说】都表示账号主人本人此前发送的内容，不代表模型自己说过；role=user 和【%@说】都表示联系人发来的内容。你现在必须站在“%@”的身份，结合双方完整上下文，生成下一条发给“%@”的回复。要明确区分双方，不能把联系人说的话当成账号主人说的，也不能遗漏账号主人此前说过的话。只输出回复正文。",
        ownerName, contactName, ownerName, contactName, ownerName, contactName];
    [result addObject:@{ @"role": @"system", @"content": identityInstruction }];
    for (NSUInteger i = start; i < all.count; i++) {
        DSMessageSnapshot *message = all[i];
        if (!message.text.length) continue;
        NSString *speaker = message.outgoing ? ownerName : contactName;
        NSString *labeledText = [NSString stringWithFormat:@"【%@说】%@", speaker, message.text];
        [result addObject:@{
            @"role": message.outgoing ? @"assistant" : @"user",
            @"content": labeledText,
        }];
    }
    [self recordDiagnostic:[NSString stringWithFormat:@"构建实名上下文：我=%@ 对方=%@ 历史文本=%lu API消息=%lu",
                            ownerName, contactName,
                            (unsigned long)(all.count - start),
                            (unsigned long)result.count]];
    return result;
}

- (BOOL)sendTextThroughYukiIfAvailable:(NSString *)text
                        conversationID:(NSString *)conversationID
                            diagnostic:(NSString *)diagnostic
                            completion:(DSSendCompletion)completion {
    Class managerClass = objc_getClass("YukiAutoMessageManager");
    id manager = DSSharedInstanceForClass(managerClass);
    SEL selector = NSSelectorFromString(@"sendMessageToConversationID:text:completion:");
    if (!manager || ![manager respondsToSelector:selector]) {
        [self recordDiagnostic:[NSString stringWithFormat:@"Yuki 兜底不可用：class=%@ manager=%@ selector=%@",
                                managerClass ? @"✓" : @"✗",
                                manager ? NSStringFromClass([manager class]) : @"nil",
                                [manager respondsToSelector:selector] ? @"✓" : @"✗"]];
        return NO;
    }

    @try {
        [self recordDiagnostic:[NSString stringWithFormat:@"调用 Yuki 兜底：manager=%@ cid=%@ selector=%@",
                                NSStringFromClass([manager class]), conversationID, NSStringFromSelector(selector)]];
        __block BOOL didFinish = NO;
        void (^callback)(BOOL) = ^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (didFinish) return;
                didFinish = YES;
                [self recordDiagnostic:[NSString stringWithFormat:@"Yuki 兜底回调：%@", success ? @"成功" : @"失败"]];
                if (success) {
                    self.recentOutgoingTexts[conversationID] = text;
                    self.recentOutgoingDates[conversationID] = NSDate.date;
                    completion(YES, nil);
                } else {
                    NSString *message = [NSString stringWithFormat:@"原生发信链失败（%@）；Yuki 发信链也返回失败。请保持目标聊天已打开，再重试一次。", diagnostic];
                    completion(NO, [NSError errorWithDomain:DSBridgeErrorDomain code:-3 userInfo:@{NSLocalizedDescriptionKey: message}]);
                }
            });
        };
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, selector, conversationID, text, [callback copy]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (didFinish) return;
            didFinish = YES;
            [self recordDiagnostic:@"Yuki 兜底超时：12 秒没有回调"];
            NSString *message = [NSString stringWithFormat:@"原生发信链失败（%@）；Yuki 发信链调用后 12 秒无回调。", diagnostic];
            completion(NO, [NSError errorWithDomain:DSBridgeErrorDomain code:-4 userInfo:@{NSLocalizedDescriptionKey: message}]);
        });
        return YES;
    } @catch (NSException *exception) {
        [self recordDiagnostic:[NSString stringWithFormat:@"Yuki 兜底异常：%@ / %@", exception.name, exception.reason ?: @"无原因"]];
        return NO;
    }
}

- (NSSet<NSString *> *)messageIDsForConversationID:(NSString *)conversationID {
    NSMutableSet<NSString *> *messageIDs = [NSMutableSet set];
    @synchronized (self.conversations) {
        DSConversationSnapshot *snapshot = self.conversations[conversationID];
        for (DSMessageSnapshot *message in snapshot.messages) {
            if (message.messageID.length) [messageIDs addObject:message.messageID];
        }
    }
    return messageIDs;
}

- (void)waitForSentText:(NSString *)text
          conversationID:(NSString *)conversationID
       baselineMessageIDs:(NSSet<NSString *> *)baselineMessageIDs
         remainingChecks:(NSInteger)remainingChecks
              completion:(void (^)(BOOL confirmed))completion {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(800 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        __block DSMessageSnapshot *matched = nil;
        @synchronized (self.conversations) {
            DSConversationSnapshot *snapshot = self.conversations[conversationID];
            for (DSMessageSnapshot *message in snapshot.messages.reverseObjectEnumerator) {
                BOOL isNew = !message.messageID.length || ![baselineMessageIDs containsObject:message.messageID];
                if (isNew && [message.text isEqualToString:text]) {
                    matched = message;
                    break;
                }
            }
        }
        if (matched) {
            [self recordDiagnostic:[NSString stringWithFormat:@"真实发信确认：messageID=%@ outgoing=%@",
                                    matched.messageID ?: @"nil", matched.outgoing ? @"✓" : @"✗"]];
            completion(YES);
            return;
        }
        if (remainingChecks > 1) {
            [self waitForSentText:text
                  conversationID:conversationID
               baselineMessageIDs:baselineMessageIDs
                 remainingChecks:remainingChecks - 1
                      completion:completion];
            return;
        }
        [self recordDiagnostic:@"真实发信确认失败：6.4 秒内会话中没有出现生成文本"];
        completion(NO);
    });
}

- (void)attemptYukiSendText:(NSString *)text
              conversationID:(NSString *)conversationID
           baselineMessageIDs:(NSSet<NSString *> *)baselineMessageIDs
                   diagnostic:(NSString *)diagnostic
                   completion:(DSSendCompletion)completion {
    BOOL invoked = [self sendTextThroughYukiIfAvailable:text
                                         conversationID:conversationID
                                             diagnostic:diagnostic
                                             completion:^(BOOL success, NSError *error) {
        if (!success) {
            completion(NO, error);
            return;
        }
        [self waitForSentText:text
               conversationID:conversationID
            baselineMessageIDs:baselineMessageIDs
              remainingChecks:8
                   completion:^(BOOL confirmed) {
            if (confirmed) {
                completion(YES, nil);
            } else {
                NSString *message = @"Yuki 返回成功，但消息仍未出现在会话中，已拒绝伪报成功。";
                completion(NO, [NSError errorWithDomain:DSBridgeErrorDomain code:-6 userInfo:@{NSLocalizedDescriptionKey: message}]);
            }
        }];
    }];
    if (!invoked) {
        NSString *message = [NSString stringWithFormat:@"原生发信未确认（%@），Yuki 发信链也不可调用。", diagnostic];
        completion(NO, [NSError errorWithDomain:DSBridgeErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey: message}]);
    }
}

- (void)sendText:(NSString *)text toConversation:(DSConversationSnapshot *)conversation completion:(DSSendCompletion)completion {
    if (!text.length || !conversation.conversationID.length) {
        [self recordDiagnostic:[NSString stringWithFormat:@"发送入口拒绝：text=%lu cid=%@",
                                (unsigned long)text.length, conversation.conversationID ?: @"nil"]];
        completion(NO, [NSError errorWithDomain:DSBridgeErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"发送内容或会话 ID 为空。"}]);
        return;
    }

    NSString *conversationID = conversation.conversationID;
    NSSet<NSString *> *baselineMessageIDs = [self messageIDsForConversationID:conversationID];
    [self recordDiagnostic:[NSString stringWithFormat:@"开始真实发送：cid=%@ 文本=%lu controller=%@ storedConversation=%@ baseline=%lu",
                            conversationID,
                            (unsigned long)text.length,
                            conversation.controller ? NSStringFromClass([conversation.controller class]) : @"nil",
                            conversation.conversationObject ? NSStringFromClass([conversation.conversationObject class]) : @"nil",
                            (unsigned long)baselineMessageIDs.count]];
    [self recordDiagnostic:@"已禁用会静默空转的 AWEIMMessageListViewController sendMessage: 路线"];

    [self fetchConversation:conversationID completion:^(id fetchedConversation) {
        id sdkConversation = DSUnwrappedConversation(fetchedConversation ?: conversation.conversationObject);
        if (sdkConversation) conversation.conversationObject = sdkConversation;
        id sender = DSSharedInstanceForClass(objc_getClass("AWEIMSendMessageController"));
        BOOL invoked = [self invokeSendController:sender text:text conversation:sdkConversation];
        NSString *diagnostic = [NSString stringWithFormat:@"SDK会话=%@，发信器=%@，原生调用=%@",
                                sdkConversation ? NSStringFromClass([sdkConversation class]) : @"nil",
                                sender ? NSStringFromClass([sender class]) : @"nil",
                                invoked ? @"✓" : @"✗"];
        if (!invoked) {
            [self recordDiagnostic:[NSString stringWithFormat:@"原生发信未调用成功：%@，转 Yuki", diagnostic]];
            [self attemptYukiSendText:text
                        conversationID:conversationID
                     baselineMessageIDs:baselineMessageIDs
                             diagnostic:diagnostic
                             completion:completion];
            return;
        }

        self.recentOutgoingTexts[conversationID] = text;
        self.recentOutgoingDates[conversationID] = NSDate.date;
        [self recordDiagnostic:[NSString stringWithFormat:@"原生发信已调用，等待真实消息出现：%@", diagnostic]];
        [self waitForSentText:text
               conversationID:conversationID
            baselineMessageIDs:baselineMessageIDs
              remainingChecks:8
                   completion:^(BOOL confirmed) {
            if (confirmed) {
                completion(YES, nil);
                return;
            }
            [self recordDiagnostic:@"原生发信无真实确认，转 Yuki 再试一次"];
            [self attemptYukiSendText:text
                        conversationID:conversationID
                     baselineMessageIDs:baselineMessageIDs
                             diagnostic:diagnostic
                             completion:completion];
        }];
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
            @try {
                id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
                id message = send(creator, selector, text);
                [self recordDiagnostic:[NSString stringWithFormat:@"消息创建器实例调用：%@ -> %@",
                                        NSStringFromClass([creator class]), message ? NSStringFromClass([message class]) : @"nil"]];
                if (message) return message;
            } @catch (NSException *exception) {
                [self recordDiagnostic:[NSString stringWithFormat:@"消息创建器实例异常：%@ / %@", exception.name, exception.reason ?: @"无原因"]];
            }
        }
        if ([creatorClass respondsToSelector:selector]) {
            @try {
                id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
                id message = send(creatorClass, selector, text);
                [self recordDiagnostic:[NSString stringWithFormat:@"消息创建器类调用：%@ -> %@",
                                        className, message ? NSStringFromClass([message class]) : @"nil"]];
                if (message) return message;
            } @catch (NSException *exception) {
                [self recordDiagnostic:[NSString stringWithFormat:@"消息创建器类异常：%@ / %@", exception.name, exception.reason ?: @"无原因"]];
            }
        }
    }
    [self recordDiagnostic:@"消息对象创建失败：未获得可发送消息对象"];
    return nil;
}

- (BOOL)invokeSendController:(id)sender text:(NSString *)text conversation:(id)conversation {
    if (!sender || !conversation) {
        [self recordDiagnostic:[NSString stringWithFormat:@"发信器调用前置失败：sender=%@ conversation=%@",
                                sender ? NSStringFromClass([sender class]) : @"nil",
                                conversation ? NSStringFromClass([conversation class]) : @"nil"]];
        return NO;
    }
    id message = [self messageObjectForText:text];
    if (!message) {
        [self recordDiagnostic:@"发信器调用前置失败：消息对象=nil"];
        return NO;
    }
    SEL selector = NSSelectorFromString(@"sendMessage:conversation:forwardMessage:mentionUsers:");
    @try {
        if ([sender respondsToSelector:selector]) {
            [self recordDiagnostic:[NSString stringWithFormat:@"调用发信选择器：%@ %@", NSStringFromClass([sender class]), NSStringFromSelector(selector)]];
            id result = ((id (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(sender, selector, message, conversation, NO, nil);
            [self recordDiagnostic:[NSString stringWithFormat:@"发信选择器返回：%@", result ? NSStringFromClass([result class]) : @"nil"]];
            return result != nil;
        }

        selector = NSSelectorFromString(@"sendMessage:conversation:forwardMessage:mentionUsers:enterFrom:");
        if ([sender respondsToSelector:selector]) {
            [self recordDiagnostic:[NSString stringWithFormat:@"调用发信选择器：%@ %@", NSStringFromClass([sender class]), NSStringFromSelector(selector)]];
            id result = ((id (*)(id, SEL, id, id, BOOL, id, id))objc_msgSend)(sender, selector, message, conversation, NO, nil, @"DouyinDeepSeek");
            [self recordDiagnostic:[NSString stringWithFormat:@"发信选择器返回：%@", result ? NSStringFromClass([result class]) : @"nil"]];
            return result != nil;
        }

        selector = NSSelectorFromString(@"sendMessage:conversation:");
        if ([sender respondsToSelector:selector]) {
            [self recordDiagnostic:[NSString stringWithFormat:@"调用发信选择器：%@ %@", NSStringFromClass([sender class]), NSStringFromSelector(selector)]];
            id result = ((id (*)(id, SEL, id, id))objc_msgSend)(sender, selector, message, conversation);
            [self recordDiagnostic:[NSString stringWithFormat:@"发信选择器返回：%@", result ? NSStringFromClass([result class]) : @"nil"]];
            return result != nil;
        }

        selector = NSSelectorFromString(@"sendMessage:");
        if ([sender respondsToSelector:selector]) {
            [self recordDiagnostic:[NSString stringWithFormat:@"调用发信选择器：%@ %@", NSStringFromClass([sender class]), NSStringFromSelector(selector)]];
            id result = ((id (*)(id, SEL, id))objc_msgSend)(sender, selector, message);
            [self recordDiagnostic:[NSString stringWithFormat:@"发信选择器返回：%@", result ? NSStringFromClass([result class]) : @"nil"]];
            return result != nil;
        }
    } @catch (NSException *exception) {
        [self recordDiagnostic:[NSString stringWithFormat:@"发信选择器异常：%@ / %@", exception.name, exception.reason ?: @"无原因"]];
    }
    [self recordDiagnostic:[NSString stringWithFormat:@"发信器没有匹配选择器：%@", NSStringFromClass([sender class])]];
    return NO;
}

- (void)fetchConversation:(NSString *)conversationID completion:(void (^)(id _Nullable))completion {
    Class utilityClass = objc_getClass("IESIMConversationUtility");
    if (!utilityClass) {
        [self recordDiagnostic:@"重新取会话失败：IESIMConversationUtility 类不存在"];
        completion(nil);
        return;
    }

    id sharedUtility = DSSharedInstanceForClass(utilityClass);
    SEL syncSelector = NSSelectorFromString(@"conversationForIdentifier:");
    for (id target in @[utilityClass, sharedUtility ?: NSNull.null]) {
        if (target == NSNull.null || ![target respondsToSelector:syncSelector]) continue;
        id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id conversation = DSUnwrappedConversation(send(target, syncSelector, conversationID));
        if (conversation) {
            [self recordDiagnostic:[NSString stringWithFormat:@"同步取得会话：target=%@ result=%@",
                                    object_isClass(target) ? NSStringFromClass(target) : NSStringFromClass([target class]),
                                    NSStringFromClass([conversation class])]];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(conversation); });
            return;
        }
    }

    SEL selector = NSSelectorFromString(@"asyncGetConversationForIdentifier:completion:");
    id target = [utilityClass respondsToSelector:selector] ? utilityClass : sharedUtility;
    if (!target || ![target respondsToSelector:selector]) {
        [self recordDiagnostic:@"重新取会话失败：同步为空且异步选择器不可用"];
        completion(nil);
        return;
    }

    [self recordDiagnostic:@"同步取会话为空，调用异步取会话"];
    void (^callback)(id) = ^(id fetched) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id unwrapped = DSUnwrappedConversation(fetched);
            [self recordDiagnostic:[NSString stringWithFormat:@"异步取会话结果：%@ -> %@",
                                    fetched ? NSStringFromClass([fetched class]) : @"nil",
                                    unwrapped ? NSStringFromClass([unwrapped class]) : @"nil"]];
            completion(unwrapped);
        });
    };
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

- (NSString *)diagnosticReportForConversation:(DSConversationSnapshot *)conversation {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *appVersion = DSStringValue(info[@"CFBundleShortVersionString"]) ?: @"未知";
    NSString *appBuild = DSStringValue(info[@"CFBundleVersion"]) ?: @"未知";
    id controller = conversation.controller;
    id conversationObject = conversation.conversationObject;
    Class creatorClass = objc_getClass("AWEIMShareMessageCreater");
    id creator = DSSharedInstanceForClass(creatorClass);
    Class senderClass = objc_getClass("AWEIMSendMessageController");
    id sender = DSSharedInstanceForClass(senderClass);
    Class utilityClass = objc_getClass("IESIMConversationUtility");
    Class yukiClass = objc_getClass("YukiAutoMessageManager");
    id yuki = DSSharedInstanceForClass(yukiClass);

    NSMutableArray<NSString *> *sendSelectors = [NSMutableArray array];
    for (NSString *name in @[
        @"sendMessage:conversation:forwardMessage:mentionUsers:",
        @"sendMessage:conversation:forwardMessage:mentionUsers:enterFrom:",
        @"sendMessage:conversation:",
        @"sendMessage:"
    ]) {
        if ([sender respondsToSelector:NSSelectorFromString(name)]) [sendSelectors addObject:name];
    }

    NSUInteger conversationCount = 0;
    @synchronized (self.conversations) { conversationCount = self.conversations.count; }
    NSUInteger ownerMessageCount = 0;
    NSUInteger contactMessageCount = 0;
    for (DSMessageSnapshot *message in conversation.messages) {
        if (message.outgoing) ownerMessageCount++;
        else contactMessageCount++;
    }
    NSArray<NSString *> *events;
    @synchronized (self.diagnosticEvents) { events = [self.diagnosticEvents copy]; }

    NSMutableString *report = [NSMutableString string];
    [report appendString:@"DouyinDeepSeek 运行报错\n"];
    [report appendString:@"插件版本：0.2.1\n"];
    [report appendFormat:@"抖音版本：%@ (%@)\n", appVersion, appBuild];
    [report appendFormat:@"系统：iOS %@ / %@\n", UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.model];
    [report appendFormat:@"兼容性：%@\n", [self compatibilitySummary]];
    [report appendFormat:@"已记录会话：%lu\n", (unsigned long)conversationCount];
    [report appendFormat:@"目标：%@ / %@\n", conversation.displayName ?: @"nil", conversation.conversationID ?: @"nil"];
    [report appendFormat:@"上下文文本：%lu\n", (unsigned long)conversation.messages.count];
    [report appendFormat:@"身份映射：账号主人=%@ / 联系人=%@\n",
     [DSConfig shared].ownerName ?: @"我", conversation.displayName ?: @"对方"];
    [report appendFormat:@"身份统计：账号主人消息=%lu / 联系人消息=%lu\n",
     (unsigned long)ownerMessageCount, (unsigned long)contactMessageCount];
    [report appendFormat:@"控制器：%@ / sendMessage:%@\n",
     controller ? NSStringFromClass([controller class]) : @"nil",
     [controller respondsToSelector:NSSelectorFromString(@"sendMessage:")] ? @"✓" : @"✗"];
    [report appendFormat:@"会话对象：%@\n", conversationObject ? NSStringFromClass([conversationObject class]) : @"nil"];
    [report appendFormat:@"消息创建器：class=%@ instance=%@ selector=%@\n",
     creatorClass ? @"✓" : @"✗",
     creator ? NSStringFromClass([creator class]) : @"nil",
     [creator respondsToSelector:NSSelectorFromString(@"sendTextMessageWithContent:")] ? @"✓" : @"✗"];
    [report appendFormat:@"发信器：class=%@ instance=%@ selectors=%@\n",
     senderClass ? @"✓" : @"✗",
     sender ? NSStringFromClass([sender class]) : @"nil",
     sendSelectors.count ? [sendSelectors componentsJoinedByString:@","] : @"无"];
    [report appendFormat:@"会话工具：class=%@ sync=%@ async=%@\n",
     utilityClass ? @"✓" : @"✗",
     [utilityClass respondsToSelector:NSSelectorFromString(@"conversationForIdentifier:")] ? @"✓" : @"✗",
     [utilityClass respondsToSelector:NSSelectorFromString(@"asyncGetConversationForIdentifier:completion:")] ? @"✓" : @"✗"];
    [report appendFormat:@"Yuki：class=%@ manager=%@ send=%@\n",
     yukiClass ? @"✓" : @"✗",
     yuki ? NSStringFromClass([yuki class]) : @"nil",
     [yuki respondsToSelector:NSSelectorFromString(@"sendMessageToConversationID:text:completion:")] ? @"✓" : @"✗"];
    [report appendString:@"\n最近运行记录：\n"];
    if (events.count) [report appendString:[events componentsJoinedByString:@"\n"]];
    else [report appendString:@"无"];
    return report;
}

@end
