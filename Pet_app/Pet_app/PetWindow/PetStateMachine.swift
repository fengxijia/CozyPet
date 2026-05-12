import Foundation
import Observation
import PetCore

public enum PetMood: String, CaseIterable, Sendable {
    case idle
    case talk
    case think
    case confused
    case remind
    case sad
    case cheer
    case angry
    case love
    case sleep

    public var label: String {
        switch self {
        case .idle: "发呆"
        case .talk: "说话"
        case .think: "思考"
        case .confused: "疑惑"
        case .remind: "提醒"
        case .sad: "难过"
        case .cheer: "开心"
        case .angry: "生气"
        case .love: "比心"
        case .sleep: "打瞌睡"
        }
    }
}

@Observable
@MainActor
final class PetStateMachine {
    var mood: PetMood = .idle
    var bubbleText: String? = nil
    var bubbleVisible: Bool = false

    /// 60 秒没人理就打瞌睡
    var sleepAfterIdleSeconds: Double = 60
    private var lastInteraction: Date = .now
    private var idleWatchdog: Task<Void, Never>?
    /// 当前 say() 的「该不该隐藏气泡」倒计时；新 say() 进来就 cancel 旧的
    private var hideTask: Task<Void, Never>?

    /// 把语音播放下沉到状态机：所有 say() 都会自动念。
    /// 用 factory 闭包而非直接传 provider —— 这样 Settings 里改 voice id / 关 TTS 即时生效。
    private let voice: VoicePlayer?
    private let ttsProviderFactory: @MainActor () -> (any TTSProvider)?

    init(
        voice: VoicePlayer? = nil,
        ttsProviderFactory: @escaping @MainActor () -> (any TTSProvider)? = { nil }
    ) {
        self.voice = voice
        self.ttsProviderFactory = ttsProviderFactory
        startIdleWatchdog()
    }

    /// - onSpeechFinish: TTS 播完触发；参数 true = 自然念完，false = 被打断 / 没 TTS。
    ///   想"念完 A 再念 B"的链式调用时传它（自己用 `guard natural else { return }` 收尾）。
    func say(_ text: String, mood: PetMood = .talk, autoHideAfter seconds: Double = 30,
             onSpeechFinish: (@MainActor (Bool) -> Void)? = nil) {
        noteInteraction()
        let snapshotMood = mood

        // 新台词来了，旧的 hide 倒计时一律失效
        hideTask?.cancel()
        hideTask = nil

        if !text.isEmpty, let voice, let provider = ttsProviderFactory() {
            // TTS 路径：onReady 时亮气泡 + 启动「轮询 voice.isPlaying 真为 false 后再倒数」的 hide。
            // 不用 AVAudioPlayer 的 audioPlayerDidFinishPlaying 来触发 —— 它在 ElevenLabs 的 mp3 上
            // 偶尔会早触发，导致 30s 倒数提前开始，气泡说到一半就消失。
            voice.speak(
                text: text, using: provider,
                onReady: { [weak self] in
                    guard let self else { return }
                    self.mood = mood
                    self.bubbleText = text
                    self.bubbleVisible = true
                    self.scheduleVoiceAwareHide(text: text, mood: snapshotMood, grace: seconds)
                },
                onFinish: onSpeechFinish
            )
        } else {
            self.mood = mood
            self.bubbleText = text
            self.bubbleVisible = true
            self.scheduleHide(text: text, mood: snapshotMood, after: seconds)
            // 没 TTS / 空文本：不算"自然念完"，链式 caller 自然停在这里。
            onSpeechFinish?(false)
        }
    }

    /// 等到 voice.isPlaying 真的转 false，再额外等 grace 秒。
    /// 期间被新的 say() 覆盖 bubbleText 就直接退出。
    private func scheduleVoiceAwareHide(text: String, mood snapshotMood: PetMood, grace: Double) {
        hideTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 1) 一直等到语音真停了（轮询 isPlaying；不依赖 AVAudioPlayer 的早触发 delegate）
            while let v = self.voice, v.isPlaying {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled || self.bubbleText != text { return }
            }
            // 2) 给用户 grace 秒读完字幕
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            if Task.isCancelled { return }
            // 3) 灭灯前再确认一次：万一这期间又有新一句开播了，让它接管
            if let v = self.voice, v.isPlaying { return }
            if self.bubbleText == text {
                self.bubbleVisible = false
                if self.mood == snapshotMood { self.mood = .idle }
            }
        }
    }

    private func scheduleHide(text: String, mood snapshotMood: PetMood, after seconds: Double) {
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.bubbleText == text {
                self.bubbleVisible = false
                if self.mood == snapshotMood { self.mood = .idle }
            }
        }
    }

    /// 每次交互（点桌宠 / 发消息 / 打开面板）调用，重置打瞌睡计时
    func noteInteraction() {
        lastInteraction = .now
        if mood == .sleep { mood = .idle }
    }

    func cycleMood() {
        let all = PetMood.allCases
        let i = all.firstIndex(of: mood) ?? 0
        mood = all[(i + 1) % all.count]
    }

    private func startIdleWatchdog() {
        idleWatchdog?.cancel()
        idleWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                let elapsed = Date.now.timeIntervalSince(self.lastInteraction)
                if self.mood == .idle, elapsed > self.sleepAfterIdleSeconds {
                    self.mood = .sleep
                }
            }
        }
    }
}
