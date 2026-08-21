# DouyinDeepSeek

## 0.4.1

- 修复 AI 回复开头不断累积 `[我说]` / `【某某说】` 的严重问题。
- 我方历史消息只以 `assistant` 纯正文传给模型，不再把身份标签混入回复风格。
- 兼容已经被旧版本污染的聊天历史：构建上下文和接收模型正文时都会循环清除开头的发言人标签。

## 0.4.0

- 正式支持群聊自动回复和“测试发话”，群聊不会再被主动跳过。
- 每条群聊消息独立保存发送者 ID 与昵称；昵称缺失时使用 `群成员(ID)`，不会把不同成员混成同一个“对方”。
- 群聊提示词明确账号主人、群名称、每句真实发送者和本次最新触发者；AI 以账号主人身份回复整个群聊，并优先回应触发者。
- 会话列表明确标注“私聊/群聊”，运行报错增加会话类型、已识别群成员数量和群聊后台能力。

## 0.3.0

- 修复严重问题：没有进入聊天框时，现在通过全局收信回调定位会话，并直接从 `TIMXOMessageManager` / `IESIMConversationDataManager` 加载最近历史，再生成和发送回复。
- 消息方向改为“我方 / 对方 / 未知”三态；方向未知的消息绝不冒充对方触发自动回复，也不会进入 AI 上下文。
- 控制器改回弱引用，只轮询当前可见聊天页；历史快照按消息 ID 单调合并，旧页面再也不能覆盖后台收到的新消息。
- 冷却结束会定时唤醒，API 与明确未调用的发信失败会有限重试；生成结果缓存复用，避免重复扣费。
- 自动回复和测试发话共用会话级发送锁与幂等操作 ID；原生发信已执行但回执较慢时，不再切 Yuki 重发同一句。
- 身份规则与自定义口吻合并为唯一一条系统提示；群聊默认跳过，避免把多个人混成同一联系人。

## 0.2.1

- 修复 AI 不知道双方身份：每次请求明确注入账号主人称呼与当前联系人昵称。
- 每条历史消息增加 `【谁说】` 标签，并明确规定 `assistant` 是账号主人此前说的话、`user` 是联系人说的话。
- 设置新增“我的称呼”，运行报错新增双方消息数量，方便检查角色识别是否正确。

## 0.2.0

- 删除真机证明会静默空转的 `AWEIMMessageListViewController sendMessage:` 路线。
- 固定使用 `AWEIMSendMessageController + TIMXOConversation` 真实 SDK 发信链。
- 发信后轮询会话新增消息；只有生成文本真实出现在会话中才报告成功，否则自动切换 Yuki 再试并继续验证。

## 0.1.9

- 根据 39.9.0 真机报错修复：会话列表给出的是 `AWEIMMessageConversation` UI 包装对象，现在自动解包其 `con` 后再交给 SDK 发信器。
- 会话控制器改为强引用，离开聊天进入设置后仍可执行控制器直发。
- 不再把“选择器被调用”当作成功；记录并检查抖音发信方法真实返回对象。

## 0.1.8

- 新增“复制运行报错”：记录控制器、会话对象、消息创建器、发信器、Yuki 兜底和每条选择器的实际调用结果。
- 测试发话失败时可一键复制完整报错，不再只显示一句没用的“发信失败”。

## 0.1.7

- 修复“DeepSeek 已生成但发信失败”：原生 39.9.0 发信链失败时，自动调用已加载的 Yuki 自动消息发送链兜底。
- 发信错误会明确显示会话对象、消息创建器和发信器的运行状态，方便继续定位设备差异。

给越狱/注入环境中的抖音 iOS 客户端增加 DeepSeek 私聊与群聊上下文自动回复。

## 已实现

- 像参考插件一样在抖音设置列表顶部增加 `DeepSeek AI` 独立分组和设置行。
- 设置入口直接 Hook `AWESettingsViewModel.sectionDataArray`，使用 `AWESettingItemModel` 与 `AWESettingSectionModel` 构建，不再依赖导航栏按钮。
- 总开关，可随时关闭自动回复。
- DeepSeek API Key 使用 iOS Keychain 保存，不写进源码、GitHub 或偏好 plist。
- API 地址、模型、思考模式、最大回复 Token 可配置。
- 默认使用 `deepseek-v4-flash`，也可切换 `deepseek-v4-pro`。
- “测试 DeepSeek API”会发起真实 `/chat/completions` 请求并显示结果。
- 兼容字符串和分段文本响应；若思考过程吃完输出 Token 导致 `content` 为空，会自动关闭思考模式并以更高 Token 上限重试一次。
- 39.9.0 使用真实的 `msg_messages`、`msg_conversation`、`contentText`、`sendFromMe` 接口读取上下文，并监听 `TIMXOMessageNotifier` 全局新消息回调，不再只盯着当前打开的聊天页。
- “测试发话”会先选择私聊或群聊，读取最近对话上下文，生成回复并自动发送。
- 正式自动回复同样携带最近 N 条上下文；我方消息映射为 `assistant`，私聊联系人及群内其他成员映射为 `user`，并逐句带真实发言人标签。
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
5. 进入抖音设置页，点击顶部的 `DeepSeek AI` 设置行。
6. 填写 API Key，先点“测试 DeepSeek API”。
7. 收到过新私聊或群聊消息的会话会自动出现在测试列表；也可以打开聊天页立即刷新会话信息。
8. 回到插件设置，点“测试发话”，选择私聊或群聊。插件会直接从抖音本地消息库加载上下文、生成并提交给发信接口。
9. 测试正常后再打开“启用自动回复”。

## 后台上下文如何读取

插件优先从 `TIMXOMessageManager` 直接读取本地会话历史，不依赖聊天页面。若消息库没有返回历史，插件会停止生成并记录错误，绝不会只拿一条新消息瞎回。

## 重要限制

- 抖音没有公开这套私信 API，类名和 selector 会随版本改变。GitHub Actions 编译成功只说明源码和工具链通过，不等于你的抖音版本真机链路已经通过。
- 群聊成员昵称取决于抖音本地消息对象；取不到昵称时会显示稳定的成员 ID，身份仍然互相隔离。
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
