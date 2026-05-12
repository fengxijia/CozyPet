import Foundation

public enum StepKind: String, Codable, Sendable, CaseIterable {
    case app
    case url
    case path
    case prompt
}

public struct WorkflowStep: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var say: String?
    public var openApp: String?
    public var openURL: String?
    public var openPath: String?
    public var kind: StepKind?
    public var thenPrompt: String?

    public init(
        id: String,
        say: String? = nil,
        openApp: String? = nil,
        openURL: String? = nil,
        openPath: String? = nil,
        kind: StepKind? = nil,
        thenPrompt: String? = nil
    ) {
        self.id = id
        self.say = say
        self.openApp = openApp
        self.openURL = openURL
        self.openPath = openPath
        self.kind = kind
        self.thenPrompt = thenPrompt
    }

    enum CodingKeys: String, CodingKey {
        case id, say, kind
        case openApp = "open_app"
        case openURL = "open_url"
        case openPath = "open_path"
        case thenPrompt = "then_prompt"
    }

    public var resolvedKind: StepKind {
        if let kind { return kind }
        if openApp != nil { return .app }
        if openURL != nil { return .url }
        if openPath != nil { return .path }
        return .prompt
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
