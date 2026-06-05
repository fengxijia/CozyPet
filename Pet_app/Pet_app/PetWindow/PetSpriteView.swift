import SwiftUI
import SDWebImageSwiftUI
import PetCore

struct PetSpriteView: View {
    @Bindable var state: PetStateMachine
    @ObservedObject var petStore: PetStore
    @ObservedObject var chat: ChatModel
    @ObservedObject var app: AppDelegate
    let onTap: () -> Void

    @State private var bobbing: CGFloat = 0
    /// 当前 mood 抽到的具体变体（用户自定义 file URL 或 bundle 资源）。nil 表示还没抽过。
    /// 只在 mood 切换 / 激活宠物切换 / 收到 .petSpritesChanged 时重抽，
    /// 避免每次 re-render 都换图导致闪烁。
    @State private var pickedSource: SpriteSource?

    var body: some View {
        switch app.displayMode {
        case .hidden:
            // 窗口本身已 orderOut；这里给个空视图防止意外被显示。
            Color.clear
        case .mini:
            miniBody
        case .full:
            fullBody
        }
    }

    private var fullBody: some View {
        // 间距要大于 sprite 最大 scaleEffect 造成的向上视觉溢出（160 × max 1.10 ≈ 8px）
        // —— scaleEffect 不参与布局，只增加视觉尺寸，留小了会盖住气泡。
        VStack(spacing: 10) {
            SpeechBubbleView(text: state.bubbleText, visible: state.bubbleVisible)
                // 收窄一点，少遮后面的字。横向更长的话会自动换行。
                .frame(maxWidth: 200)
                .animation(.easeInOut(duration: 0.25), value: state.bubbleVisible)

            ZStack {
                spriteForCurrentMood
                // AppKit 原生拖拽 —— 透明覆盖在 sprite 上，零延迟跟随鼠标。
                // 点一次（窗口没动）= tap；右键弹自己搭的 NSMenu。
                PetDragHandle(
                    onTap: {
                        state.noteInteraction()
                        onTap()
                    },
                    onDoubleTap: { app.setDisplayMode(.mini) },
                    onPickMode: { app.setDisplayMode($0) },
                    onSay: { state.say("嗨～", mood: .talk) },
                    onCycleMood: { state.cycleMood() }
                )
            }
            .frame(width: 160, height: 160)
            .scaleEffect(scaleForMood)
            .offset(y: bobbing)
            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: state.mood)
            .onAppear { startBobbing() }

            InlineChatBar(chat: chat)
                .frame(maxWidth: 200)
        }
        .padding(8)
    }

    /// 「仅图标」模式：只有一个小动图，双击回到完整模式（带气泡 + 输入条）。
    /// 单击不放大 —— 单击/拖拽用的是 NSWindow.performDrag，mini 窗口 110x110 小，
    /// 拖动时 origin 变化经常被判为 0，会被误识别成"点击"。所以放大门槛设成双击。
    /// 不显示气泡（mini 状态下用户主动收起来就是为了清屏，硬塞气泡反而打扰）。
    /// 拖拽 / 右键菜单仍然保留。
    private var miniBody: some View {
        ZStack {
            spriteForCurrentMood
            PetDragHandle(
                onTap: { state.noteInteraction() },
                onDoubleTap: { app.setDisplayMode(.full) },
                onPickMode: { app.setDisplayMode($0) },
                onSay: { state.say("嗨～", mood: .talk) },
                onCycleMood: { state.cycleMood() }
            )
        }
        .frame(width: 90, height: 90)
        .scaleEffect(scaleForMood)
        .offset(y: bobbing)
        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: state.mood)
        .onAppear { startBobbing() }
        .padding(8)
        .help("点一下展开输入条")
    }

    private func startBobbing() {
        guard bobbing == 0 else { return }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            bobbing = -6
        }
    }

    /// 解析一个 (prefix, mood) 到可加载资源：先查用户自定义目录（file URL），
    /// 再回退到 bundle 的 `<prefix>-<mood>`（GIF 文件或 asset catalog 位图）。
    private func resolve(prefix: String, mood: String) -> SpriteSource? {
        if let url = PetSprites.customSpriteURL(prefix: prefix, mood: mood) {
            return .gif(url)
        }
        return resolveSprite(name: "\(prefix)-\(mood)")
    }

    /// pickedSource 没命中时的回退链：
    /// 1. 当前宠物 + 当前 mood（用户图优先，其次 bundle）
    /// 2. confused 借 think 的表情
    /// 3. 当前宠物 + idle
    /// 4. 全局 pet-<mood>
    /// 5. 全局 pet-idle
    /// 全没就 emoji。
    private var fallbackCandidates: [SpriteSource] {
        let prefix = petStore.active.assetPrefix
        let mood = state.mood.rawValue
        var list: [SpriteSource] = []
        if let s = resolve(prefix: prefix, mood: mood) { list.append(s) }
        // 困惑没有自己的图时，借 think（思考表情）而不是 idle —— 表情上更接近
        if state.mood == .confused, let s = resolve(prefix: prefix, mood: "think") { list.append(s) }
        if let s = resolve(prefix: prefix, mood: "idle") { list.append(s) }
        if let s = resolve(prefix: "pet", mood: mood) { list.append(s) }
        if let s = resolve(prefix: "pet", mood: "idle") { list.append(s) }
        return list
    }

    /// 给当前 (active pet, mood) 抽一个变体。用户给了图就只在用户变体里抽
    /// （用户自定义全胜，不混 bundle）；否则扫 bundle 的 `<prefix>-<mood>`、`-2`…`-5`。
    /// 没抽到就置 nil，让 fallbackCandidates 兜底。
    private func repickVariant() {
        let prefix = petStore.active.assetPrefix
        let mood = state.mood.rawValue
        let userURLs = PetSprites.userSpriteURLs(prefix: prefix, mood: mood)
        if !userURLs.isEmpty {
            pickedSource = userURLs.randomElement().map(SpriteSource.gif)
            return
        }
        var bundle: [SpriteSource] = []
        for n in 1...5 {
            let name = n == 1 ? "\(prefix)-\(mood)" : "\(prefix)-\(mood)-\(n)"
            if let url = Bundle.main.url(forResource: name, withExtension: "gif") {
                bundle.append(.gif(url))
            } else if NSImage(named: name) != nil {
                bundle.append(.asset(name))
            }
        }
        pickedSource = bundle.randomElement()
    }

    /// 资源来源：bundle GIF 文件 / 用户自定义 file URL（都走 `.gif`，`AnimatedImage(url:)` 通吃
    /// GIF / PNG / WebP），或 asset catalog 位图（`.asset`）。
    private enum SpriteSource {
        case gif(URL)
        case asset(String)
    }

    private func resolveSprite(name: String) -> SpriteSource? {
        if let url = Bundle.main.url(forResource: name, withExtension: "gif") {
            return .gif(url)
        }
        if NSImage(named: name) != nil {
            return .asset(name)
        }
        return nil
    }

    @ViewBuilder
    private var spriteForCurrentMood: some View {
        // pickedSource 命中就直接用（`??` 短路，不必构建整条回退链）。
        let resolved = pickedSource ?? fallbackCandidates.first
        Group {
            switch resolved {
            case .gif(let url):
                AnimatedImage(url: url)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .asset(let name):
                AnimatedImage(name: name)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case nil:
                Text(placeholder).font(.system(size: 96))
            }
        }
        .onAppear { repickVariant() }
        .onChange(of: state.mood) { _, _ in repickVariant() }
        .onChange(of: petStore.roster.active) { _, _ in repickVariant() }
        .onReceive(NotificationCenter.default.publisher(for: .petSpritesChanged)) { _ in repickVariant() }
    }

    private var placeholder: String {
        switch state.mood {
        case .idle: "🐾"
        case .talk: "💬"
        case .think: "🤔"
        case .confused: "❓"
        case .remind: "🔔"
        case .sad: "🥺"
        case .cheer: "✨"
        case .angry: "😡"
        case .love: "💗"
        case .daze: "😶‍🌫️"
        case .sleep: "💤"
        }
    }

    private var scaleForMood: CGFloat {
        switch state.mood {
        case .talk: 1.05
        case .cheer: 1.10
        case .sad: 0.95
        case .sleep: 0.92
        case .think: 0.9
        case .confused: 1.0
        default: 1.0
        }
    }

}

