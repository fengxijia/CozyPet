import Foundation
import ServiceManagement

/// 包一层 `SMAppService.mainApp`，给 Settings 一个开机自启 toggle 用。
///
/// 注意：系统按当前 `.app` 的绝对路径注册登录项 —— 所以这个开关只有当 app 放在
/// `/Applications/CozyPet.app`（或其他稳定路径）时才长期有效。
/// 从 Xcode 直接 Run 的那份在 DerivedData 里，Clean Build 之后路径失效，登录项会变
/// 「not found」。 UI 文案里要把这个提醒带出来。
@MainActor
enum LoginItem {
    /// 当前是否已注册为登录项（包括「等待用户在系统设置里允许」的中间态）
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// 是否还需要去系统设置里手动点「允许」
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func enable() throws {
        try SMAppService.mainApp.register()
    }

    static func disable() throws {
        try SMAppService.mainApp.unregister()
    }

    /// 跳到「系统设置 → 通用 → 登录项」让用户去点允许
    static func openSystemLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
