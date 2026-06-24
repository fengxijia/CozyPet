import CryptoKit
import Foundation

public protocol TTSProvider: Sendable {
    /// 把一段文本合成成音频字节（MP3 / WAV，由实现决定）。
    func synthesize(_ text: String) async throws -> Data
}

public protocol SegmentedTTSProvider: TTSProvider {
    /// 把一段文本合成成多个可顺序播放的音频片段。
    func synthesizePieces(_ text: String) async throws -> [Data]
}

/// 给任意 TTSProvider 套一层磁盘缓存：相同输入（text + voiceKey）直接读 mp3 文件，
/// 不重新跑一次 ElevenLabs 请求。voiceKey 应该把 voice id / model / 风格参数都拼进去，
/// 否则换音色后会拿到旧缓存。
public struct CachingTTSProvider: TTSProvider {
    public let inner: any TTSProvider
    public let cacheDir: URL
    public let voiceKey: String

    public init(inner: any TTSProvider, cacheDir: URL, voiceKey: String) {
        self.inner = inner
        self.cacheDir = cacheDir
        self.voiceKey = voiceKey
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    public func synthesize(_ text: String) async throws -> Data {
        let file = cacheFile(for: text)
        if let cached = try? Data(contentsOf: file), !cached.isEmpty {
            return cached
        }
        let data = try await inner.synthesize(text)
        try? data.write(to: file, options: .atomic)
        return data
    }

    private func cacheFile(for text: String) -> URL {
        let payload = "\(voiceKey)\u{0001}\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hex).mp3")
    }
}

public enum TTSError: Error, LocalizedError {
    case missingAPIKey
    case missingVoiceID
    case http(Int, String)
    case empty
    case serverNotRunning

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "TTS API key 没配"
        case .missingVoiceID: "TTS voice id 没配"
        case .http(let code, let body): "TTS HTTP \(code): \(body)"
        case .empty: "TTS 返回为空"
        case .serverNotRunning: "本地 TTS 服务没启动 —— 去 设置→语音 看一下"
        }
    }
}

public struct ElevenLabsTTS: TTSProvider {
    public let apiKey: String
    public let voiceID: String
    public let modelID: String      // 例如 eleven_multilingual_v2 / eleven_turbo_v2_5
    public let baseURL: URL
    public let stability: Double
    public let similarityBoost: Double
    public let style: Double
    public let speakerBoost: Bool

    public init(
        apiKey: String,
        voiceID: String,
        modelID: String = "eleven_multilingual_v2",
        baseURL: URL = URL(string: "https://api.elevenlabs.io")!,
        stability: Double = 0.5,
        similarityBoost: Double = 0.75,
        style: Double = 0.0,
        speakerBoost: Bool = true
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID
        self.baseURL = baseURL
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.speakerBoost = speakerBoost
    }

    public func synthesize(_ text: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw TTSError.missingAPIKey }
        guard !voiceID.isEmpty else { throw TTSError.missingVoiceID }

        let url = baseURL.appendingPathComponent("v1/text-to-speech/\(voiceID)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": [
                "stability": stability,
                "similarity_boost": similarityBoost,
                "style": style,
                "use_speaker_boost": speakerBoost,
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
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

/// ElevenLabs Voice 资源管理：上传音频克隆音色。
/// 注意：免费档不支持，需要 Starter（$5/月）的 Instant Voice Cloning 才能调通。
public struct ElevenLabsVoices: Sendable {
    public let apiKey: String
    public let baseURL: URL

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.elevenlabs.io")!) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
    }

    /// POST /v1/voices/add — multipart/form-data, name + files[]。
    /// 成功返回新建 voice 的 voice_id；失败把 server body 透出来（free tier 拒绝时一目了然）。
    public func clone(name: String, description: String?, audioFiles: [URL]) async throws -> String {
        guard !apiKey.isEmpty else { throw TTSError.missingAPIKey }
        guard !audioFiles.isEmpty else { throw TTSError.empty }

        let url = baseURL.appendingPathComponent("v1/voices/add")
        let boundary = "Boundary-\(UUID().uuidString)"

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 120  // clone 比合成慢，给宽点

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        appendField(name: "name", value: name)
        if let description, !description.isEmpty {
            appendField(name: "description", value: description)
        }
        for fileURL in audioFiles {
            let data = try Data(contentsOf: fileURL)
            let filename = fileURL.lastPathComponent
            let mime = mimeType(for: fileURL.pathExtension.lowercased())
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        req.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw TTSError.http(http.statusCode, text)
        }
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let voiceID = json["voice_id"] as? String, !voiceID.isEmpty else {
            let text = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw TTSError.http(http.statusCode, "缺 voice_id：\(text)")
        }
        return voiceID
    }

    private func mimeType(for ext: String) -> String {
        switch ext {
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "m4a", "mp4": "audio/mp4"
        case "ogg", "oga": "audio/ogg"
        case "flac": "audio/flac"
        default: "application/octet-stream"
        }
    }
}