/// 桌宠脚下的小输入条 —— 跟 SpeechBubbleView 同款 ultraThinMaterial + 圆角，
/// 不要那种纯白冷冰冰的对话框。回复直接通过 ChatModel 流回 state.bubbleText，
/// 桌宠头顶的气泡就会显示，所以这里只管"输入"。
private struct InlineChatBar: View {
    @ObservedObject var chat: ChatModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("和我说说…", text: $chat.input, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.pink.opacity(0.35), lineWidth: 0.8)
                )
                .focused($focused)
                .onSubmit { submit() }

            Button {
                submit()
            } label: {
                Image(systemName: chat.sending ? "stop.circle.fill" : "paperplane.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.pink.opacity(0.9))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(!chat.sending && chat.input.trimmingCharacters(in: .whitespaces).isEmpty)
            .help(chat.sending ? "停止" : "发送（Enter）")
        }
    }

    private func submit() {
        if chat.sending {
            chat.stop()
        } else {
            chat.send()
        }
    }
}

/// 透明的 AppKit 拖拽手柄。
/// SwiftUI 的 DragGesture 走 gesture pipeline，跟随鼠标会有可感的延迟；
/// `NSWindow.performDrag(with:)` 走 AppKit 原生 drag loop，跟系统标题栏一样跟手。
/// 同时承担：
/// - 点一下（窗口没动）→ onTap
/// - 双击 → onDoubleTap（mini ↔ full 切换；走 clickCount==2 提前返回，不走 performDrag）
/// - 右键 → 弹自己拼的 NSMenu（替代 SwiftUI 的 .contextMenu）
struct PetDragHandle: NSViewRepresentable {
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onPickMode: (PetDisplayMode) -> Void
    let onSay: () -> Void
    let onCycleMood: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = PetDragHandleView()
        v.apply(onTap: onTap, onDoubleTap: onDoubleTap, onPickMode: onPickMode, onSay: onSay, onCycleMood: onCycleMood)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? PetDragHandleView else { return }
        v.apply(onTap: onTap, onDoubleTap: onDoubleTap, onPickMode: onPickMode, onSay: onSay, onCycleMood: onCycleMood)
    }
}

