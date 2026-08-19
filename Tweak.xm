#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "Sources/DSConfig.h"
#import "Sources/DSDeepSeekClient.h"
#import "Sources/DSRuntimeBridge.h"
#import "Sources/DSSettingsViewController.h"

static const NSInteger DSSettingsButtonTag = 0x44534149;
static const void *DSSettingsInjectedKey = &DSSettingsInjectedKey;

@interface DSAutoReplyEngine : NSObject
+ (instancetype)shared;
- (void)startPolling;
- (void)observeController:(id)controller;
@end

@interface DSAutoReplyEngine ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *lastSeenMessageIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *lastReplyDates;
@property (nonatomic, strong) NSMutableSet<NSString *> *busyConversationIDs;
@property (nonatomic, strong) NSHashTable *controllers;
@property (nonatomic, strong) NSTimer *pollTimer;
@end

@implementation DSAutoReplyEngine

+ (instancetype)shared {
    static DSAutoReplyEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engine = [[self alloc] init];
        engine.lastSeenMessageIDs = [NSMutableDictionary dictionary];
        engine.lastReplyDates = [NSMutableDictionary dictionary];
        engine.busyConversationIDs = [NSMutableSet set];
        engine.controllers = [NSHashTable weakObjectsHashTable];
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
        for (id controller in controllers) [strongEngine observeController:controller];
    }];
}

- (void)observeController:(id)controller {
    if (!controller) return;
    @synchronized (self.controllers) { [self.controllers addObject:controller]; }

    DSConversationSnapshot *conversation = [[DSRuntimeBridge shared] captureMessageController:controller];
    DSMessageSnapshot *latest = conversation.messages.lastObject;
    if (!conversation.conversationID.length || !latest.messageID.length) return;

    NSString *previousMessageID = self.lastSeenMessageIDs[conversation.conversationID];
    self.lastSeenMessageIDs[conversation.conversationID] = latest.messageID;

    // 第一次见到会话只建立基线，绝不拿旧消息突然回复。
    if (!previousMessageID.length) return;
    if ([previousMessageID isEqualToString:latest.messageID]) return;
    if (latest.outgoing || !latest.text.length) return;

    DSConfig *config = [DSConfig shared];
    if (!config.enabled || !config.apiKey.length) return;
    if ([self.busyConversationIDs containsObject:conversation.conversationID]) return;

    NSDate *lastReplyDate = self.lastReplyDates[conversation.conversationID];
    if (lastReplyDate && -lastReplyDate.timeIntervalSinceNow < config.cooldown) return;

    NSArray *context = [[DSRuntimeBridge shared] apiMessagesForConversation:conversation];
    if (!context.count) return;

    NSString *conversationID = [conversation.conversationID copy];
    [self.busyConversationIDs addObject:conversationID];
    [[DSDeepSeekClient shared] generateReplyWithMessages:context conversationID:conversationID completion:^(NSString *reply, NSError *error) {
        if (error || !reply.length) {
            NSLog(@"[DouyinDeepSeek] generation failed for %@: %@", conversationID, error.localizedDescription);
            [self.busyConversationIDs removeObject:conversationID];
            return;
        }
        if (![DSConfig shared].enabled) {
            [self.busyConversationIDs removeObject:conversationID];
            return;
        }
        DSConversationSnapshot *fresh = [[DSRuntimeBridge shared] conversationForID:conversationID] ?: conversation;
        [[DSRuntimeBridge shared] sendText:reply toConversation:fresh completion:^(BOOL success, NSError *sendError) {
            if (success) {
                self.lastReplyDates[conversationID] = NSDate.date;
                NSLog(@"[DouyinDeepSeek] context reply sent to %@", conversationID);
            } else {
                NSLog(@"[DouyinDeepSeek] send failed for %@: %@", conversationID, sendError.localizedDescription);
            }
            [self.busyConversationIDs removeObject:conversationID];
        }];
    }];
}

@end

