#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <float.h>

#import "Sources/DSConfig.h"
#import "Sources/DSDeepSeekClient.h"
#import "Sources/DSRuntimeBridge.h"
#import "Sources/DSSettingsViewController.h"

static BOOL DSHookInstanceMethod(Class targetClass, SEL selector, IMP replacement, IMP *original) {
    if (!targetClass || !selector || !replacement) return NO;
    Method method = class_getInstanceMethod(targetClass, selector);
    if (!method) return NO;

    IMP previous = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(targetClass, selector, replacement, types)) {
        Method ownMethod = class_getInstanceMethod(targetClass, selector);
        previous = method_setImplementation(ownMethod, replacement);
    }
    if (original) *original = previous;
    return previous != NULL;
}

@interface DSAutoReplyEngine : NSObject
+ (instancetype)shared;
- (void)startPolling;
- (void)observeController:(id)controller;
- (void)observeIncomingConversation:(DSConversationSnapshot *)conversation;
- (void)processPendingConversation:(DSConversationSnapshot *)conversation;
@end

@interface DSAutoReplyEngine ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *lastSeenMessageIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *pendingMessageIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *lastReplyDates;
@property (nonatomic, strong) NSMutableSet<NSString *> *busyConversationIDs;
@property (nonatomic, strong) NSHashTable *controllers;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *retryCounts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *wakeupTokens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *generatedReplies;
@property (nonatomic, strong) NSMutableSet<NSString *> *processedMessageIDs;
@end

@implementation DSAutoReplyEngine

+ (instancetype)shared {
    static DSAutoReplyEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engine = [[self alloc] init];
        engine.lastSeenMessageIDs = [NSMutableDictionary dictionary];
        engine.pendingMessageIDs = [NSMutableDictionary dictionary];
        engine.lastReplyDates = [NSMutableDictionary dictionary];
        engine.busyConversationIDs = [NSMutableSet set];
        engine.controllers = [NSHashTable weakObjectsHashTable];
        engine.retryCounts = [NSMutableDictionary dictionary];
        engine.wakeupTokens = [NSMutableDictionary dictionary];
        engine.generatedReplies = [NSMutableDictionary dictionary];
        NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:@"DouyinDeepSeek.processedMessageIDs"];
        engine.processedMessageIDs = [NSMutableSet setWithArray:[stored isKindOfClass:NSArray.class] ? stored : @[]];
    });
    return engine;
}

- (void)startPolling {
    if (self.pollTimer) return;
    __weak DSAutoReplyEngine *weakEngine = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
        __strong DSAutoReplyEngine *strongEngine = weakEngine;
        if (!strongEngine) return;
        NSArray *controllers;
        @synchronized (strongEngine.controllers) { controllers = strongEngine.controllers.allObjects; }
        for (id controller in controllers) {
            if (![controller isKindOfClass:UIViewController.class] || ((UIViewController *)controller).viewIfLoaded.window) {
                [strongEngine observeController:controller];
            }
        }
        for (NSString *conversationID in strongEngine.pendingMessageIDs.allKeys.copy) {
            DSConversationSnapshot *snapshot = [[DSRuntimeBridge shared] conversationForID:conversationID];
            if (snapshot) [strongEngine processPendingConversation:snapshot];
        }
    }];
}

- (void)markProcessedMessageID:(NSString *)messageID {
    if (!messageID.length) return;
    [self.processedMessageIDs addObject:messageID];
    NSArray *all = self.processedMessageIDs.allObjects;
    if (all.count > 300) all = [all subarrayWithRange:NSMakeRange(all.count - 300, 300)];
    self.processedMessageIDs = [NSMutableSet setWithArray:all];
    [[NSUserDefaults standardUserDefaults] setObject:all forKey:@"DouyinDeepSeek.processedMessageIDs"];
}

- (NSString *)retryKeyForConversationID:(NSString *)conversationID messageID:(NSString *)messageID {
    return [NSString stringWithFormat:@"%@|%@", conversationID ?: @"", messageID ?: @""];
}

