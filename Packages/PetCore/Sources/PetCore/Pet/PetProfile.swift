import Foundation
import Yams

public struct PetProfile: Codable, Identifiable, Sendable, Equatable {
    /// 内部稳定 id，也用于资源前缀 / 子目录命名（小写、无空格）
    public var id: String
    /// 显示名
    public var name: String
    /// 图片资源前缀。比如 "doro" 会查找 doro-idle / doro-talk 等 imageset。
    /// 找不到时回退到全局 "pet-<mood>"，再不行用 emoji。
    public var assetPrefix: String
    public var persona: Persona
    /// 该宠物用的 TTS 后端（取值同 App 端 TTSBackend 的 rawValue：
    /// `hybrid_taffy` / `elevenlabs` / `bertvits2_local`）。
    /// nil = 按默认规则（见 `resolvedVoiceBackend`）：塔菲用混合塔菲，其它宠物用 ElevenLabs。
    public var voiceBackend: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case assetPrefix = "asset_prefix"
        case persona
        case voiceBackend = "voice_backend"
    }

    public init(
        id: String,
        name: String,
        assetPrefix: String,
        persona: Persona,
        voiceBackend: String? = nil
    ) {
        self.id = id
        self.name = name
        self.assetPrefix = assetPrefix
        self.persona = persona
        self.voiceBackend = voiceBackend
    }

    /// 实际生效的声音后端。显式设了就用；没设时：本地 Bert-VITS2 模型本身是「塔菲」音色，
    /// 所以只有塔菲（id / 前缀 == taffy）默认用「混合塔菲」，其它宠物默认走 ElevenLabs，
    /// 免得别的宠物都顶着塔菲的嗓子。
    public var resolvedVoiceBackend: String {
        if let v = voiceBackend, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        if id.lowercased() == "taffy" || assetPrefix.lowercased() == "taffy" {
            return "hybrid_taffy"
        }
        return "elevenlabs"
    }

    /// 把任意名字转成 id / 前缀友好的 slug：小写、保留 ASCII 字母数字和短横线
    public static func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        let kept = lower.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let s = String(kept)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return s.isEmpty ? "pet" : s
    }
}

/// pets.yaml 的整体形状：当前激活的 id + 所有宠物列表
public struct PetRoster: Codable, Sendable, Equatable {
    public var active: String
    public var pets: [PetProfile]

    enum CodingKeys: String, CodingKey {
        case active
        case pets
    }

    public init(active: String, pets: [PetProfile]) {
        self.active = active
        self.pets = pets
    }

    public var activeProfile: PetProfile? {
        pets.first(where: { $0.id == active }) ?? pets.first
    }
}

public struct PetRosterLoader: Sendable {
    public init() {}

    public func load(from url: URL) throws -> PetRoster {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode(PetRoster.self, from: raw)
    }

    public func save(_ roster: PetRoster, to url: URL) throws {
        let yaml = try YAMLEncoder().encode(roster)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }
}
