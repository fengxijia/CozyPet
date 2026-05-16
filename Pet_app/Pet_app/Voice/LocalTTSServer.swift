import AppKit
import Combine
import Foundation
import PetCore

/// 管 Python TTS 子进程的生命周期。
///
/// 设计要点：
/// - App 启动时如果 backend 是 `bertVITS2Local`，调 `startIfNeeded()` 把 server 拉起来；
///   App 退出时调 `stop()` 把它干掉，避免留孤儿进程。
/// - 启动后轮询 `/health` 直到 ready 或超时；UI 通过 `@Published status` 反应。
/// - Python 子进程的 stdout/stderr 重定向到 `tts-server/server.log`，方便排查。
/// - 用 `terminationHandler` 检测崩溃；崩了切到 `.crashed`，让用户能在 Settings 看到。
@MainActor
final class LocalTTSServer: ObservableObject {
    static let shared = LocalTTSServer()

    enum Status: Equatable {
        case notInstalled  // 检查不到 venv/python 或者 server.py 缺
        case stopped       // 主动停了，或者从来没起过
        case starting      // 子进程拉起来了，但 /health 还没 ready
        case ready         // /health 返回 ready，可以用
        case crashed(String)  // 子进程意外退出，附 stderr 末尾几行
    }

    @Published private(set) var status: Status = .stopped

    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private let health = LocalBertVITS2Health()

    private init() {}

    /// 检查安装是否齐备 —— Settings UI 用它决定要不要显示「点这里安装」按钮。
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: AppPaths.ttsServerVenvPython.path)
            && FileManager.default.fileExists(atPath: AppPaths.ttsServerScript.path)
    }

    /// 仅当 backend = 本地 Taffy 时由 AppDelegate 调一次。重复调安全（已 ready 直接返回）。
    func startIfNeeded() {
        switch status {
        case .ready, .starting:
            return
        default:
            break
        }
        guard isInstalled else {
            status = .notInstalled
            return
        }
        spawn()
    }

    /// 主动停子进程（App 退出 / 用户切回 ElevenLabs 时调）。
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let p = process, p.isRunning {
            // SIGTERM 给它几秒收尾，超时再 SIGKILL
            p.terminationHandler = nil  // 主动 stop 不算崩
            p.terminate()
        }
        process = nil
        status = .stopped
    }

    /// 重启 —— UI 那个「重启服务」按钮。
    func restart() {
        stop()
        // 给 OS 一点时间释放端口
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startIfNeeded()
        }
    }

    /// 在 Terminal 里跑 setup.sh，让用户能看到 pip / huggingface-cli 输出。
    func openInstallerInTerminal() {
        // 安装脚本走仓库里的源文件（不靠 ttsServerDir 是否存在），路径硬编码到用户的项目位置
        let setupPath = "\(NSHomeDirectory())/Code/pet/tts-server/setup.sh"
        if FileManager.default.fileExists(atPath: setupPath) {
            runInTerminal(command: "bash \(shellQuote(setupPath))")
        } else {
            // 兜底：先打开仓库的 tts-server 目录让用户自己找
            let url = URL(fileURLWithPath: "\(NSHomeDirectory())/Code/pet/tts-server")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 打开模型目录（用户想看模型在不在）。
    func openServerDirectoryInFinder() {
        let url = AppPaths.ttsServerDir
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 打开 server.log（崩溃时看这个）。
    func openLog() {
        let url = AppPaths.ttsServerLog
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 内部实现

    private func spawn() {
        let venvPython = AppPaths.ttsServerVenvPython
        let serverScript = AppPaths.ttsServerScript
        let cwd = serverScript.deletingLastPathComponent()  // Bert-VITS2/
        let logURL = AppPaths.ttsServerLog

        // 准备 log 文件
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()

        let p = Process()
        p.executableURL = venvPython
        p.arguments = [serverScript.path]
        p.currentDirectoryURL = cwd

        // 把 venv 的 bin 塞 PATH 前面 —— ffmpeg、huggingface-cli 找得到
        var env = ProcessInfo.processInfo.environment
        let venvBin = AppPaths.ttsServerDir.appendingPathComponent("venv/bin").path
        env["PATH"] = "\(venvBin):\(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")"
        env["PYTHONUNBUFFERED"] = "1"
        // 不希望子进程沿用 Xcode 的开发证书路径之类的乱七八糟变量；上面已经覆盖关键的
        p.environment = env

        if let handle = logHandle {
            p.standardOutput = handle
            p.standardError = handle
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                // 如果是用户主动 stop()，terminationHandler 已经被 nil 掉了，走不到这里。
                // 走到这里 = 意外退出。
                let code = proc.terminationStatus
                let tail = self.tailLog(lines: 30)
                self.status = .crashed("exit=\(code)\n\(tail)")
                self.process = nil
                self.pollTask?.cancel()
                self.pollTask = nil
            }
        }

        do {
            try p.run()
            self.process = p
            self.status = .starting
            startHealthPoll()
        } catch {
            self.status = .crashed("启动失败：\(error.localizedDescription)")
        }
    }

    private func startHealthPoll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            // 最多等 120s —— 第一次跑模型加载 + BERT 子模型加载真有可能这么久
            for _ in 0..<120 {
                if Task.isCancelled { return }
                if let s = await self?.health.ping(timeout: 2) {
                    guard let self else { return }
                    switch s {
                    case .ready:
                        self.status = .ready
                        return
                    case .loading, .idle:
                        self.status = .starting
                    case .error(let msg):
                        self.status = .crashed(msg)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // 超时了，但进程还活着就保持 .starting；进程退了 terminationHandler 已经接管
            if self?.process?.isRunning == false {
                self?.status = .crashed("启动超时，进程已退出，看 server.log")
            }
        }
    }

    private func tailLog(lines: Int) -> String {
        guard let data = try? Data(contentsOf: AppPaths.ttsServerLog),
              let text = String(data: data, encoding: .utf8) else {
            return "(no log)"
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = all.suffix(lines).joined(separator: "\n")
        return tail
    }

    private func runInTerminal(command: String) {
        // 用 AppleScript 让 Terminal.app 打开一个新窗口跑命令；用户能看到 pip 进度并按提示输入
        let script = """
        tell application "Terminal"
            activate
            do script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
