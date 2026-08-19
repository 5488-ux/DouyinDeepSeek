# DouyinDeepSeek

给越狱/注入环境中的抖音 iOS 客户端增加 DeepSeek 私信上下文自动回复。

## 已实现

- 抖音设置页右上角增加 DeepSeek 入口。
- 总开关，可随时关闭自动回复。
- DeepSeek API Key 使用 iOS Keychain 保存，不写进源码、GitHub 或偏好 plist。
- API 地址、模型、思考模式、最大回复 Token 可配置。
- 默认使用 `deepseek-v4-flash`，也可切换 `deepseek-v4-pro`。
- “测试 DeepSeek API”会发起真实 `/chat/completions` 请求并显示结果。
- “测试发话”会先选择联系人，读取最近对话上下文，生成回复并自动发送。
- 正式自动回复同样携带最近 N 条上下文；我方消息映射为 `assistant`，对方消息映射为 `user`。
- 首次捕获会话只建立基线，不会对旧消息突然补回复。
- 跳过自己发出的消息，同一会话防重复、串行生成并带冷却时间。
- 生成或冷却期间到达的新消息会保留为待处理消息，不再提前吞掉。
- 发信链路按参考插件使用 `AWEIMShareMessageCreater.sharedInstance` 和 `AWEIMSendMessageController.sharedInstance`。
- 工程面向抖音这种普通 App Store App 只编译 `arm64`，避免 Linux 云工具链产出带不兼容 ABI 警告的 `arm64e` slice。
- Hook 使用 Objective-C Runtime，不再链接 `CydiaSubstrate`，可供全能签直接注入 IPA。
- 同时云编译 rootless、rootful 两种 `.deb` 和全能签裸 `.dylib`。

## 参考 dylib 得到的兼容点

用户提供的 `Yuki.dylib` 是包含两个 slice 的 Fat Mach-O：arm64 和 arm64e。可见字符串证明它使用了以下抖音私有类/方法：

- `AWESettingBaseViewController`
- `AWEIMMessageListViewController`
- `AWEIMFriendInfoDataModel`
- `IESIMConversationUtility`
- `AWEIMShareMessageCreater`
- `AWEIMSendMessageController`
- `sendTextMessageWithContent:`
- `sendMessage:conversation:forwardMessage:mentionUsers:`
- `asyncGetConversationForIdentifier:completion:`

本项目只参考这些运行时接口和交互路径，未打包、复制或修改参考 dylib。

## 使用步骤

1. 在 GitHub 仓库打开 `Actions`。
2. 选择 `Build DouyinDeepSeek`，点 `Run workflow`。
3. 构建完成后下载：
   - `DouyinDeepSeek-rootless`：Dopamine、无根越狱等环境。
   - `DouyinDeepSeek-rootful`：传统 rootful 环境。
   - `DouyinDeepSeek-AllSign`：解压后把 `DouyinDeepSeek-AllSign.dylib` 注入抖音 IPA，再签名安装。
4. 用 Sileo、Zebra、Filza 或 `dpkg -i` 安装 `.deb`，然后彻底结束并重开抖音。
5. 进入抖音设置页，点右上角脑袋图标（旧系统显示 `AI`）。
6. 填写 API Key，先点“测试 DeepSeek API”。
7. 依次打开几个目标联系人的私信，让插件记录其上下文。
8. 回到插件设置，点“测试发话”，选择联系人。插件会结合上下文生成并提交给抖音发信接口；返回聊天确认消息真实送达。
9. 测试正常后再打开“启用自动回复”。

## 为什么测试联系人要先打开一次聊天

上下文不能凭空编。插件必须先从 `AWEIMMessageListViewController` 拿到真实消息数组，才能保证测试和自动回复都结合对话历史。没有抓到上下文时，测试发话会直接拒绝生成，不会拿一句孤零零的话瞎回。

## 重要限制

- 抖音没有公开这套私信 API，类名和 selector 会随版本改变。GitHub Actions 编译成功只说明源码和工具链通过，不等于你的抖音版本真机链路已经通过。
- 当前可靠触发点是已经被抖音创建过的消息控制器。彻底没打开过的会话可能要先进入一次，插件才能持续观察并取得上下文。
- 插件显示“已提交给抖音发信接口”只代表私有 selector 已成功调用，不代表抖音服务器已经确认送达；必须回聊天检查。
- 当前只把文本消息送给模型；图片、语音、分享卡片不会伪装成文本乱塞。
- 自动回复会消耗 DeepSeek API 余额。建议先用 `deepseek-v4-flash`、20 条上下文、15 秒冷却。
- 不要把 API Key 写进仓库、Actions Secret 日志或 issue。

## DeepSeek API

默认地址：

```text
https://api.deepseek.com/v1/chat/completions
```

默认模型：

```text
deepseek-v4-flash
```

旧的 `deepseek-chat` 和 `deepseek-reasoner` 已在 2026-07-24 弃用，所以工程不再拿旧模型名当默认值。

## 本地编译（可选）

```bash
export THEOS=~/theos
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

产物位于 `packages/`。

## 故障判断

- 设置页没有 AI 按钮：`AWESettingBaseViewController` 名称变了，先看插件里的 Hook 兼容性。
- API 测试 401：API Key 错误或失效。
- API 测试 404：API 地址或模型名错误。
- 能生成、不能发送：`AWEIMSendMessageController` 的 selector 漂了；先打开目标聊天再测一次。
- 完全不自动回复：确认总开关、API Key、会话已有上下文，并检查同会话冷却。

## 目录

```text
.
├── .github/workflows/build.yml
├── Sources/
├── DouyinDeepSeek.plist
├── Makefile
├── Tweak.xm
├── control
└── README.md
```

## 许可

MIT
