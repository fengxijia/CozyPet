import AppKit
import SwiftUI

/// 桌宠在屏幕上的显示形态。
/// - `full`：完整模式 —— 气泡 + 桌宠 + 输入条
/// - `mini`：仅图标 —— 只剩一个小动图，点一下回到完整模式
/// - `hidden`：藏起来 —— 整个浮窗 orderOut，只剩菜单栏图标
enum PetDisplayMode: String, CaseIterable {
    case full
    case mini
    case hidden

    var label: String {
        switch self {
        case .full: "完整"
        case .mini: "仅图标"
        case .hidden: "隐藏"
        }
    }

    /// 该模式下浮窗的 content size
    var windowSize: NSSize {
        switch self {
        case .full: NSSize(width: 280, height: 340)
        case .mini: NSSize(width: 110, height: 110)
        case .hidden: NSSize(width: 280, height: 340) // 不显示，尺寸无意义；保持原值方便复原
        }
    }
}

/// Borderless 浮窗默认 `canBecomeKey == false`，导致在非 key 屏幕上首次点击被系统吞掉
/// （不会送到 SwiftUI gesture），桌宠看起来就「拖不动」。重写一下让它能成为 key。
final class PetFloatWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 让 hosting 区接受 first mouse —— 否则跨 app 切到桌宠所在屏，第一次点击只激活窗口、
/// 不会触发 DragGesture，需要点第二次才能拖。
///
/// 这里故意写死成 `NSHostingView<PetSpriteView>` 而非泛型：Swift 6.3 编译器在 Release `-O`
/// 优化「泛型子类的隐式 deinit」时 inliner 会 segfault。锁死一种 Content 类型就绕过去了。
final class FirstMouseHostingView: NSHostingView<PetSpriteView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PetWindowController: NSWindowController {
    private let state: PetStateMachine
    private let petStore: PetStore
    private let chat: ChatModel
    private weak var app: AppDelegate?
    private let onTap: () -> Void

    init(state: PetStateMachine, petStore: PetStore, chat: ChatModel, app: AppDelegate, onTap: @escaping () -> Void) {
        self.state = state
        self.petStore = petStore
        self.chat = chat
        self.app = app
        self.onTap = onTap

        let rootView = PetSpriteView(state: state, petStore: petStore, chat: chat, app: app, onTap: onTap)
        let hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        // 底下要塞一个输入条，所以比纯 sprite 时高一点、宽一点
        let size = NSSize(width: 280, height: 340)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screen.maxX - size.width - 40,
            y: screen.minY + 80
        )
        let win = PetFloatWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = hostingView
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        win.isMovableByWindowBackground = true
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true
        super.init(window: win)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    func showPet() {
        window?.orderFrontRegardless()
    }

    /// 切换显示模式。负责窗口层面的尺寸 / 显隐；
    /// PetSpriteView 自己通过 @ObservedObject 观察 AppDelegate.displayMode 来切内容。
    /// 缩放时保持「窗口底部中线」不动 —— 桌宠在用户视野里看起来像是缩在原地，而不是飘到角落。
    func applyDisplayMode(_ mode: PetDisplayMode) {
        guard let win = window else { return }
        switch mode {
        case .hidden:
            win.orderOut(nil)
        case .full, .mini:
            let oldFrame = win.frame
            let oldBottomCenter = NSPoint(x: oldFrame.midX, y: oldFrame.minY)
            let newSize = mode.windowSize
            win.setContentSize(newSize)
            let newFrame = win.frame
            let dx = oldBottomCenter.x - newFrame.midX
            win.setFrameOrigin(NSPoint(x: newFrame.origin.x + dx, y: oldBottomCenter.y))
            if !win.isVisible {
                win.orderFrontRegardless()
            }
        }
    }
}
