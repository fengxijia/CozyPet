import Foundation
import PetCore

@MainActor
enum WorkflowRunner {
    /// Execute the side-effect part of a step (open app/URL/path).
    /// Returns true on best-effort success; "prompt" steps always return true.
    @discardableResult
    static func run(_ step: WorkflowStep) -> Bool {
        switch step.resolvedKind {
        case .app:
            guard let bundleID = step.openApp else { return false }
            // 如果同时给了 open_path，把路径交给指定 app（比如 iTerm 打开 ~/Code）
            if let path = step.openPath {
                return AppLauncher.openPath(path, withBundleID: bundleID)
            }
            return AppLauncher.openApp(bundleID: bundleID)
        case .url:
            guard let url = step.openURL else { return false }
            return AppLauncher.openURL(url)
        case .path:
            guard let path = step.openPath else { return false }
            return AppLauncher.openPath(path)
        case .prompt:
            return true
        }
    }
}
