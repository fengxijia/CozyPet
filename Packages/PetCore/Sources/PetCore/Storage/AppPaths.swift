import Foundation

public enum AppPaths {
    public static var supportDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = base.appendingPathComponent("Pet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var workflowFile: URL {
        supportDir.appendingPathComponent("workflow.yaml")
    }

    public static var petsFile: URL {
        supportDir.appendingPathComponent("pets.yaml")
    }

    /// 「暖心提示」便签 —— 跟 todo 完全无关，单独存。JSON 比 YAML 简单且不会被空格 / 缩进搞坏。
    public static var notesFile: URL {
        supportDir.appendingPathComponent("notes.json")
    }

    /// TTS 合成结果的磁盘缓存目录（per-text + voice 配置哈希成文件名）。
    public static var ttsCacheDir: URL {
        let dir = supportDir.appendingPathComponent("tts-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func todayDoneKey(date: Date = .init()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "workflow.done.\(f.string(from: date))"
    }
}
