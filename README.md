# CozyPet

一只浮在 macOS 桌面上的小宠物，陪你写代码、提醒喝水、念几句强心的话。

> 起因：作者最近压力大、记性差，打开电脑常脑子一片空白，
> 就给自己造了只桌宠负责开屏催活、按 todo 提醒、心情差时陪聊。

---

## 它会做什么

- **浮窗桌宠** — 透明无边框 NSWindow，跨 Space / 跨全屏跟着你；可拖、可切换「完整 / 仅图标 / 隐藏」三种显示形态
- **今日工作流** — YAML 描述的 todo 列表，点一下启动对应 app / 网址 / 文件夹；首次打开自动念一遍清单
- **爱心便签** — 跟 todo 完全分开的一块小区域，写给自己的鼓励 / 提醒。可拖动排序、可调整与 todo 的高度占比、可点喇叭依次念出来，被打断后续读
- **桌宠聊天** — 桌宠脚下一行小输入条，回车直接发 Claude，流式打字回在头顶气泡里；persona 走 prompt caching
- **语音克隆** — 接 ElevenLabs，可以在设置里上传一段你想要的音色样本一键克隆，桌宠说话直接换你给的音色；同一段文字带磁盘缓存，再念就不走网络

---

## 跑起来

需要 macOS 14+ 和 Xcode 16+。

```sh
git clone https://github.com/fengxijia/CozyPet.git
open CozyPet/Pet_app/Pet_app.xcodeproj
```

Xcode 打开后第一次会自动拉 SwiftPM 依赖（Yams、SDWebImage），等 1-2 分钟。

**Signing**：左上角项目图标 → TARGETS → Pet_app → Signing & Capabilities → **Team** 选你自己的 Apple ID（没有就点 Add an Account 登一下，免费的 Personal Team 够用）。

⌘R 跑。

跑起来应该看到：

- 没有 Dock 图标（菜单栏程序）
- 屏幕右上角菜单栏多一只小爪子
- 屏幕右下角浮出一只桌宠（没塞图就是 emoji 🐾）

---

## 想用聊天 / 语音

菜单栏小爪子 → **设置**：

| Tab | 干嘛的 |
|---|---|
| 宠物 | 切换桌宠形象、改名字 |
| 对话 | 贴 Anthropic API key（去 console.anthropic.com 申请）；选 Claude 模型 |
| 语音 | 贴 ElevenLabs key + voice ID；或上传音频克隆音色 |
| 常规 | 自启动、persona 文件路径 |

都不填也能跑，只是桌宠只会显示气泡不会念出来。

---

## 自定义

工作流和宠物形象都在 `~/Library/Application Support/Pet/`：

```
workflow.yaml   — 今日工作流，每条 step 改 say + open_url / open_app / open_path
pets.yaml       — 多只宠物的元数据（图片前缀、名字）
notes.json      — 爱心便签（一般通过 UI 改）
persona.yaml    — 桌宠对话人格，热重载（改完不用重开 app）
tts-cache/      — ElevenLabs 合成结果的本地缓存（删掉会重新走网络）
```

`workflow.yaml` 的 step 长这样：

```yaml
name: "今日工作流"
steps:
  - id: check-todo
    say: "看看今天的待办是什么喵"
    kind: prompt           # 纯提醒，无动作；点"念一下"用 TTS 读这句话
  - id: open-notion
    say: "打开 Notion 看清单"
    open_url: "https://www.notion.so/"
  - id: open-iterm
    say: "顺手看下实验跑得怎么样"
    open_app: "com.googlecode.iterm2"
    open_path: "~/Code"    # 给指定 app 打开这个路径
```

---

## 工程结构

```
Packages/PetCore/         本地 SPM 包，纯逻辑（YAML 解析 / LLM / TTS / 持久化）
Pet_app/                  Xcode 项目（UI + AppKit 胶水）
  Pet_app/
    PetWindow/            浮窗、状态机、气泡、AppKit 拖拽
    Workflow/             工作流面板、爱心便签、step 启动器
    Chat/                 聊天 popover + 桌宠脚下输入条
    Settings/             四 tab 设置窗
    Voice/                ElevenLabs 播放
    System/               NSWorkspace 启动 app / URL / 文件夹
  Resources/              默认 workflow / persona YAML
```

桌宠跨 Space + 跨全屏靠 NSWindow.collectionBehavior 的 `.canJoinAllSpaces + .fullScreenAuxiliary`；
拖拽走 AppKit 原生 `performDrag(with:)`，零延迟跟手；
SwiftUI 部分通过 `@Observable PetStateMachine` 驱动表情 + 气泡。

---

## 已知限制

- borderless `.floating` 窗在 Keynote 全屏演示模式下会被压住，正常使用看不见
- ElevenLabs 免费档不支持音色克隆（需要 Starter $5/月），UI 会把 422 的错误透出来
- 自启动用 `SMAppService.mainApp.register()`，重命名 .app 后要在设置里重新注册一次
- App Sandbox 关着 —— 这是个人机器自用 app，需要 `NSWorkspace.open(bundleID:)` 任意应用

---

## License

MIT。喜欢就拿走改。
