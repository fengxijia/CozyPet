import AppKit
import Foundation

enum AppLauncher {
    /// Open a registered app by bundle identifier (e.g. "com.googlecode.iterm2").
    static func openApp(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        return true
    }

    /// Open the given path *inside* the specified app (so a folder opens in iTerm
    /// instead of Finder). If the app can't be found, falls back to default handler.
    static func openPath(_ path: String, withBundleID bundleID: String?) -> Bool {
        let pathURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if let bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([pathURL], withApplicationAt: appURL, configuration: cfg) { _, _ in }
            return true
        }
        return NSWorkspace.shared.open(pathURL)
    }

    /// Open any URL — http(s), notion://, mailto:, file:// …
    /// 用户写 `google.com` 也算数：没 scheme 自动补 `https://`。
    static func openURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let hasScheme = trimmed.range(
            of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*:"#,
            options: .regularExpression
        ) != nil
        let normalized = hasScheme ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Open path with default handler (folder → Finder).
    static func openPath(_ path: String) -> Bool {
        openPath(path, withBundleID: nil)
    }
}
