import SwiftUI

@main
struct PetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Pet", systemImage: "pawprint.fill") {
            Button("今日工作流…") { appDelegate.openWorkflowPanel() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("和小宠聊天…") { appDelegate.openChat() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Menu("桌宠显示") {
                ForEach(PetDisplayMode.allCases, id: \.rawValue) { mode in
                    Button {
                        appDelegate.setDisplayMode(mode)
                    } label: {
                        // 当前模式前面打勾
                        if appDelegate.displayMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            }
            Divider()
            Button("设置…") { appDelegate.openSettings() }
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
