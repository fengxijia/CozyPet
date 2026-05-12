import AVFoundation
import Combine
import Foundation
import PetCore

/// 串行播放 TTS 音频。新一段进来会打断前一段。
@MainActor
final class VoicePlayer: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var lastError: String?

    private var player: AVAudioPlayer?
    private var currentTask: Task<Void, Never>?
    private var delegate: PlayerDelegate?
    /// 当前正在播的那段的 onFinish 回调，cancel() 也要负责把它触发掉。
    /// 参数 = 是否「自然播完」（false 表示被 cancel / 错误中断）。
    private var pendingFinish: (@MainActor (Bool) -> Void)?

    /// - onReady: 「音频真的开始播 / 出错 / 取消」三种情况都会调一次（保证上游不会卡住）
    /// - onFinish: 真的播完（AVAudioPlayer delegate 触发）/ 取消 / 失败 都调一次。
    ///   参数 true = 自然播完；false = 被打断或失败。让上游能区分"接着读下一条"还是"停在这条"。
    func speak(text: String, using provider: TTSProvider,
               onReady: (@MainActor () -> Void)? = nil,
               onFinish: (@MainActor (Bool) -> Void)? = nil) {
        cancel()
        let snapshot = text

        // 用 box 维持闭包之间的"只调一次"状态（变量在 escape 闭包之间共享要靠 class 持有）
        final class Once { var done = false }
        let readyFlag = Once()
        let finishFlag = Once()
        let fireReady: @MainActor () -> Void = {
            guard !readyFlag.done else { return }
            readyFlag.done = true
            onReady?()
        }
        let fireFinish: @MainActor (Bool) -> Void = { natural in
            guard !finishFlag.done else { return }
            finishFlag.done = true
            onFinish?(natural)
        }

        currentTask = Task { @MainActor [weak self] in
            guard let self else { fireReady(); fireFinish(false); return }
            do {
                let data = try await provider.synthesize(snapshot)
                if Task.isCancelled { fireReady(); fireFinish(false); return }
                // 把 finish 钩到 delegate 上；同时存到 pendingFinish 供 cancel() 触发
                self.pendingFinish = fireFinish
                try self.play(data: data)
                fireReady()
                self.lastError = nil
                // finish 由播放结束 delegate 或 cancel() 调用
            } catch is CancellationError {
                fireReady(); fireFinish(false)
            } catch {
                self.lastError = String(describing: error)
                fireReady(); fireFinish(false)
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        if let fire = pendingFinish {
            pendingFinish = nil
            fire(false)
        }
    }

    private func play(data: Data) throws {
        let p = try AVAudioPlayer(data: data)
        let d = PlayerDelegate { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                if let fire = self.pendingFinish {
                    self.pendingFinish = nil
                    fire(success)
                }
            }
        }
        delegate = d
        p.delegate = d
        p.prepareToPlay()
        p.play()
        player = p
        isPlaying = true
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: (Bool) -> Void
    init(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish(flag)
    }
}
