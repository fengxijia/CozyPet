import Foundation

public struct HybridTaffyTTSProvider: SegmentedTTSProvider {
    private enum Route {
        case localTaffy
        case elevenLabs
    }

    private struct Piece {
        var route: Route
        var text: String
    }

    private let localTaffy: any TTSProvider
    private let elevenLabs: (any TTSProvider)?

    public init(localTaffy: any TTSProvider, elevenLabs: (any TTSProvider)?) {
        self.localTaffy = localTaffy
        self.elevenLabs = elevenLabs
    }

    public func synthesize(_ text: String) async throws -> Data {
        let pieces = try await synthesizePieces(text)
        guard !pieces.isEmpty else { throw TTSError.empty }
        if pieces.count == 1 { return pieces[0] }

        // VoicePlayer consumes synthesizePieces() directly. This fallback keeps the
        // plain TTSProvider contract usable for callers that are not segment-aware.
        return pieces.reduce(into: Data()) { $0.append($1) }
    }

    public func synthesizePieces(_ text: String) async throws -> [Data] {
        let pieces = Self.split(text)
        guard !pieces.isEmpty else { throw TTSError.empty }

        var out: [Data] = []
        out.reserveCapacity(pieces.count)
        for piece in pieces {
            let provider: any TTSProvider
            switch piece.route {
            case .localTaffy:
                provider = localTaffy
            case .elevenLabs:
                // 没配 ElevenLabs（key / voice 缺）就用本地塔菲念英文 ——
                // Bert-VITS2 v2.3 本身支持 EN/ZH/JP，总比整句报错静音强。
                provider = elevenLabs ?? localTaffy
            }
            let data = try await provider.synthesize(piece.text)
            guard !data.isEmpty else { throw TTSError.empty }
            out.append(data)
        }
        return out
    }

    private static func split(_ text: String) -> [Piece] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var pieces: [Piece] = []
        var current = ""
        var currentRoute: Route?

        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let route = currentRoute, !t.isEmpty else {
                current = ""
                return
            }
            if let last = pieces.last, last.route == route {
                pieces[pieces.count - 1].text += t
            } else {
                pieces.append(Piece(route: route, text: t))
            }
            current = ""
        }

        for ch in trimmed {
            let route = route(for: ch)
            if let route {
                if let existing = currentRoute, existing != route {
                    flush()
                }
                currentRoute = route
            } else if currentRoute == nil {
                currentRoute = .localTaffy
            }
            current.append(ch)
        }
        flush()
        return pieces
    }

    private static func route(for character: Character) -> Route? {
        var sawCJK = false
        var sawLatin = false
        for scalar in character.unicodeScalars {
            if isCJK(scalar) {
                sawCJK = true
            } else if isLatinLetter(scalar) {
                sawLatin = true
            }
        }
        if sawLatin { return .elevenLabs }
        if sawCJK { return .localTaffy }
        return nil
    }

    private static func isLatinLetter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A:
            return true
        default:
            return false
        }
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
