import Foundation

/// 调本地 FastAPI（`tts-server/server.py`），让 Bert-VITS2 跑 xzjosh 训练的 Taffy 音色。
/// 服务的进程由 App 端 `LocalTTSServer` 拉起来，这里只负责 HTTP 调用 —— 协议一致就能套
/// `CachingTTSProvider` 共用磁盘缓存。
///
/// 服务端做了中英文分段（segment.py），所以这里直接发整段文本就行，无需在 Swift 里再切。
public struct LocalBertVITS2TTS: TTSProvider {
    public let baseURL: URL
    public let timeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:47322")!,
        timeout: TimeInterval = 120
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public func synthesize(_ text: String) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTSError.empty }

        var req = URLRequest(url: baseURL.appendingPathComponent("tts"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": trimmed])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            // 进程没起来 / 端口没监听 → URLSession 抛 .cannotConnectToHost
            let nse = error as NSError
            if nse.domain == NSURLErrorDomain,
               nse.code == NSURLErrorCannotConnectToHost || nse.code == NSURLErrorTimedOut {
                throw TTSError.serverNotRunning
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TTSError.http(http.statusCode, body)
        }
        guard !data.isEmpty else { throw TTSError.empty }
        return data
    }
}

/// 单独问一下健康状态（不强依赖 TTSProvider 协议；UI 拿来显示状态 pill）。
public struct LocalBertVITS2Health: Sendable {
    public let baseURL: URL
    public init(baseURL: URL = URL(string: "http://127.0.0.1:47322")!) {
        self.baseURL = baseURL
    }

    public enum Status: Sendable, Equatable {
        case ready
        case loading
        case idle  // 服务起来了但模型还没开始加载
        case error(String)
    }

    public func ping(timeout: TimeInterval = 2) async -> Status? {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let raw = (obj["status"] as? String) ?? ""
            switch raw {
            case "ready":   return .ready
            case "loading": return .loading
            case "idle":    return .idle
            case "error":   return .error((obj["error"] as? String) ?? "unknown")
            default:        return nil
            }
        } catch {
            return nil  // 服务没起 / 网络问题，nil 给上层解读为"未运行"
        }
    }
}
