import Foundation

public enum ClaudeAuthMode: String, Sendable, CaseIterable {
    /// Anthropic 官方风格：x-api-key header
    case apiKey = "api_key"
    /// 第三方代理（aihubmix / OpenRouter / 自建 LiteLLM 等）常见的 Authorization: Bearer ...
    case authToken = "auth_token"
}

public struct ClaudeProvider: LLMProvider {
    public let apiKey: String
    public let model: String
    public let endpoint: URL
    public let authMode: ClaudeAuthMode
    public let session: URLSession

    /// Anthropic 的 /v1/messages 强制要 max_tokens，没法省。
    /// 直接挂一个比正常聊天大得多的值（opus-4 系列输出上限就是这个），
    /// 等于让模型自己决定什么时候停。
    private static let defaultMaxTokens = 32000

    public init(
        apiKey: String,
        model: String = "claude-opus-4-7",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        authMode: ClaudeAuthMode = .apiKey,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = baseURL.appendingPathComponent("v1/messages")
        self.authMode = authMode
        self.session = session
    }

    public func chat(persona: Persona, history: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanKey.isEmpty {
                        throw LLMError.missingAPIKey
                    }
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    switch authMode {
                    case .apiKey:
                        req.setValue(cleanKey, forHTTPHeaderField: "x-api-key")
                    case .authToken:
                        req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
                    }
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("application/json", forHTTPHeaderField: "content-type")

                    let systemBlock: [[String: Any]] = [[
                        "type": "text",
                        "text": persona.systemPrompt,
                        "cache_control": ["type": "ephemeral"],
                    ]]
                    let messages: [[String: Any]] = history.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }
                    let payload: [String: Any] = [
                        "model": model,
                        "max_tokens": Self.defaultMaxTokens,
                        "stream": true,
                        "system": systemBlock,
                        "messages": messages,
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n" }
                        throw LLMError.http(status: http.statusCode, body: body)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payloadStr = line
                            .dropFirst(5)
                            .trimmingCharacters(in: .whitespaces)
                        if payloadStr.isEmpty || payloadStr == "[DONE]" { continue }
                        guard let data = payloadStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let type = obj["type"] as? String,
                           type == "content_block_delta",
                           let delta = obj["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let e as LLMError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: LLMError.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
