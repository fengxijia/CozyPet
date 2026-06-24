import AVFoundation
import Combine
import Foundation
import PetCore

/// 串行播放 TTS 音频。新一段进来会打断前一段。
///
/// 长文本会先在 Swift 这边按句号 / 问号 / 换行切成小段，逐段调 provider.synthesize 并
/// 顺序播放。原因：ElevenLabs 单次请求有字符上限、本地 Bert-VITS2 sidecar 也会在很长输入上
/// 超时或直接报错；不切的话整段就一声不响地没了（用户视角："气泡出了，但语音不读"）。
@MainActor
final class VoicePlayer: ObservableObject {
    /// 当前是否处在 speak() 会话里（横跨多个 chunk）。bubble 的隐藏倒计时
    /// 轮询这个值，所以 chunk 之间的衔接空隙不要把它翻成 false。
    @Published var isPlaying: Bool = false
    @Published var lastError: String?

    private var player: AVAudioPlayer?
    private var currentTask: Task<Void, Never>?
    private var delegate: PlayerDelegate?
    /// 当前 chunk 播完时要 resume 的 continuation。cancel() 时直接 resume 一下，
    /// 让 playAndWait 返回，外层 loop 看到 Task.isCancelled 后收尾。
    private var pendingPlaybackContinuation: CheckedContinuation<Void, Never>?

    /// - onReady: 「首个 chunk 真的开始播 / 出错 / 取消」三种情况都会调一次。
    /// - onFinish: 全部 chunk 自然播完（true），或被取消 / 失败（false）。
    func speak(text: String, using provider: TTSProvider,
               onReady: (@MainActor () -> Void)? = nil,
               onFinish: (@MainActor (Bool) -> Void)? = nil) {
        cancel()
        let snapshot = Self.normalizeForSpeech(text)
        let chunks = Self.chunkForTTS(snapshot)
        guard !chunks.isEmpty else {
            onReady?()
            onFinish?(false)
            return
        }

        // 用 box 维持闭包之间的"只调一次"状态
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

        // 整个 session 期间 isPlaying 都保持 true，chunk 之间不抖动。
        isPlaying = true
        currentTask = Task { @MainActor [weak self] in
            guard let self else {
                fireReady(); fireFinish(false); return
            }
            var startedAudio = false
            for chunk in chunks {
                if Task.isCancelled {
                    self.endSession()
                    fireReady(); fireFinish(false); return
                }
                let pieces: [Data]
                do {
                    if let segmented = provider as? any SegmentedTTSProvider {
                        pieces = try await segmented.synthesizePieces(chunk)
                    } else {
                        pieces = [try await provider.synthesize(chunk)]
                    }
                } catch is CancellationError {
                    self.endSession()
                    fireReady(); fireFinish(false); return
                } catch {
                    // URLSession 取消会抛 URLError(.cancelled)；这里一并归到"取消"路径，
                    // lastError 留个非空（cancelled 也算）方便 debug；但 onFinish(false) 该报还是要报。
                    self.lastError = String(describing: error)
                    self.endSession()
                    fireReady(); fireFinish(false); return
                }
                if Task.isCancelled {
                    self.endSession()
                    fireReady(); fireFinish(false); return
                }
                for data in pieces {
                    do {
                        try self.startPlayback(data: data)
                    } catch {
                        self.lastError = String(describing: error)
                        self.endSession()
                        fireReady(); fireFinish(false); return
                    }
                    if !startedAudio {
                        startedAudio = true
                        fireReady()
                    }
                    await self.waitForPlaybackEnd()
                    // 走到这里：要么自然播完，要么 cancel() 把 player.stop() 调了。
                    if Task.isCancelled {
                        self.endSession()
                        fireFinish(false); return
                    }
                }
            }
            self.lastError = nil
            self.endSession()
            fireFinish(true)
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        player?.stop()
        player = nil
        // 让正在 await 的 playAndWait 立刻返回；外层 loop 看到 isCancelled 后会自己收尾。
        if let cont = pendingPlaybackContinuation {
            pendingPlaybackContinuation = nil
            cont.resume()
        }
        // 立刻给 UI 一个"停了"的反馈，task 后续也会 endSession 把它再设一次，幂等。
        isPlaying = false
    }

    /// session 结束（自然完成 / 失败 / 取消都走这）。
    private func endSession() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func startPlayback(data: Data) throws {
        let p = try AVAudioPlayer(data: data)
        let d = PlayerDelegate { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let cont = self.pendingPlaybackContinuation {
                    self.pendingPlaybackContinuation = nil
                    cont.resume()
                }
            }
        }
        delegate = d
        p.delegate = d
        p.prepareToPlay()
        p.play()
        player = p
    }

