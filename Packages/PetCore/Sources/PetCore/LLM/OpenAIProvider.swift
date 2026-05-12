import Foundation

/// OpenAI Chat Completions 协议的兼容 provider。
/// 适用于：OpenAI 官方、Google Gemini 的 OpenAI-compat 端点
/// (`https://generativelanguage.googleapis.com/v1beta/openai/`)、
/// OpenRouter、Ollama (`http://localhost:11434/v1/`)、自建 LiteLLM 等。
public struct OpenAIProvider: LLMProvider {
    public let apiKey: String
    public let model: String
    public let endpoint: URL
    public let session: URLSession

    public init(
        apiKey: String,
        model: String,
        baseURL: URL,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        // baseURL 末尾有没有斜杠都接受
        let trimmed = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        self.endpoint = URL(string: trimmed + "/chat/completions")!
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
                    req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "content-type")

                    var messages: [[String: String]] = [
                        ["role": "system", "content": persona.systemPrompt]
                    ]
                    for m in history {
                        messages.append(["role": m.role.rawValue, "content": m.content])
                    }
                    // 故意不带 max_tokens —— 让服务端按模型默认（通常等同上限）出。
                    let payload: [String: Any] = [
                        "model": model,
                        "stream": true,
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
                        let payloadStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payloadStr.isEmpty || payloadStr == "[DONE]" { continue }
                        guard let data = payloadStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let choices = obj["choices"] as? [[String: Any]],
                           let first = choices.first,
                           let delta = first["delta"] as? [String: Any],
                           let text = delta["content"] as? String,
                           !text.isEmpty {
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
