import Foundation

/// 用户自定义形象的查找 / 导入逻辑。纯 Foundation（PetCore 不碰 AppKit），
/// 这样既能单测，也能给 App 端的缓存清理复用。
///
/// 文件落在 `~/Library/Application Support/Pet/sprites/<assetPrefix>/`，文件名只用 mood：
/// `idle.gif` / `talk.gif` / `cheer.gif` / `cheer-2.gif`（变体 -2..-5）。
public enum PetSprites {
    /// 可导入的扩展名（NSOpenPanel 也按这个限制）。
    public static let importableExtensions = ["gif", "png", "webp", "heic", "apng"]
    /// 解析时的扩展名优先级 —— gif / webp / apng（动图）排在静态 png / heic 前面，
    /// 同一 mood 万一动静都在，优先动图。
    static let resolveExtensions = ["gif", "webp", "apng", "png", "heic"]

    /// 某 mood 现有的所有用户图：base（`<mood>`）+ 变体（`<mood>-2`…`-5`）。
    /// 每个序号按扩展名优先级取第一个存在的；序号缺了就跳过。
    public static func userSpriteURLs(prefix: String, mood: String) -> [URL] {
        let dir = AppPaths.spritesDir(prefix: prefix, create: false)
        var result: [URL] = []
        for n in 1...5 {
            let base = n == 1 ? mood : "\(mood)-\(n)"
            if let url = firstExisting(dir: dir, base: base) {
                result.append(url)
            }
        }
        return result
    }

    /// 该 mood 的主图（base，无变体）URL；没有返回 nil。
    /// Settings 用它判断「已自定义 / 未设」。
    public static func customSpriteURL(prefix: String, mood: String) -> URL? {
        let dir = AppPaths.spritesDir(prefix: prefix, create: false)
        return firstExisting(dir: dir, base: mood)
    }

    /// 把 `src` 拷成 `<mood>.<srcExt>`，并删掉同 mood base 的其它扩展名兄弟
    /// （避免 idle.gif / idle.png 同时存在产生歧义）。返回落地后的 URL。
    @discardableResult
    public static func importSprite(from src: URL, prefix: String, mood: String) throws -> URL {
        let ext = src.pathExtension.lowercased()
        guard importableExtensions.contains(ext) else {
            throw PetSpriteError.unsupportedFormat(ext)
        }
        let dir = AppPaths.spritesDir(prefix: prefix, create: true)
        let fm = FileManager.default
        // 先清掉同 base 的所有扩展名（含目标自己），保证只剩这一张
        for other in importableExtensions {
            let sibling = dir.appendingPathComponent("\(mood).\(other)")
            try? fm.removeItem(at: sibling)
        }
        let dest = dir.appendingPathComponent("\(mood).\(ext)")
        try fm.copyItem(at: src, to: dest)
        return dest
    }

    /// 删掉某 mood 的所有用户图（base + 变体 -2..-5 的所有扩展名），恢复 bundle 内置。
    public static func removeUserSprites(prefix: String, mood: String) {
        let dir = AppPaths.spritesDir(prefix: prefix, create: false)
        let fm = FileManager.default
        for n in 1...5 {
            let base = n == 1 ? mood : "\(mood)-\(n)"
            for ext in importableExtensions {
                try? fm.removeItem(at: dir.appendingPathComponent("\(base).\(ext)"))
            }
        }
    }

    /// sprites/ 下所有常规文件（递归遍历各宠物子目录），给启动时缓存清理用。
    public static func allUserSpriteURLs() -> [URL] {
        let root = AppPaths.spritesRootDir
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in en {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            if isFile == true { urls.append(url) }
        }
        return urls
    }

    private static func firstExisting(dir: URL, base: String) -> URL? {
        for ext in resolveExtensions {
            let url = dir.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

public enum PetSpriteError: Error, LocalizedError {
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            "不支持的图片格式：.\(ext)（支持 gif / png / webp / heic / apng）"
        }
    }
}