- (void)scheduleRetryForConversationID:(NSString *)conversationID
                             messageID:(NSString *)messageID
                                 delay:(NSTimeInterval)delay
                        increaseCount:(BOOL)increaseCount {
    if (!conversationID.length || !messageID.length) return;
    NSString *retryKey = [self retryKeyForConversationID:conversationID messageID:messageID];
    NSInteger count = [self.retryCounts[retryKey] integerValue];
    if (increaseCount) count++;
    if (count > 3) {
        NSLog(@"[DouyinDeepSeek] retry exhausted for %@", retryKey);
        return;
    }
    self.retryCounts[retryKey] = @(count);
    NSString *token = NSUUID.UUID.UUIDString;
    self.wakeupTokens[conversationID] = token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.5, delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self.wakeupTokens[conversationID] isEqualToString:token]) return;
        if (![self.pendingMessageIDs[conversationID] isEqualToString:messageID]) return;
        [self.wakeupTokens removeObjectForKey:conversationID];
        DSConversationSnapshot *snapshot = [[DSRuntimeBridge shared] conversationForID:conversationID];
        if (snapshot) [self processPendingConversation:snapshot];
    });
}

- (void)clearPendingConversationID:(NSString *)conversationID messageID:(NSString *)messageID {
    if ([self.pendingMessageIDs[conversationID] isEqualToString:messageID]) {
        [self.pendingMessageIDs removeObjectForKey:conversationID];
    }
    [self.wakeupTokens removeObjectForKey:conversationID];
    [self.generatedReplies removeObjectForKey:[self retryKeyForConversationID:conversationID messageID:messageID]];
    [self.retryCounts removeObjectForKey:[self retryKeyForConversationID:conversationID messageID:messageID]];
}

- (void)observeController:(id)controller {
    if (!controller) return;
    @synchronized (self.controllers) { [self.controllers addObject:controller]; }

    DSConversationSnapshot *conversation = [[DSRuntimeBridge shared] captureMessageController:controller];
    DSMessageSnapshot *latest = conversation.messages.lastObject;
    if (!conversation.conversationID.length || !latest.messageID.length) return;

    NSString *previousMessageID = self.lastSeenMessageIDs[conversation.conversationID];

    // 第一次见到会话只建立基线，绝不拿旧消息突然回复。
    if (!previousMessageID.length) {
        self.lastSeenMessageIDs[conversation.conversationID] = latest.messageID;
        return;
    }

    if (![previousMessageID isEqualToString:latest.messageID]) {
        self.lastSeenMessageIDs[conversation.conversationID] = latest.messageID;
        if (latest.direction != DSMessageDirectionIncoming || !latest.text.length) {
            // 用户自己已经回复时，不再补发旧的 AI 回复。
            [self.pendingMessageIDs removeObjectForKey:conversation.conversationID];
            return;
        }
        DSConfig *config = [DSConfig shared];
        if (config.enabled && config.apiKey.length) {
            // 生成中或冷却期的新消息留在 pending，绝不提前吞掉。
            self.pendingMessageIDs[conversation.conversationID] = latest.messageID;
        }
    }

    [self processPendingConversation:conversation];
}

- (void)observeIncomingConversation:(DSConversationSnapshot *)conversation {
    DSMessageSnapshot *latest = conversation.messages.lastObject;
    if (!conversation.conversationID.length || !latest.messageID.length) return;

    NSString *previousMessageID = self.lastSeenMessageIDs[conversation.conversationID];
    self.lastSeenMessageIDs[conversation.conversationID] = latest.messageID;
    if ([previousMessageID isEqualToString:latest.messageID]) return;

    if (latest.direction != DSMessageDirectionIncoming || !latest.text.length) {
        [self.pendingMessageIDs removeObjectForKey:conversation.conversationID];
        return;
    }

    // 全局消息创建回调只处理刚收到的消息，额外挡住异常历史回放。
    NSTimeInterval age = fabs(NSDate.date.timeIntervalSince1970 - latest.timestamp);
    if (latest.timestamp > 0 && age > 300) return;
    if ([self.processedMessageIDs containsObject:latest.messageID]) return;

    DSConfig *config = [DSConfig shared];
    if (config.enabled && config.apiKey.length) {
        self.pendingMessageIDs[conversation.conversationID] = latest.messageID;
        [self processPendingConversation:conversation];
    }
}

