import AppKit
import Combine
import SDWebImage
import SwiftUI
import PetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private(set) var petWindowController: PetWindowController?
    private var workflowWindow: NSWindow?
    private var chatWindow: NSWindow?
    private var settingsWindow: NSWindow?

    let workflowStore = WorkflowStore()
    let petStore = PetStore()
    let voice = VoicePlayer()
    /// state 现在依赖 voice + Settings.makeTTSProvider 注入，所以延迟初始化。
    /// 这样所有桌宠 say() 都会自动走 TTS（开屏、提醒、聊天回复）。
    lazy var state: PetStateMachine = PetStateMachine(
        voice: voice,
        ttsProviderFactory: { SettingsView.makeTTSProvider() }
    )
    /// 桌宠下面那条小输入框直接绑这个 ChatModel —— 跟菜单"和小宠聊天…"打开的历史
    /// 窗口共享同一份 messages，所以无论从哪里发的话上下文都连得上。
    lazy var chat: ChatModel = ChatModel(state: state, petStore: petStore, voice: voice)

    /// 本次启动是否已经念过一遍 workflow todo —— 念过一次就够，再开面板只说开场白。
    /// 关闭 app 再开会重置（实例本身被销毁）。
    private var didReadWorkflowThisLaunch = false

    /// 显示形态：完整 / 仅图标 / 隐藏。持久化到 UserDefaults。
    @Published var displayMode: PetDisplayMode = {
        let raw = UserDefaults.standard.string(forKey: "pet.displayMode") ?? PetDisplayMode.full.rawValue
        return PetDisplayMode(rawValue: raw) ?? .full
    }()

    func setDisplayMode(_ mode: PetDisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "pet.displayMode")
        petWindowController?.applyDisplayMode(mode)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        invalidatePetGifCache()
        showPet()
        // 登录后第一件事：弹工作流面板。哪怕工作流为空也提示用户去配置。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.openWorkflowPanel()
        }
        // 本地 Taffy TTS 服务：仅当 backend 选了本地 & 总开关打开时自动拉起。
        syncLocalTTSServerWithSettings()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTTSBackendChanged),
            name: .ttsBackendChanged, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 不让 Python 子进程变孤儿
        LocalTTSServer.shared.stop()
    }

    @objc private func handleTTSBackendChanged() {
        syncLocalTTSServerWithSettings()
    }

    /// 根据 UserDefaults 里的 backend 决定本地 server 起 / 停。
    private func syncLocalTTSServerWithSettings() {
        let d = UserDefaults.standard
        let backend = TTSBackend(rawValue: d.string(forKey: SettingsKeys.ttsBackend) ?? "")
            ?? .elevenlabs
        let enabled = d.bool(forKey: SettingsKeys.ttsEnabled)
        if backend == .bertVITS2Local && enabled {
            LocalTTSServer.shared.startIfNeeded()
        } else {
            LocalTTSServer.shared.stop()
        }
    }

    /// SDWebImage 用 URL 字符串当 cache key —— 我们的桌宠 GIF 在 bundle 里
    /// `cp` 覆盖文件后路径不变，缓存就会一直返回旧帧。每次启动主动失效一下，
    /// 这样换图后只需重启 app 就能看到新表情。
    private func invalidatePetGifCache() {
        guard let dir = Bundle.main.resourceURL else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        let cache = SDImageCache.shared
        for url in urls where url.pathExtension.lowercased() == "gif" {
            cache.removeImage(forKey: url.absoluteString, fromDisk: true)
        }
        cache.clearMemory()
    }

    // MARK: - Pet window

    func showPet() {
        if petWindowController == nil {
            petWindowController = PetWindowController(state: state, petStore: petStore, chat: chat, app: self) { [weak self] in
                // 点桌宠本体只是抚摸 —— 输入条永远在桌宠下面，想说话直接点输入框就行。
                self?.state.noteInteraction()
            }
        }
        // 启动时尊重持久化的显示模式（除了「隐藏」之外都要 orderFront）
        if displayMode == .hidden {
            // 用户上次选了隐藏，那就别冒出来；菜单栏图标还在，他要回来就点
            petWindowController?.applyDisplayMode(.hidden)
        } else {
            petWindowController?.showPet()
            petWindowController?.applyDisplayMode(displayMode)
        }
    }

    // MARK: - Auxiliary windows

    func openWorkflowPanel() {
        if workflowWindow == nil {
            let view = WorkflowPanel(state: state, store: workflowStore, voice: voice)
            workflowWindow = makeUtilityWindow(title: "今日工作流", content: view)
        }
        workflowWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if didReadWorkflowThisLaunch {
            // 这次启动已经念过了 —— 后续再开面板只说开场白，不再唠叨整条 todo。
            state.say("今天先做这几件事～", mood: .remind, autoHideAfter: 30)
            return
        }
        didReadWorkflowThisLaunch = true
        let steps = workflowStore.workflow?.steps ?? []
        state.say("今天先做这几件事～", mood: .remind, autoHideAfter: 30) { [weak self] natural in
            guard natural else { return }
            self?.readWorkflowSteps(steps, at: 0)
        }
    }

    /// 念完一条工作流的 say，自然结束才接下一条；
    /// 用户中途点了启动 / 别的 state.say 抢走音频会拿到 natural=false，链式自动断掉。
    /// 不切表情：有些 step 内容是凶 / 丧的，切 .talk 反而违和；保持当前表情即可。
    private func readWorkflowSteps(_ steps: [WorkflowStep], at idx: Int) {
        guard idx < steps.count else { return }
        let line = steps[idx].say ?? steps[idx].id
        state.say(line, mood: state.mood, autoHideAfter: 8) { [weak self] natural in
            guard natural else { return }
            self?.readWorkflowSteps(steps, at: idx + 1)
        }
    }

    /// 菜单"和小宠聊天…" 走这里；用来翻历史。日常发消息直接用桌宠下面那条 InlineChatBar。
    func openChat() {
        if chatWindow == nil {
            let view = ChatView(state: state, petStore: petStore, voice: voice, model: chat)
            chatWindow = makeUtilityWindow(title: "和\(petStore.active.name)的聊天记录", content: view)
        }
        chatWindow?.title = "和\(petStore.active.name)的聊天记录"
        chatWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(petStore: petStore)
            settingsWindow = makeUtilityWindow(title: "设置", content: view)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 给 utility 窗口一个合理初始尺寸 + 允许用户自由拖大小。
    /// 注意：故意不设 `hosting.preferredContentSize` —— 它会反向钳制窗口尺寸，导致拖不动。
    private func makeUtilityWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        // 初始尺寸偏小：宁可让用户拖大，也别一开就糊脸
        let maxAllowed = NSSize(
            width: min(620, visible.width - 80),
            height: min(620, visible.height - 80)
        )
        let hosting = NSHostingController(rootView: content)
        let fit = hosting.sizeThatFits(in: maxAllowed)
        let size = NSSize(
            width: max(420, min(fit.width, maxAllowed.width)),
            height: max(360, min(fit.height, maxAllowed.height))
        )

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.contentMinSize = NSSize(width: 380, height: 320)
        win.contentViewController = hosting
        win.setContentSize(size)
        win.center()
        win.isReleasedWhenClosed = false
        return win
    }
}
