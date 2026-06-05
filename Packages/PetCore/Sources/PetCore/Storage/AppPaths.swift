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

    /// 所有用户自定义形象的根目录 —— 遍历清缓存时用。
    public static var spritesRootDir: URL {
        supportDir.appendingPathComponent("sprites", isDirectory: true)
    }

    /// 某只宠物的用户自定义形象目录：`~/Library/Application Support/Pet/sprites/<prefix>/`。
    /// 目录已按 assetPrefix 分好，内部文件名只用 mood（idle.gif / cheer.gif / cheer-2.gif），
    /// 不重复 prefix。`create` 默认建目录；只读探测时传 false。
    public static func spritesDir(prefix: String, create: Bool = true) -> URL {
        let dir = spritesRootDir.appendingPathComponent(prefix, isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 本地 Bert-VITS2 TTS 服务的安装目录（venv + Bert-VITS2 仓库 + Taffy checkpoint）。
    /// `setup.sh` 会在此处建 venv / clone 仓库 / 下模型；App 不直接创建它，要等用户跑过安装脚本。
    public static var ttsServerDir: URL {
        supportDir.appendingPathComponent("tts-server", isDirectory: true)
    }

    /// `server.py` 实际位置 —— setup.sh 把它复制进 Bert-VITS2/ 根目录里跑。
    public static var ttsServerScript: URL {
        ttsServerDir.appendingPathComponent("Bert-VITS2/server.py")
    }

    /// venv 里的 python（用它启 server.py，省得用户在 Settings 里手填路径）。
    public static var ttsServerVenvPython: URL {
        ttsServerDir.appendingPathComponent("venv/bin/python")
    }

    /// Python 子进程的日志文件，方便排查启动失败。
    public static var ttsServerLog: URL {
        ttsServerDir.appendingPathComponent("server.log")
    }

    public static func todayDoneKey(date: Date = .init()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "workflow.done.\(f.string(from: date))"
    }
}
