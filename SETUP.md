# Pet — 桌宠 Setup（Lite v1）

> 重写过一版：原先要你在 Xcode 里点十几下"Add Files / Create groups / Add Package"，太乱了。现在 `Pet_app.xcodeproj` 已经把所有源码、本地 SPM 包、Resources、entitlements、Info.plist 设置全都打包进去了。装完 Xcode 直接 ⌘R 就跑。

---

## 当前目录结构（你不用动）

```
/Users/xixi/Code/pet/
├─ Packages/PetCore/                 ← 纯逻辑 SPM 包（项目自动引用）
├─ Pet_app/
│  ├─ Pet_app.xcodeproj              ← 双击它打开 Xcode
│  ├─ Pet_app/                       ← 应用层源码（Xcode 同步文件夹，加文件直接拖进 Finder 即可被识别）
│  │  ├─ PetApp.swift
│  │  ├─ AppDelegate.swift
│  │  ├─ Assets.xcassets             ← 桌宠图丢这里，命名 pet-idle
│  │  ├─ Chat/  PetWindow/  Settings/  System/  Workflow/
│  └─ Resources/                     ← YAML（也已加入 bundle）
│     ├─ default-persona.yaml
│     └─ sample-workflow.yaml
└─ SETUP.md
```

> Xcode 同步文件夹 = 你在 Finder 里加 / 删 swift 文件，Xcode 自动跟着加 / 删，不再有"组（group）"vs"文件夹"的区别。这就是为什么不需要再点 Add Files。

---

## 1. 打开项目

```sh
open /Users/xixi/Code/pet/Pet_app/Pet_app.xcodeproj
```

第一次打开会自动解析 `PetCore` 本地包（拉 Yams 依赖，可能要 1-2 分钟，看左下角进度条）。

---

## 2. Signing（一次性）

蓝色项目图标 → **TARGETS → Pet_app → Signing & Capabilities**：

- **Team**：选你的 Apple ID（没有的话点 "Add an Account" 登一下，免费的 Personal Team 就够了）
- **Signing Certificate**：保持 *Sign to Run Locally*

> App Sandbox 已在 Build Settings 里关掉（`ENABLE_APP_SANDBOX = NO`），不用管。

---

## 3. ⌘R 跑

第一次跑你应该看到：

- 没有 Dock 图标（`LSUIElement = YES` 已经设好）
- 右上角菜单栏出现一只小爪子 🐾
- 屏幕右下角浮出来一只 emoji 桌宠（🐾，因为你还没放图）
- 0.3 秒后自动弹「今日工作流」窗口，列出 5 个步骤

跑不起来看文末「排错」。

---

## 4. 配 Claude API Key

菜单栏小爪子 → **设置…** → 在 *ANTHROPIC_API_KEY* 字段贴 key → 关窗口（自动保存到 UserDefaults）。

> v1 明文存 UserDefaults。本机自用没事，别开 screenshare。v2 迁 Keychain。

然后菜单栏点 **和小宠聊天…**（或直接点桌宠）→ 输入「我好累」→ 应该看到流式回复。

---

## 5. 配你自己的工作流和 persona

```sh
mkdir -p ~/Library/Application\ Support/Pet
cp /Users/xixi/Code/pet/Pet_app/Resources/sample-workflow.yaml \
   ~/Library/Application\ Support/Pet/workflow.yaml
cp /Users/xixi/Code/pet/Pet_app/Resources/default-persona.yaml \
   ~/Library/Application\ Support/Pet/persona.yaml
```

改成你自己的内容。`workflow.yaml` 改完后回工作流面板点右上角刷新箭头就重读。app 启动时会优先读这俩用户文件，没有才回退到 bundle 里的样例。

---

## 6. 放你的桌宠图（可选）

把一张透明背景 PNG 拖进 Xcode 左侧的 `Assets.xcassets`，命名 image set 为 **pet-idle**。

没图也跑得起来——会显示 emoji（🐾）占位。

> 推荐 prompt（给 Midjourney / NanoBanana / Sora image 之类）：
> `chibi sticker, transparent background, soft pastel, full body, front facing, 512x512`
>
> 后续要换 GIF 动图，再加 SDWebImageSwiftUI 依赖（Xcode → File → Add Package Dependencies → 输 `https://github.com/SDWebImage/SDWebImageSwiftUI`），把 `Image` 换成 `AnimatedImage(name:)`。Lite v1 没接，能跑就先这样。

---

## 7. 端到端验证清单

- [ ] 编译运行无错误
- [ ] 菜单栏出现小爪子图标
- [ ] 桌宠浮在屏幕右下，能拖动
- [ ] 切 Space（左右滑桌面）桌宠跟着走
- [ ] 进全屏 app（比如全屏浏览器）桌宠仍在最前
- [ ] 工作流面板列出 5 个步骤
- [ ] 点「Notion」步骤的「启动」→ 浏览器打开 Notion
- [ ] 步骤打钩、关 app、再开 → 当日打钩状态还在
- [ ] 点桌宠 → 弹聊天窗
- [ ] 输入「我好累」→ Claude 流式回复，桌宠 speech bubble 同步显示
- [ ] [Anthropic dashboard](https://console.anthropic.com/) 看 `cache_read_input_tokens > 0`，确认 prompt cache 生效
- [ ] 改 `~/Library/Application Support/Pet/persona.yaml` 让它毒舌一点 → 下次对话风格变了

---

## 8. 跑 PetCore 单测（可选）

只在装了完整 Xcode 之后能跑（CLT 不带 swift-testing 框架）：

```sh
cd /Users/xixi/Code/pet/Packages/PetCore
swift test
```

或者在 Xcode 里 **⌘U**。

---

## 9. v2 待办（按优先级）

1. EventKit 拉今日 Calendar / Reminders
2. UNUserNotificationCenter 提醒（Apple Watch 自动转发）
3. `SMAppService.mainApp.register()` 登录自启动
4. API key 迁到 Keychain
5. iPhone Shortcut → 本地 HTTP 桥（127.0.0.1:47321）读 stand hours / 步数
6. Notion API provider
7. OpenAI / Ollama provider 切换
8. 多状态 GIF（接 SDWebImageSwiftUI）

---

## 排错

**"No such module 'PetCore'"** → 第一次打开时 SPM 包还没解析完。Xcode → File → Packages → Reset Package Caches，等左下角进度条转完再 ⌘R。

**"找不到 sample-workflow.yaml"** → 检查 Pet_app target 的 Build Phases → Copy Bundle Resources，应该能看到 `default-persona.yaml` 和 `sample-workflow.yaml`。如果没有，在 Xcode 左侧选中那两个文件，右键 → Show File Inspector → 勾上 Target Membership 里的 Pet_app。

**"401 unauthorized"** → API key 错了或没贴；Settings 里再贴一次。

**"NSWorkspace 启动失败"** → 你机器上没装那个 bundle id 的 app。改 `workflow.yaml` 里的 `open_app` 字段。常用 bundle id：`com.apple.Safari`、`com.google.Chrome`、`com.tinyspeck.slackmacgap`、`md.obsidian`、`com.googlecode.iterm2`。`mdfind "kMDItemKind == 'Application'"` 能列你装了什么。

**"桌宠点不动"** → 检查菜单栏「桌宠：幽灵模式」选项，可能不小心切到了。

**"项目打开就一片红"** → 大概率 SPM 还没解析；File → Packages → Resolve Package Versions，再 ⌘B。