- (void)processPendingConversation:(DSConversationSnapshot *)conversation {
    NSString *conversationID = conversation.conversationID;
    NSString *pendingMessageID = self.pendingMessageIDs[conversationID];
    if (!pendingMessageID.length) return;

    DSConfig *config = [DSConfig shared];
    if (!config.enabled || !config.apiKey.length) {
        [self clearPendingConversationID:conversationID messageID:pendingMessageID];
        return;
    }
    if (!conversation.directConversation && !conversation.groupConversation) {
        [self clearPendingConversationID:conversationID messageID:pendingMessageID];
        NSLog(@"[DouyinDeepSeek] skip unsupported conversation %@", conversationID);
        return;
    }
    if ([self.busyConversationIDs containsObject:conversationID]) return;

    NSDate *lastReplyDate = self.lastReplyDates[conversationID];
    NSTimeInterval elapsed = lastReplyDate ? -lastReplyDate.timeIntervalSinceNow : DBL_MAX;
    if (elapsed < config.cooldown) {
        [self scheduleRetryForConversationID:conversationID
                                   messageID:pendingMessageID
                                       delay:config.cooldown - elapsed + 0.2
                              increaseCount:NO];
        return;
    }

    NSString *processingMessageID = [pendingMessageID copy];
    [self.busyConversationIDs addObject:conversationID];
    [[DSRuntimeBridge shared] hydrateConversation:conversation completion:^(DSConversationSnapshot *fresh, NSError *hydrateError) {
        if (hydrateError || !fresh.historyHydrated) {
            [self.busyConversationIDs removeObject:conversationID];
            NSLog(@"[DouyinDeepSeek] history hydration failed for %@: %@", conversationID, hydrateError.localizedDescription);
            [self scheduleRetryForConversationID:conversationID messageID:processingMessageID delay:3 increaseCount:YES];
            return;
        }
        if (![self.pendingMessageIDs[conversationID] isEqualToString:processingMessageID]) {
            [self.busyConversationIDs removeObject:conversationID];
            return;
        }
        DSMessageSnapshot *trigger = nil;
        for (DSMessageSnapshot *message in fresh.messages.reverseObjectEnumerator) {
            if ([message.messageID isEqualToString:processingMessageID]) { trigger = message; break; }
        }
        if (trigger.direction != DSMessageDirectionIncoming) {
            [self.busyConversationIDs removeObject:conversationID];
            [self clearPendingConversationID:conversationID messageID:processingMessageID];
            return;
        }

        NSString *retryKey = [self retryKeyForConversationID:conversationID messageID:processingMessageID];
        void (^sendReply)(NSString *) = ^(NSString *reply) {
            if (![self.pendingMessageIDs[conversationID] isEqualToString:processingMessageID] || ![DSConfig shared].enabled) {
                [self.busyConversationIDs removeObject:conversationID];
                return;
            }
            NSString *operationID = [NSString stringWithFormat:@"auto:%@:%@", conversationID, processingMessageID];
            [[DSRuntimeBridge shared] sendText:reply toConversation:fresh operationID:operationID completion:^(BOOL success, NSError *sendError) {
                [self.busyConversationIDs removeObject:conversationID];
                if (success || sendError.code == -7) {
                    self.lastReplyDates[conversationID] = NSDate.date;
                    [self markProcessedMessageID:processingMessageID];
                    [self clearPendingConversationID:conversationID messageID:processingMessageID];
                    NSLog(@"[DouyinDeepSeek] background reply transaction finished for %@", conversationID);
                    return;
                }
                NSLog(@"[DouyinDeepSeek] send failed for %@: %@", conversationID, sendError.localizedDescription);
                [self scheduleRetryForConversationID:conversationID messageID:processingMessageID delay:5 increaseCount:YES];
            }];
        };

        NSString *cachedReply = self.generatedReplies[retryKey];
        if (cachedReply.length) {
            sendReply(cachedReply);
            return;
        }
        NSArray *context = [[DSRuntimeBridge shared] apiMessagesForConversation:fresh];
        [[DSDeepSeekClient shared] generateReplyWithMessages:context conversationID:conversationID completion:^(NSString *reply, NSError *error) {
            if (error || !reply.length) {
                [self.busyConversationIDs removeObject:conversationID];
                NSLog(@"[DouyinDeepSeek] generation failed for %@: %@", conversationID, error.localizedDescription);
                NSInteger code = error.code;
                BOOL retryable = code == 408 || code == 429 || code < 0 || code >= 500;
                if (retryable) [self scheduleRetryForConversationID:conversationID messageID:processingMessageID delay:3 increaseCount:YES];
                else [self clearPendingConversationID:conversationID messageID:processingMessageID];
                return;
            }
            self.generatedReplies[retryKey] = reply;
            sendReply(reply);
        }];
    }];
}

@end

static UIViewController *DSTopViewController(void) {
    UIWindow *window = nil;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).topViewController;
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
        if ([controller isKindOfClass:UINavigationController.class]) {
            controller = ((UINavigationController *)controller).topViewController;
        }
    }
    return controller;
}

