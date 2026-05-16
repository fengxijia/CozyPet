import Foundation
import PetCore

@MainActor
enum WorkflowRunner {
    /// 跑一个步骤的全部动作；prompt 步骤（无动作）也算成功。
    /// 多动作场景下，全部成功才返回 true；有一个失败就返回 false，但前面的依然会被执行。
    @discardableResult
    static func run(_ step: WorkflowStep) -> Bool {
        let actions = step.resolvedActions
        if actions.isEmpty {
            // prompt 步骤：纯提醒，没有动作
            return true
        }
        var allOK = true
        for action in actions {
            if !runAction(action) {
                allOK = false
            }
        }
        return allOK
    }

    private static func runAction(_ action: StepAction) -> Bool {
        switch action.kind {
        case .app:
            guard let bundleID = action.openApp else { return false }
            if let path = action.openPath {
                return AppLauncher.openPath(path, withBundleID: bundleID)
            }
            return AppLauncher.openApp(bundleID: bundleID)
        case .url:
            guard let url = action.openURL else { return false }
            return AppLauncher.openURL(url)
        case .path:
            guard let path = action.openPath else { return false }
            return AppLauncher.openPath(path)
        case .prompt:
            // 单个 action 类型为 prompt 意义不大；当作 no-op 成功。
            return true
        }
    }
}
