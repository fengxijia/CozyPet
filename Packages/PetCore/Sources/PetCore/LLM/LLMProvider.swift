import Foundation

public struct LLMMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol LLMProvider: Sendable {
    /// Streams response text deltas. Caller concatenates them.
    func chat(persona: Persona, history: [LLMMessage]) -> AsyncThrowingStream<String, Error>
}

public enum LLMError: Error, CustomStringConvertible {
    case missingAPIKey
    case http(status: Int, body: String)
    case decoding(String)
    case transport(Error)

    public var description: String {
        switch self {
        case .missingAPIKey: return "缺 API key，去 Settings 贴一下"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(200))"
        case .decoding(let s): return "解码失败：\(s)"
        case .transport(let e): return "网络错误：\(e.localizedDescription)"
        }
    }
}