static void DSOpenSettingsFromController(UIViewController *controller) {
    DSSettingsViewController *settings = [[DSSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *navigation = controller.navigationController;
    if (navigation) {
        [navigation pushViewController:settings animated:YES];
    } else if (controller) {
        UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:settings];
        [controller presentViewController:wrapper animated:YES completion:nil];
    }
}

static void DSSetObjectSettingValue(id target, NSString *selectorName, id value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value);
}

static void DSSetIntegerSettingValue(id target, NSString *selectorName, NSInteger value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
}

static void DSSetBoolSettingValue(id target, NSString *selectorName, BOOL value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, selector, value);
}

static void DSSetDoubleSettingValue(id target, NSString *selectorName, double value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return;
    ((void (*)(id, SEL, double))objc_msgSend)(target, selector, value);
}

static NSString *DSSettingSectionTitle(id section) {
    SEL selector = NSSelectorFromString(@"sectionHeaderTitle");
    if (![section respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(section, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id (*DSOldSectionDataArray)(id, SEL);
static id DSNewSectionDataArray(id self, SEL _cmd) {
    NSArray *original = DSOldSectionDataArray ? DSOldSectionDataArray(self, _cmd) : nil;
    if (![original isKindOfClass:NSArray.class]) return original;

    for (id section in original) {
        NSString *title = DSSettingSectionTitle(section);
        if ([title isEqualToString:@"DeepSeek AI"]) return original;
    }

    Class itemClass = objc_getClass("AWESettingItemModel");
    Class sectionClass = objc_getClass("AWESettingSectionModel");
    if (!itemClass || !sectionClass) return original;

    id item = [[itemClass alloc] init];
    DSSetObjectSettingValue(item, @"setIdentifier:", @"DouyinDeepSeek");
    DSSetObjectSettingValue(item, @"setTitle:", @"DeepSeek AI");
    DSSetObjectSettingValue(item, @"setDetail:", @"0.4.0");
    DSSetIntegerSettingValue(item, @"setType:", 0);
    DSSetObjectSettingValue(item, @"setSvgIconImageName:", @"ic_module_outlined_20");
    DSSetIntegerSettingValue(item, @"setCellType:", 26);
    DSSetIntegerSettingValue(item, @"setColorStyle:", 2);
    DSSetBoolSettingValue(item, @"setIsEnable:", YES);

    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            DSOpenSettingsFromController(DSTopViewController());
        });
    };
    DSSetObjectSettingValue(item, @"setCellTappedBlock:", [tapBlock copy]);

    id section = [[sectionClass alloc] init];
    DSSetObjectSettingValue(section, @"setItemArray:", @[item]);
    DSSetIntegerSettingValue(section, @"setType:", 0);
    DSSetDoubleSettingValue(section, @"setSectionHeaderHeight:", 40.0);
    DSSetObjectSettingValue(section, @"setSectionHeaderTitle:", @"DeepSeek AI");

    NSMutableArray *result = [NSMutableArray arrayWithArray:original];
    [result insertObject:section atIndex:0];
    return result;
}

static BOOL (*DSOldUseCardUIStyle)(id, SEL);
static BOOL DSNewUseCardUIStyle(id self, SEL _cmd) {
    return YES;
}

static void (*DSOldMessageViewDidAppear)(id, SEL, BOOL);
static void DSNewMessageViewDidAppear(id self, SEL _cmd, BOOL animated) {
    DSOldMessageViewDidAppear(self, _cmd, animated);
    [[DSAutoReplyEngine shared] observeController:self];
}

static void (*DSOldAfterReloadData)(id, SEL);
static void DSNewAfterReloadData(id self, SEL _cmd) {
    DSOldAfterReloadData(self, _cmd);
    [[DSAutoReplyEngine shared] observeController:self];
}

static void (*DSOldAfterUpdateData)(id, SEL);
static void DSNewAfterUpdateData(id self, SEL _cmd) {
    DSOldAfterUpdateData(self, _cmd);
    [[DSAutoReplyEngine shared] observeController:self];
}

static void (*DSOldMessagesCreated)(id, SEL, id, id, id, id);
static void DSNewMessagesCreated(id self, SEL _cmd, id messages, id conversationMap, id reason, id context) {
    DSOldMessagesCreated(self, _cmd, messages, conversationMap, reason, context);
    if (![messages isKindOfClass:NSArray.class] || ![(NSArray *)messages count]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<DSConversationSnapshot *> *snapshots = [[DSRuntimeBridge shared]
            ingestRawMessages:messages
            belongingConversationMap:[conversationMap isKindOfClass:NSDictionary.class] ? conversationMap : nil];
        for (DSConversationSnapshot *snapshot in snapshots) {
            [[DSAutoReplyEngine shared] observeIncomingConversation:snapshot];
        }
    });
}

