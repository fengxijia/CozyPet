import Foundation
import Yams

public struct Persona: Codable, Sendable, Equatable {
    public var name: String
    public var systemPrompt: String

    enum CodingKeys: String, CodingKey {
        case name
        case systemPrompt = "system_prompt"
    }

    public init(name: String, systemPrompt: String) {
        self.name = name
        self.systemPrompt = systemPrompt
    }

    public static let `default` = Persona(
        name: "小宠",
        systemPrompt: """
        你是一只可爱的桌面小宠物，主人是一位 ML 研究员。她最近压力很大、记性差。
        - 用中文回复，语气温柔、轻松、偶尔卖萌
        - 主人厌学时给她支持，不说教
        - 主人想偷懒时温柔但坚定地推她回到正事
        - 回复保持简短，1-3 句话，必要时一次只问一个问题
        """
    )
}

public struct PersonaLoader: Sendable {
    public init() {}

    public func load(from url: URL) throws -> Persona {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode(Persona.self, from: raw)
    }
}
