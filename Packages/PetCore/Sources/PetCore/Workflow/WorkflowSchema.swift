import Foundation

public enum StepKind: String, Codable, Sendable, CaseIterable {
    case app
    case url
    case path
    case prompt
}

/// 一个步骤可以挂多个动作，全部会被并行 / 顺序触发。
/// yaml 里长这样：
/// ```
/// - id: morning
///   say: "开工"
///   actions:
///     - kind: app
///       open_app: com.microsoft.VSCode
///       open_path: /Users/xixi/Code/pet
///     - kind: url
///       open_url: https://notion.so/x
/// ```
public struct StepAction: Codable, Hashable, Sendable, Identifiable {
    /// 仅用于 SwiftUI list 身份，不参与 Codable。每次 decode 重新生成。
    public let id: UUID
    public var kind: StepKind
    public var openApp: String?
    public var openURL: String?
    public var openPath: String?

    public init(
        kind: StepKind,
        openApp: String? = nil,
        openURL: String? = nil,
        openPath: String? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.openApp = openApp
        self.openURL = openURL
        self.openPath = openPath
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case openApp = "open_app"
        case openURL = "open_url"
        case openPath = "open_path"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.kind = try c.decode(StepKind.self, forKey: .kind)
        self.openApp = try c.decodeIfPresent(String.self, forKey: .openApp)
        self.openURL = try c.decodeIfPresent(String.self, forKey: .openURL)
        self.openPath = try c.decodeIfPresent(String.self, forKey: .openPath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(openApp, forKey: .openApp)
        try c.encodeIfPresent(openURL, forKey: .openURL)
        try c.encodeIfPresent(openPath, forKey: .openPath)
    }
}

public struct WorkflowStep: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var say: String?
    public var openApp: String?
    public var openURL: String?
    public var openPath: String?
    public var kind: StepKind?
    public var thenPrompt: String?
    /// 多动作。优先于 open_app / open_url / open_path 这些「老字段」。
    /// 老 yaml 没填这个 —— resolvedActions 会兜底用单动作字段构造一项。
    public var actions: [StepAction]?
    /// 归档：暂时不需要、但以后可能再提回今日日程的步骤。
    /// 可选，只在 true 时落盘；nil 即「未归档」，老 yaml 不受影响。读用 `isArchived`。
    public var archived: Bool?

    public init(
        id: String,
        say: String? = nil,
        openApp: String? = nil,
        openURL: String? = nil,
        openPath: String? = nil,
        kind: StepKind? = nil,
        thenPrompt: String? = nil,
        actions: [StepAction]? = nil,
        archived: Bool? = nil
    ) {
        self.id = id
        self.say = say
        self.openApp = openApp
        self.openURL = openURL
        self.openPath = openPath
        self.kind = kind
        self.thenPrompt = thenPrompt
        self.actions = actions
        self.archived = archived
    }

    enum CodingKeys: String, CodingKey {
        case id, say, kind, actions, archived
        case openApp = "open_app"
        case openURL = "open_url"
        case openPath = "open_path"
        case thenPrompt = "then_prompt"
    }

    /// 是否已归档（不在今日列表显示 / 不朗读 / 不计进度）。
    public var isArchived: Bool { archived ?? false }

    /// 单动作时给老 UI / runner 一个 best-guess 类型。多动作时返回第一项的 kind。
    public var resolvedKind: StepKind {
        if let kind { return kind }
        if let first = actions?.first { return first.kind }
        if openApp != nil { return .app }
        if openURL != nil { return .url }
        if openPath != nil { return .path }
        return .prompt
    }

    /// 这个步骤实际要执行的动作列表。
    /// - 优先用 `actions`（多动作场景）
    /// - 否则按老字段构造单元素列表
    /// - prompt 类型返回空数组（runner 视为"啥也不干"）
    public var resolvedActions: [StepAction] {
        if let actions, !actions.isEmpty { return actions }
        switch resolvedKind {
        case .prompt:
            return []
        case .app:
            guard let openApp else { return [] }
            return [StepAction(kind: .app, openApp: openApp, openPath: openPath)]
        case .url:
            guard let openURL else { return [] }
            return [StepAction(kind: .url, openURL: openURL)]
        case .path:
            guard let openPath else { return [] }
            return [StepAction(kind: .path, openPath: openPath)]
        }
    }
}

public struct Workflow: Codable, Sendable {
    public var name: String
    public var steps: [WorkflowStep]

    public init(name: String, steps: [WorkflowStep]) {
        self.name = name
        self.steps = steps
    }
}