    private func waitForPlaybackEnd() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // cancel() / 上一次 finish 没 resume 干净的话，这里直接收尾，避免悬挂。
            if let stale = pendingPlaybackContinuation {
                pendingPlaybackContinuation = nil
                stale.resume()
            }
            pendingPlaybackContinuation = cont
        }
    }

    /// 合成前的文本规整。目前只做一件事：把列表编号「1. / 2) / 3、」转成中文「一、二、三、」，
    /// 否则 Bert-VITS2 的语种分割会把「1.」判成英文、读成 "one"。
    /// 只动「真·列表编号」：数字前是行首 / 空白 / 中文冒号顿号括号，数字后是 .、) 之一，
    /// 且分隔符后面不是数字 —— 这样「2.5」「v2.3」「gpt-4」「100」都不会被误伤。
    static func normalizeForSpeech(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0
        let boundaryBefore: Set<Character> = [" ", "\t", "\n", "：", ":", "，", ",", "、", "(", "（", "．"]
        let seps: Set<Character> = [".", "．", "、", ")", "）"]
        func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

        while i < chars.count {
            // 试着在位置 i 匹配「(边界) 1~2 位数字 + 分隔符 + (空白/中文/结尾)」
            let atBoundary = (i == 0) || boundaryBefore.contains(chars[i - 1])
            if atBoundary, isDigit(chars[i]) {
                var j = i
                while j < chars.count, isDigit(chars[j]), j - i < 2 { j += 1 }  // 最多 2 位
                if j < chars.count, seps.contains(chars[j]), !(j == i) {
                    let afterSep = j + 1 < chars.count ? chars[j + 1] : " "
                    // 分隔符后是数字 → 是小数/版本号，不动
                    if !isDigit(afterSep) {
                        let n = Int(String(chars[i..<j])) ?? -1
                        if n >= 0, let cn = Self.chineseNumber(n) {
                            out += cn + "、"
                            i = j + 1
                            // 吃掉分隔符后的一个空格，免得「一、 写」中间多空格
                            if i < chars.count, chars[i] == " " { i += 1 }
                            continue
                        }
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// 0–99 的阿拉伯数字转中文（列表编号够用）。超范围返回 nil（不转，保持原样）。
    static func chineseNumber(_ n: Int) -> String? {
        guard (0...99).contains(n) else { return nil }
        let d = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        if n < 10 { return d[n] }
        if n < 20 { return "十" + (n % 10 == 0 ? "" : d[n % 10]) }
        let t = n / 10, o = n % 10
        return d[t] + "十" + (o == 0 ? "" : d[o])
    }

    /// 把长文本按句号 / 感叹号 / 问号 / 换行切片，每片不超过 maxLen。
    /// 一段太长时退而求其次在逗号 / 分号 / 顿号断；都没有就硬切。
    /// 这是 ElevenLabs 字符上限和本地 Bert-VITS2 长输入掉链子的兜底。
    static func chunkForTTS(_ text: String, maxLen: Int = 160) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= maxLen { return [trimmed] }

        let strongBreaks: Set<Character> = ["。", "！", "？", "!", "?", "\n", "."]
        let softBreaks: Set<Character> = ["；", ";", "，", ",", "、", " "]

        var chunks: [String] = []
        var current = ""
        for ch in trimmed {
            current.append(ch)
            if strongBreaks.contains(ch), current.count >= maxLen / 3 {
                chunks.append(current)
                current = ""
            } else if current.count >= maxLen {
                if let softIdx = current.lastIndex(where: { softBreaks.contains($0) }),
                   current.distance(from: current.startIndex, to: softIdx) >= maxLen / 3 {
                    let cut = current.index(after: softIdx)
                    chunks.append(String(current[..<cut]))
                    current = String(current[cut...])
                } else {
                    chunks.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
