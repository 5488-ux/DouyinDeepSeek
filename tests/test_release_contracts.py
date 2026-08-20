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
        self.assertIn("skip non-direct conversation", tweak)

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
        self.assertEqual({control, tweak, diagnostic, readme}, {"0.3.0"})


if __name__ == "__main__":
    unittest.main()