static id (*DSOldFriendInit)(id, SEL, id);
static id DSNewFriendInit(id self, SEL _cmd, id user) {
    id result = DSOldFriendInit(self, _cmd, user);
    [[DSRuntimeBridge shared] trackFriendModel:result];
    return result;
}

static BOOL DSSettingsHooked = NO;
static BOOL DSCardStyleHooked = NO;
static BOOL DSMessageHooked = NO;
static BOOL DSReloadHooked = NO;
static BOOL DSUpdateHooked = NO;
static BOOL DSGlobalMessageHooked = NO;
static BOOL DSFriendHooked = NO;

static void DSInstallHooks(void) {
    Class settingsClass = objc_getClass("AWESettingBaseViewController");
    if (settingsClass && !DSCardStyleHooked) {
        SEL selector = NSSelectorFromString(@"useCardUIStyle");
        if (class_getInstanceMethod(settingsClass, selector)) {
            DSCardStyleHooked = DSHookInstanceMethod(settingsClass, selector, (IMP)DSNewUseCardUIStyle, (IMP *)&DSOldUseCardUIStyle);
        }
    }

    Class settingsViewModelClass = objc_getClass("AWESettingsViewModel");
    if (settingsViewModelClass && !DSSettingsHooked) {
        SEL selector = NSSelectorFromString(@"sectionDataArray");
        if (class_getInstanceMethod(settingsViewModelClass, selector)) {
            DSSettingsHooked = DSHookInstanceMethod(settingsViewModelClass, selector, (IMP)DSNewSectionDataArray, (IMP *)&DSOldSectionDataArray);
        }
    }

    Class messageClass = objc_getClass("AWEIMMessageListViewController");
    if (messageClass && !DSMessageHooked) {
        Method method = class_getInstanceMethod(messageClass, @selector(viewDidAppear:));
        if (method) {
            DSMessageHooked = DSHookInstanceMethod(messageClass, @selector(viewDidAppear:), (IMP)DSNewMessageViewDidAppear, (IMP *)&DSOldMessageViewDidAppear);
        }
    }
    if (messageClass && !DSReloadHooked) {
        SEL selector = NSSelectorFromString(@"vm_afterReloadData");
        Method method = class_getInstanceMethod(messageClass, selector);
        if (method) {
            DSReloadHooked = DSHookInstanceMethod(messageClass, selector, (IMP)DSNewAfterReloadData, (IMP *)&DSOldAfterReloadData);
        }
    }
    if (messageClass && !DSUpdateHooked) {
        SEL selector = NSSelectorFromString(@"vm_afterUpdateData");
        Method method = class_getInstanceMethod(messageClass, selector);
        if (method) {
            DSUpdateHooked = DSHookInstanceMethod(messageClass, selector, (IMP)DSNewAfterUpdateData, (IMP *)&DSOldAfterUpdateData);
        }
    }

    Class notifierClass = objc_getClass("TIMXOMessageNotifier");
    if (notifierClass && !DSGlobalMessageHooked) {
        SEL selector = NSSelectorFromString(@"onMessagesCreated:belongingConversationMap:reason:context:");
        Method method = class_getInstanceMethod(notifierClass, selector);
        if (method) {
            DSGlobalMessageHooked = DSHookInstanceMethod(notifierClass, selector, (IMP)DSNewMessagesCreated, (IMP *)&DSOldMessagesCreated);
        }
    }

    Class friendClass = objc_getClass("AWEIMFriendInfoDataModel");
    if (friendClass && !DSFriendHooked) {
        SEL selector = NSSelectorFromString(@"initWithIMUser:");
        Method method = class_getInstanceMethod(friendClass, selector);
        if (method) {
            DSFriendHooked = DSHookInstanceMethod(friendClass, selector, (IMP)DSNewFriendInit, (IMP *)&DSOldFriendInit);
        }
    }
}

static void DSScheduleHookRetries(NSInteger attempt) {
    DSInstallHooks();
    if ((DSSettingsHooked && DSMessageHooked && DSFriendHooked && DSGlobalMessageHooked) || attempt >= 60) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSScheduleHookRetries(attempt + 1);
    });
}

__attribute__((constructor)) static void DouyinDeepSeekInitialize(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DSAutoReplyEngine shared] startPolling];
            DSScheduleHookRetries(0);
            NSLog(@"[DouyinDeepSeek] loaded");
        });
    }
}
