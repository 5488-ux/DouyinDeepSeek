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

@interface DSRuntimeBridge ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, DSConversationSnapshot *> *conversations;
@property (nonatomic, strong) NSHashTable *friendModels;
@property (nonatomic, strong) NSHashTable *messageControllers;
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
        @"msg_conversationID", @"iesMessage.conversationID"
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
    id value = DSSafeValue(object, @[
        @"text", @"content", @"messageText", @"msg_content", @"messageContent",
        @"iesMessage.content", @"message.content", @"content.text"
    ]);
    if ([value isKindOfClass:NSAttributedString.class]) value = [value string];
    NSString *text = DSStringValue(value);
    if (!text.length) {
        id ext = DSSafeValue(object, @[@"localExt", @"ext", @"extra"]);
        if ([ext isKindOfClass:NSDictionary.class]) {
            text = DSStringValue(ext[@"text"] ?: ext[@"content"]);
        }
    }
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString *)messageIDFromObject:(id)object fallback:(NSString *)fallback {
    NSString *messageID = DSStringValue(DSSafeValue(object, @[
        @"messageID", @"messageId", @"msg_id", @"serverMessageID", @"clientMessageID",
        @"uuid", @"iesMessage.messageID", @"iesMessage.messageId"
    ]));
    return messageID.length ? messageID : fallback;
}

- (BOOL)messageIsOutgoing:(id)object {
    BOOL found = NO;
    BOOL outgoing = DSBoolValue(object, @[@"isSelf", @"isSendByMe", @"isMine", @"isSelfMessage", @"isFromMe"], &found);
    if (found) return outgoing;

    id numeric = DSSafeValue(object, @[@"msg_isSelf", @"senderIsSelf", @"isSender"]);
    if ([numeric respondsToSelector:@selector(boolValue)]) return [numeric boolValue];
    return NO;
}

- (NSTimeInterval)messageTimestamp:(id)object fallback:(NSTimeInterval)fallback {
    id value = DSSafeValue(object, @[@"createTime", @"timestamp", @"msg_createTime", @"serverTime", @"iesMessage.createTime"]);
    if (![value respondsToSelector:@selector(doubleValue)]) return fallback;
    NSTimeInterval timestamp = [value doubleValue];
    if (timestamp > 1000000000000.0) timestamp /= 1000.0;
    return timestamp > 0 ? timestamp : fallback;
}

- (DSConversationSnapshot *)captureMessageController:(id)controller {
    if (!controller) return nil;
    [self trackMessageController:controller];

    id conversation = DSSafeValue(controller, @[@"conversation", @"messageViewModel.conversation", @"viewModel.conversation"]);
    NSString *conversationID = [self conversationIDFromObject:controller];
    if (!conversationID.length) conversationID = [self conversationIDFromObject:conversation];

    NSArray *rawMessages = DSArrayValue(controller, @[
        @"messages", @"messageViewModel.messages", @"viewModel.messages",
        @"messageList", @"dataSource.messages", @"messageViewModel.messageList"
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
    NSArray<NSString *> *directSelectors = @[@"sendTextMessageWithContent:", @"sendTextMessage:", @"sendMessageWithText:"];
    for (NSString *name in directSelectors) {
        SEL selector = NSSelectorFromString(name);
        if (controller && [controller respondsToSelector:selector]) {
            void (*send)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
            send(controller, selector, text);
            completion(YES, nil);
            return;
        }
    }

    id sendController = DSSafeValue(controller, @[@"sendMessageController", @"messageViewModel.sendMessageController"]);
    id conversationObject = conversation.conversationObject ?: DSSafeValue(controller, @[@"conversation"]);
    if ([self invokeSendController:sendController text:text conversation:conversationObject]) {
        completion(YES, nil);
        return;
    }

    [self fetchConversation:conversation.conversationID completion:^(id fetchedConversation) {
        if (fetchedConversation) conversation.conversationObject = fetchedConversation;
        Class senderClass = objc_getClass("AWEIMSendMessageController");
        id sender = senderClass ? [[senderClass alloc] init] : nil;
        BOOL sent = [self invokeSendController:sender text:text conversation:fetchedConversation];
        if (sent) {
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
        SEL selector = NSSelectorFromString(@"messageObjectForText:");
        if ([creatorClass respondsToSelector:selector]) {
            id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id message = send(creatorClass, selector, text);
            if (message) return message;
        }
        id creator = [[creatorClass alloc] init];
        if ([creator respondsToSelector:selector]) {
            id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id message = send(creator, selector, text);
            if (message) return message;
        }
    }
    return text;
}

- (BOOL)invokeSendController:(id)sender text:(NSString *)text conversation:(id)conversation {
    if (!sender || !conversation) return NO;
    id message = [self messageObjectForText:text];
    NSArray<NSString *> *selectors = @[
        @"sendMessage:conversation:forwardMessage:mentionUsers:enterFrom:",
        @"sendMessage:conversation:forwardMessage:mentionUsers:",
        @"sendMessage:conversation:",
    ];

    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if (![sender respondsToSelector:selector]) continue;
        NSMethodSignature *signature = [sender methodSignatureForSelector:selector];
        if (!signature) continue;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = sender;
        invocation.selector = selector;
        id nilValue = nil;
        id enterFrom = @"DouyinDeepSeek";
        if (signature.numberOfArguments > 2) [invocation setArgument:&message atIndex:2];
        if (signature.numberOfArguments > 3) [invocation setArgument:&conversation atIndex:3];
        if (signature.numberOfArguments > 4) [invocation setArgument:&nilValue atIndex:4];
        if (signature.numberOfArguments > 5) [invocation setArgument:&nilValue atIndex:5];
        if (signature.numberOfArguments > 6) [invocation setArgument:&enterFrom atIndex:6];
        [invocation invoke];
        return YES;
    }
    return NO;
}

- (void)fetchConversation:(NSString *)conversationID completion:(void (^)(id _Nullable))completion {
    Class utilityClass = objc_getClass("IESIMConversationUtility");
    if (!utilityClass) { completion(nil); return; }

    SEL selector = NSSelectorFromString(@"asyncGetConversationForIdentifier:completion:");
    id target = nil;
    if ([utilityClass respondsToSelector:selector]) {
        target = utilityClass;
    } else {
        for (NSString *singletonName in @[@"sharedInstance", @"sharedUtility", @"defaultUtility"]) {
            SEL singletonSelector = NSSelectorFromString(singletonName);
            if ([utilityClass respondsToSelector:singletonSelector]) {
                id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                target = send(utilityClass, singletonSelector);
                if ([target respondsToSelector:selector]) break;
            }
        }
    }
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
    [parts addObject:objc_getClass("AWEIMSendMessageController") ? @"发信器✓" : @"发信器✗"];
    [parts addObject:objc_getClass("IESIMConversationUtility") ? @"会话工具✓" : @"会话工具✗"];
    return [parts componentsJoinedByString:@"  "];
}

@end

