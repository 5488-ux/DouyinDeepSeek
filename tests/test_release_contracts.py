import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def method_body(source, signature, next_signature):
    start = source.index(signature)
    end = source.index(next_signature, start)
    return source[start:end]


def last_method_body(source, signature, next_signature):
    start = source.rindex(signature)
    end = source.index(next_signature, start)
    return source[start:end]


class ReleaseContracts(unittest.TestCase):
    def test_identity_labels_and_unknown_filter(self):
        source = read("Sources/DSRuntimeBridge.m")
        body = method_body(source, "- (NSArray<NSDictionary", "- (BOOL)sendTextThroughYuki")
        self.assertIn("ownerName", body)
        self.assertIn("contactName", body)
        self.assertIn("DSMessageDirectionUnknown", body)
        self.assertIn('@"assistant" : @"user"', body)
        self.assertIn("【%@说】", body)
        self.assertIn("outgoing ? cleanText", body)
        self.assertIn("DSStripLeadingSpeakerLabels", body)

    def test_generated_reply_strips_repeated_speaker_labels(self):
        client = read("Sources/DSDeepSeekClient.m")
        cleaner = method_body(client, "static NSString *DSStripGeneratedSpeakerLabels", "@interface DSDeepSeekClient")
        self.assertIn('hasPrefix:@"["', cleaner)
        self.assertIn('hasPrefix:@"【"', cleaner)
        self.assertIn('hasSuffix:@"说"', cleaner)
        self.assertIn("index < 32", cleaner)
        self.assertIn("reply = DSStripGeneratedSpeakerLabels(reply);", client)
        bridge = read("Sources/DSRuntimeBridge.m")
        context = method_body(bridge, "- (NSArray<NSDictionary", "- (BOOL)sendTextThroughYuki")
        self.assertIn("严禁输出或复制任何", context)

    def test_ai_send_audit_is_local_and_never_changes_chat_text(self):
        header = read("Sources/DSRuntimeBridge.h")
        bridge = read("Sources/DSRuntimeBridge.m")
        settings = read("Sources/DSSettingsViewController.m")
        log_ui = read("Sources/DSAISendLogViewController.m")
        makefile = read("Makefile")
        self.assertIn("aiSendRecords", header)
        self.assertIn("clearAISendRecords", header)
        self.assertIn("DouyinDeepSeek.aiSendRecords", bridge)
        self.assertIn("self.storedAISendRecords.count > 500", bridge)
        self.assertIn('@"AI自动回复" : @"AI测试发话"', bridge)
        send = method_body(bridge, "- (void)sendText:(NSString *)text\n  toConversation", "- (id)messageObjectForText")
        self.assertIn("recordAISendOperation", send)
        self.assertIn("invokeSendController:sender text:text", send)
        self.assertNotIn("stringByAppendingString:@\"AI自动发送\"", send)
        self.assertIn("DSSettingsSectionAudit", settings)
        self.assertIn("AI发送记录", settings)
        self.assertIn("复制全部记录", log_ui)
        self.assertIn("清空全部记录", log_ui)
        self.assertIn("不会添加任何“AI自动发送”字样", log_ui)
        self.assertIn("Sources/DSAISendLogViewController.m", makefile)

    def test_direction_is_three_state_and_unknown_never_queues(self):
        header = read("Sources/DSRuntimeBridge.h")
        bridge = read("Sources/DSRuntimeBridge.m")
        tweak = read("Tweak.xm")
        for name in ("DSMessageDirectionUnknown", "DSMessageDirectionIncoming", "DSMessageDirectionOutgoing"):
            self.assertIn(name, header)
        direction = method_body(bridge, "- (DSMessageDirection)messageDirectionFromObject", "- (NSTimeInterval)messageTimestamp")
        self.assertIn("return DSMessageDirectionUnknown", direction)
        self.assertIn("currentSDKLoginUserID", bridge)
        self.assertGreaterEqual(tweak.count("latest.direction != DSMessageDirectionIncoming"), 2)

    def test_capture_merges_and_controller_is_weak(self):
        header = read("Sources/DSRuntimeBridge.h")
        bridge = read("Sources/DSRuntimeBridge.m")
        capture = method_body(bridge, "- (DSConversationSnapshot *)captureMessageController", "- (id)conversationForID:")
        self.assertIn("weak, nullable", header)
        self.assertIn("mergeMessages:messages existing:snapshot.messages", capture)
        self.assertNotIn("snapshot.messages = messages;", capture)
        merge = method_body(bridge, "- (NSArray<DSMessageSnapshot *> *)mergeMessages", "- (BOOL)isDirectConversationObject")
        self.assertIn("byID", merge)
        self.assertIn("result.count > 100", merge)
        self.assertIn("DSMessageDirectionUnknown", merge)

    def test_background_history_hydration(self):
        bridge = read("Sources/DSRuntimeBridge.m")
        tweak = read("Tweak.xm")
        self.assertIn("messagesInConversation:excludeMessageTypes:limit:", bridge)
        self.assertIn("getMessagesInConversation:limit:", bridge)
        self.assertIn("hydrateConversation:conversation", tweak)
        self.assertIn("!fresh.historyHydrated", tweak)
        self.assertIn("skip unsupported conversation", tweak)

    def test_group_chat_keeps_each_sender_identity(self):
        header = read("Sources/DSRuntimeBridge.h")
        bridge = read("Sources/DSRuntimeBridge.m")
        tweak = read("Tweak.xm")
        settings = read("Sources/DSSettingsViewController.m")
        self.assertIn("senderID", header)
        self.assertIn("senderName", header)
        self.assertIn("groupConversation", header)
        self.assertIn("isGroupConversationObject", bridge)
        self.assertIn('senderProfile.senderNickName', bridge)
        self.assertIn('participantsMap', bridge)
        self.assertIn('@"0:2:"', bridge)
        self.assertIn("群成员(%@)", bridge)
        self.assertIn("绝不能把不同成员混成一个人", bridge)
        self.assertIn("当前需要回复的主要对象", bridge)
        self.assertIn("conversation.directConversation && !conversation.groupConversation", tweak)
        self.assertNotIn("暂不支持群聊", settings)

    def test_group_context_labels_and_sender_merge(self):
        bridge = read("Sources/DSRuntimeBridge.m")
        snapshots = method_body(bridge, "- (NSArray<DSMessageSnapshot *> *)messageSnapshotsFromRawMessages", "- (NSArray<DSMessageSnapshot *> *)mergeMessages")
        merge = method_body(bridge, "- (NSArray<DSMessageSnapshot *> *)mergeMessages", "- (BOOL)isDirectConversationObject")
        context = method_body(bridge, "- (NSArray<NSDictionary", "- (BOOL)sendTextThroughYuki")
        self.assertIn("senderIDFromObject", snapshots)
        self.assertIn("senderNameFromObject", snapshots)
        self.assertIn("old.senderID", merge)
        self.assertIn("old.senderName", merge)
        self.assertIn("speakerForMessage", context)
        self.assertIn('conversation.groupConversation ? @"群聊" : @"私聊"', context)

    def test_cooldown_has_wakeup_and_retry_limit(self):
        tweak = read("Tweak.xm")
        cooldown = last_method_body(tweak, "- (void)processPendingConversation", "@end")
        self.assertIn("config.cooldown - elapsed", cooldown)
        self.assertIn("scheduleRetryForConversationID", cooldown)
        scheduler = method_body(tweak, "- (void)scheduleRetryForConversationID", "- (void)clearPendingConversationID")
        self.assertIn("dispatch_after", scheduler)
        self.assertIn("count > 3", scheduler)
        self.assertIn("wakeupTokens", scheduler)

    def test_single_system_prompt(self):
        client = read("Sources/DSDeepSeekClient.m")
        generate = method_body(client, "- (void)generateReplyWithMessages", "- (NSString *)safeUserID")
        self.assertIn("alreadyHasSystem", generate)
        self.assertNotIn("arrayWithObject", generate)
        bridge = read("Sources/DSRuntimeBridge.m")
        context = method_body(bridge, "- (NSArray<NSDictionary", "- (BOOL)sendTextThroughYuki")
        self.assertIn("config.systemPrompt", context)

    def test_send_is_locked_idempotent_and_no_blind_fallback(self):
        bridge = read("Sources/DSRuntimeBridge.m")
        send = method_body(bridge, "- (void)sendText:(NSString *)text\n  toConversation", "- (id)messageObjectForText")
        self.assertIn("activeSendConversationIDs", send)
        self.assertIn("completedSendOperations", send)
        self.assertIn("原生发信已执行但暂未观测到回执", send)
        self.assertNotIn("原生发信无真实确认，转 Yuki", send)
        confirmation = method_body(bridge, "- (void)waitForSentText", "- (void)attemptYukiSendText")
        self.assertIn("DSMessageDirectionOutgoing", confirmation)
        self.assertIn("notBefore", confirmation)

    def test_version_consistency(self):
        control = re.search(r"^Version:\s*(\S+)", read("control"), re.M).group(1)
        tweak = re.search(r'setDetail:\", @\"([^\"]+)', read("Tweak.xm")).group(1)
        diagnostic = re.search(r"插件版本：([^\\]+)\\n", read("Sources/DSRuntimeBridge.m")).group(1)
        readme = re.search(r"^##\s+([^\s]+)", read("README.md"), re.M).group(1)
        self.assertEqual({control, tweak, diagnostic, readme}, {"0.5.0"})


if __name__ == "__main__":
    unittest.main()