final class PetDragHandleView: NSView {
    private var onTap: (() -> Void)?
    private var onDoubleTap: (() -> Void)?
    private var onPickMode: ((PetDisplayMode) -> Void)?
    private var onSay: (() -> Void)?
    private var onCycleMood: (() -> Void)?

    func apply(
        onTap: @escaping () -> Void,
        onDoubleTap: @escaping () -> Void,
        onPickMode: @escaping (PetDisplayMode) -> Void,
        onSay: @escaping () -> Void,
        onCycleMood: @escaping () -> Void
    ) {
        self.onTap = onTap
        self.onDoubleTap = onDoubleTap
        self.onPickMode = onPickMode
        self.onSay = onSay
        self.onCycleMood = onCycleMood
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 双击：直接走切换，不进 performDrag —— 否则双击的第二下会被拖拽逻辑吃掉
        if event.clickCount >= 2 {
            onDoubleTap?()
            return
        }
        guard let win = window else { return }
        let originBefore = win.frame.origin
        win.performDrag(with: event) // blocks until mouseUp；AppKit 原生 drag，零延迟
        if win.frame.origin == originBefore {
            // 没动 → 是一次点击
            onTap?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let sayItem = NSMenuItem(title: "说点什么", action: #selector(handleSay), keyEquivalent: "")
        sayItem.target = self
        menu.addItem(sayItem)

        let cycleItem = NSMenuItem(title: "循环换状态（debug）", action: #selector(handleCycle), keyEquivalent: "")
        cycleItem.target = self
        menu.addItem(cycleItem)

        menu.addItem(.separator())

        for mode in PetDisplayMode.allCases {
            let it = NSMenuItem(title: mode.label, action: #selector(handleMode(_:)), keyEquivalent: "")
            it.representedObject = mode.rawValue
            it.target = self
            menu.addItem(it)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func handleSay() { onSay?() }
    @objc private func handleCycle() { onCycleMood?() }
    @objc private func handleMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PetDisplayMode(rawValue: raw) else { return }
        onPickMode?(mode)
    }
}