static void DSOpenSettings(id self, SEL _cmd) {
    DSSettingsViewController *settings = [[DSSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *navigation = nil;
    if ([self isKindOfClass:UIViewController.class]) navigation = [(UIViewController *)self navigationController];
    if (navigation) {
        [navigation pushViewController:settings animated:YES];
    } else if ([self isKindOfClass:UIViewController.class]) {
        UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:settings];
        [(UIViewController *)self presentViewController:wrapper animated:YES completion:nil];
    }
}

static void DSInjectSettingsButton(UIViewController *controller) {
    if (!controller || objc_getAssociatedObject(controller, DSSettingsInjectedKey)) return;
    objc_setAssociatedObject(controller, DSSettingsInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImage *image = nil;
    if (@available(iOS 13.0, *)) image = [UIImage systemImageNamed:@"brain.head.profile"];
    UIBarButtonItem *item = image
        ? [[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain target:controller action:NSSelectorFromString(@"ds_openDeepSeekSettings")]
        : [[UIBarButtonItem alloc] initWithTitle:@"AI" style:UIBarButtonItemStylePlain target:controller action:NSSelectorFromString(@"ds_openDeepSeekSettings")];
    item.tag = DSSettingsButtonTag;
    item.accessibilityLabel = @"DeepSeek 自动回复";

    NSMutableArray *items = [controller.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    BOOL exists = NO;
    for (UIBarButtonItem *oldItem in items) if (oldItem.tag == DSSettingsButtonTag) exists = YES;
    if (!exists) [items insertObject:item atIndex:0];
    controller.navigationItem.rightBarButtonItems = items;
}

static void (*DSOldSettingsViewDidAppear)(id, SEL, BOOL);
static void DSNewSettingsViewDidAppear(id self, SEL _cmd, BOOL animated) {
    DSOldSettingsViewDidAppear(self, _cmd, animated);
    DSInjectSettingsButton((UIViewController *)self);
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

static id (*DSOldFriendInit)(id, SEL, id);
static id DSNewFriendInit(id self, SEL _cmd, id user) {
    id result = DSOldFriendInit(self, _cmd, user);
    [[DSRuntimeBridge shared] trackFriendModel:result];
    return result;
}

static BOOL DSSettingsHooked = NO;
static BOOL DSMessageHooked = NO;
static BOOL DSReloadHooked = NO;
static BOOL DSFriendHooked = NO;

static void DSInstallHooks(void) {
    Class settingsClass = objc_getClass("AWESettingBaseViewController");
    if (settingsClass && !DSSettingsHooked) {
        class_addMethod(settingsClass, NSSelectorFromString(@"ds_openDeepSeekSettings"), (IMP)DSOpenSettings, "v@:");
        Method method = class_getInstanceMethod(settingsClass, @selector(viewDidAppear:));
        if (method) {
            MSHookMessageEx(settingsClass, @selector(viewDidAppear:), (IMP)DSNewSettingsViewDidAppear, (IMP *)&DSOldSettingsViewDidAppear);
            DSSettingsHooked = YES;
        }
    }

    Class messageClass = objc_getClass("AWEIMMessageListViewController");
    if (messageClass && !DSMessageHooked) {
        Method method = class_getInstanceMethod(messageClass, @selector(viewDidAppear:));
        if (method) {
            MSHookMessageEx(messageClass, @selector(viewDidAppear:), (IMP)DSNewMessageViewDidAppear, (IMP *)&DSOldMessageViewDidAppear);
            DSMessageHooked = YES;
        }
    }
    if (messageClass && !DSReloadHooked) {
        SEL selector = NSSelectorFromString(@"vm_afterReloadData");
        Method method = class_getInstanceMethod(messageClass, selector);
        if (method) {
            MSHookMessageEx(messageClass, selector, (IMP)DSNewAfterReloadData, (IMP *)&DSOldAfterReloadData);
            DSReloadHooked = YES;
        }
    }

    Class friendClass = objc_getClass("AWEIMFriendInfoDataModel");
    if (friendClass && !DSFriendHooked) {
        SEL selector = NSSelectorFromString(@"initWithIMUser:");
        Method method = class_getInstanceMethod(friendClass, selector);
        if (method) {
            MSHookMessageEx(friendClass, selector, (IMP)DSNewFriendInit, (IMP *)&DSOldFriendInit);
            DSFriendHooked = YES;
        }
    }
}

static void DSScheduleHookRetries(NSInteger attempt) {
    DSInstallHooks();
    if ((DSSettingsHooked && DSMessageHooked && DSFriendHooked) || attempt >= 30) return;
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
