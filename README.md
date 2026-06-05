# CozyPet

打开电脑 脑袋空空 不知道从何开始？
每天重复打开一样的软件和网页 好繁琐？
心理阻力大 不想开始做事？
———
macOS 超治愈桌宠 + 工作流管理软件 CozyPet 来力！！

✨ 开机自动弹出你喜欢的角色，原音色读出当天工作流

✨ 一键启动每日必开的网页、软件和本地路径，再也不用每天挨个点开一样的软件

✨ 更有自定义便签时刻鼓励自己，帮你减轻痛苦，开启新的一天

快来试试吧 😛


> 起因：作者最近压力大、记性差，打开电脑常脑子一片空白，
> 就给自己造了只桌宠负责开屏催活、按 todo 提醒、心情差时陪聊。

---

## 它会做什么

- **降低心理阻力** — 开机即可看到你喜欢的角色！用角色的声音告诉你每天要做的事 跨应用 跨屏幕 随时陪伴你！
- **桌宠聊天** — 不想工作？不想学习？心情不好？来和桌宠聊天吧～原生自带taffy/doro 桌宠，可切换多个形象，开启语音回复即可用原角色声线对话，仿佛ta就在你身边！
- **今日工作流** — 可编辑的每日工作流列表，常用网站/软件一键导入，点启动键即可一键打开该任务所需的所有网站/软件；首次打开会自动用角色声线念一遍清单
- **爱心便签** — 前一天振作的原因，第二天就忘记？把对自己的 鼓励 / 感悟 / 安慰都写在便签里吧！每天起来提醒一遍！可以让桌面宠物念出来！
- **语音克隆** — 接 ElevenLabs，可以在设置里上传一段你想要的音色样本一键克隆，桌宠直接变成你给的音色！

---

## 下载即用（推荐 / Apple Silicon）

1. 去 [Releases](https://github.com/fengxijia/CozyPet/releases) 下载最新的 `CozyPet-vX.Y.Z-macOS-arm64.zip`。
2. 双击解压，把 `CozyPet.app` 拖到 `/Applications`。
3. **第一次启动**：因为 App 没经过 Apple 公证，直接双击会被 Gatekeeper 拦。
   - 在 Finder 里 **右键 → 打开**，弹窗里再点一次「打开」就好（这一步只用做一次）；
   - 或者去「系统设置 → 隐私与安全性」滚到底，点「仍要打开」。
4. 菜单栏右上会冒出一只小爪子 🐾，点它开始用。

> 第一次开启 Claude 聊天和 ElevenLabs 语音不需要自己申请 API key —— 默认走作者维护的代理服务，
> 共享速率限制内随便用。要切换到自己的 key 也可以，进 设置 → 对话 / 语音 改 Base URL 就行。
> 代理服务端代码在 [`proxy-server/`](./proxy-server/)，自部署说明在它的 README。
>
> 不想用云端 TTS / 想完全离线？设置 → 语音 切到「本地 Bert-VITS2」，按 [`tts-server/README.md`](./tts-server/README.md) 跑一次 `setup.sh` 拉模型权重就行。

---

## 自己 build（开发者）

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
| 宠物 | 切换桌宠形象（Taffy / Doro）、改名字 |
| 对话 | 贴 Anthropic API key（去 console.anthropic.com 申请）；选 Claude 模型 |
| 语音 | 选 TTS 后端 —— ElevenLabs（贴 key + voice ID，或上传音频克隆）/ 本地 Bert-VITS2（首次需要跑 `tts-server/setup.sh` 拉模型权重） |
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
tts-cache/      — 双后端共用的合成结果缓存，按「文本 + 音色」哈希（删掉会重新走网络 / 重新推理）
tts-server/     — 本地 Bert-VITS2 sidecar 的安装目录（首次跑 setup.sh 后才存在）
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
    Voice/                NSSound 播放 + 本地 Bert-VITS2 子进程生命周期管理
    System/               NSWorkspace 启动 app / URL / 文件夹
  Resources/              默认 workflow / persona YAML
tts-server/               可选的本地 TTS sidecar：FastAPI + Bert-VITS2 v2.3
```

桌宠跨 Space + 跨全屏靠 NSWindow.collectionBehavior 的 `.canJoinAllSpaces + .fullScreenAuxiliary`；
拖拽走 AppKit 原生 `performDrag(with:)`，零延迟跟手；
SwiftUI 部分通过 `@Observable PetStateMachine` 驱动表情 + 气泡。

---

## 已知限制

- **Keynote 全屏演示时桌宠会被盖住** —— 演讲模式下整个屏幕被独占，浮窗会被压在下面看不见；结束演示就自动回来，日常使用不受影响
- **ElevenLabs 免费账号克隆不了音色** —— 音色克隆是 ElevenLabs 的付费功能（最低 Starter 档 $5/月），免费账号上传声音样本会失败，UI 会直接把官方返回的错误提示给你看
- **重命名 / 移动 `CozyPet.app` 之后开机自启会失效** —— macOS 按 App 的位置和名字记自启规则，改了之后请回 设置 → 常规，把"开机自启动"关掉再打开一次就好
- **不会上架 Mac App Store** —— 工作流要"一键启动任意 App"必须关掉系统沙盒（App Sandbox），所以这个 App 只能直接下载 / 自己 build，没法走商店分发

---

## License

MIT。喜欢就拿走改。
