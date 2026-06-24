import Combine
import SwiftUI
import PetCore

/// 一条聊天记录 + 它的作者宠物。
/// petID == nil → 用户消息（右侧气泡，不显示宠物头像）。
/// assistant 消息记下当时是哪只宠物在说：切宠后旧消息仍显示原来的头像，
/// 喂回 LLM 时也能把「别的宠物说过的话」标出来，避免新宠物串了性格。
struct ChatEntry: Identifiable, Equatable {
    let id: UUID
    var message: LLMMessage
    var petID: String?

    init(id: UUID = UUID(), message: LLMMessage, petID: String? = nil) {
        self.id = id
        self.message = message
        self.petID = petID
    }
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var entries: [ChatEntry] = []
    @Published var input: String = ""
    @Published var streaming: String = ""   // current partial assistant reply
    @Published var sending: Bool = false
    @Published var lastError: String?

    private let state: PetStateMachine
    private let petStore: PetStore
    private let voice: VoicePlayer
    private var task: Task<Void, Never>?

    init(state: PetStateMachine, petStore: PetStore, voice: VoicePlayer) {
        self.state = state
        self.petStore = petStore
        self.voice = voice
    }

    /// 展示用：历史 + 正在 streaming 的临时尾巴（作者 = 当前宠物）。
    var displayEntries: [ChatEntry] {
        var all = entries
        if !streaming.isEmpty {
            all.append(ChatEntry(
                message: .init(role: .assistant, content: streaming),
                petID: petStore.active.id
            ))
        }
        return all
    }

    /// 某条消息作者宠物的资源前缀（找不到就退当前宠物）—— 用来取对应头像。
    func assetPrefix(forPetID id: String?) -> String {
        if let id, let p = petStore.roster.pets.first(where: { $0.id == id }) {
            return p.assetPrefix
        }
        return petStore.active.assetPrefix
    }

    /// 让 LLM 在每次回复开头标一个 [mood:xxx]，由 ChatModel 解析后切换桌宠表情，
    /// 解析完会从展示文本里剥掉 tag —— 用户在聊天里看不到。
    private static let moodInstruction = """

【输出格式 — 必须严格遵守】
每次回复都必须以 [mood:xxx] 这个标签开头，xxx 在以下列表里选最贴本次心情的一个：
- idle 平静中性、一般说话、闲聊
- think 思考、犹豫、疑惑、想想
- sad 难过、伤心、委屈
- cheer 开心、兴奋、欢笑、夸奖
- angry 生气、不满、抗议
- love 撒娇、比心、表白、抱抱
然后再写正文，不要解释这个标签，也不要在正文里再提 mood。
例：
[mood:cheer] 太棒了！
[mood:sad] 怎么了…要不要抱抱
[mood:angry] 不准摆烂！
"""

    /// 把 [mood:xxx] 从串里剥出来。返回 (mood?, 剩余文本)。
    /// 没找到合法 tag 时 mood 返回 nil、文本原样。
    private static func extractMoodTag(_ s: String) -> (PetMood?, String) {
        guard let tagRange = s.range(of: #"^\s*\[mood:(\w+)\]\s*"#, options: .regularExpression) else {
            return (nil, s)
        }
        // 从匹配段里抓 ':' 后到 ']' 前的那截当作 mood 名
        let tagText = String(s[tagRange])
        var mood: PetMood?
        if let colon = tagText.firstIndex(of: ":"),
           let bracket = tagText.firstIndex(of: "]"),
           colon < bracket {
            let name = tagText[tagText.index(after: colon)..<bracket]
                .trimmingCharacters(in: .whitespaces)
            mood = PetMood(rawValue: name)
        }
        var remainder = s
        remainder.removeSubrange(tagRange)
        return (mood, remainder)
    }

    /// 把内存里的 entries 转成喂给 LLM 的 history。
    /// 「别的宠物」说过的 assistant 消息前面标上它的名字，让当前宠物明白那不是自己说的，
    /// 从而用自己的性格接续、而不是模仿上一只的语气。
    private func llmHistory(activePetID: String) -> [LLMMessage] {
        entries.map { entry in
            guard entry.message.role == .assistant,
                  let pid = entry.petID, pid != activePetID else {
                return entry.message
            }
            let name = petStore.roster.pets.first(where: { $0.id == pid })?.name ?? "另一只宠物"
            return LLMMessage(role: .assistant, content: "（这句是「\(name)」说的）\(entry.message.content)")
        }
    }

    /// 历史里是否有「别的宠物」说过的话 —— 有的话才需要给当前宠物加防串味提示。
    private func hasForeignAssistant(activePetID: String) -> Bool {
        entries.contains {
            $0.message.role == .assistant && ($0.petID ?? activePetID) != activePetID
        }
    }

    /// 切宠后防止性格 / 语气串味的系统提示，仅当历史里掺了别的宠物的话时才加。
    private static func styleGuard(activeName: String, hasForeign: Bool) -> String {
        guard hasForeign else { return "" }
        return """


【接手对话】这段记录里有些 assistant 回复来自别的宠物（已用「名字」标在句首）。你现在是「\(activeName)」，请先读懂前面的来龙去脉，然后只用你自己的性格、语气和说话风格自然接续，不要模仿别的宠物的腔调，也不要把自己错当成它们。
"""
    }

    func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        let userMsg = LLMMessage(role: .user, content: trimmed)
        entries.append(ChatEntry(message: userMsg, petID: nil))
        input = ""
        streaming = ""
        sending = true
        lastError = nil
        state.noteInteraction()
        state.mood = .think     // 等回复期间在思考

        // 这一轮回复归属当前激活的宠物；历史里别的宠物的话会被标注出来。
        let authorID = petStore.active.id
        let authorName = petStore.active.name
        let basePersona = petStore.active.persona
        let history = llmHistory(activePetID: authorID)
        let provider = SettingsView.makeProvider()
        let persona = Persona(
            name: basePersona.name,
            systemPrompt: basePersona.systemPrompt
                + Self.moodInstruction
                + Self.styleGuard(activeName: authorName, hasForeign: hasForeignAssistant(activePetID: authorID))
        )

        // TTS 开着时，"边流边显示气泡 + 完整后才发声"会让文字早于语音 2-3 秒，体验拉跨。
        // 流式期间不更新桌宠气泡，等流完调 state.say() 让气泡和音频同时亮。
        // 聊天历史窗里仍然能看到 streaming，所以打字感不丢。
        let ttsOn = SettingsView.makeTTSProvider(for: petStore.active) != nil

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var raw = ""              // 累积原始流（含 tag）
                var moodResolved = false   // tag 是否已经处理（找到或放弃）
                var parsedMood: PetMood = .idle
                for try await delta in provider.chat(persona: persona, history: history) {
                    raw += delta
                    if !moodResolved {
                        let stripped = raw.drop(while: \.isWhitespace)
                        if !stripped.isEmpty, stripped.first != "[" {
                            // 不以 [ 开头，肯定不是 tag —— 直接吐字
                            moodResolved = true
                            parsedMood = .idle
                            if !ttsOn { self.state.mood = .idle }
                        } else if raw.contains("]") || raw.count > 30 {
                            let (mood, rest) = Self.extractMoodTag(raw)
                            parsedMood = mood ?? .idle
                            raw = rest
                            moodResolved = true
                            if !ttsOn { self.state.mood = parsedMood }
                        } else {
                            // 还在 buffer 里等 ]
                            continue
                        }
                    }
                    self.streaming = raw
                    if !ttsOn {
                        self.state.bubbleText = raw
                        self.state.bubbleVisible = true
                    }
                }
                // 流结束时如果都没解析到 tag（比如回复非常短），也兜底处理一下
                if !moodResolved {
                    let (mood, rest) = Self.extractMoodTag(raw)
                    if let mood { parsedMood = mood }
                    raw = rest
                }
                let final = raw
                if !final.isEmpty {
                    self.entries.append(ChatEntry(
                        message: .init(role: .assistant, content: final),
                        petID: authorID
                    ))
                }
                self.streaming = ""
                self.sending = false
                // state.say 会等音频准备好再亮气泡（VoicePlayer.onReady 回调），所以这里只调一次。
                self.state.say(final.isEmpty ? "嗯～" : final, mood: parsedMood, autoHideAfter: 30)
            } catch {
                self.sending = false
                self.lastError = String(describing: error)
                self.state.say("出错了：\(self.lastError ?? "未知")", mood: .sad)
            }
        }
    }

    func stop() {
        task?.cancel()
        sending = false
    }
}

struct ChatView: View {
    @Bindable var state: PetStateMachine
    @ObservedObject var petStore: PetStore
    @ObservedObject var voice: VoicePlayer
    /// 由 AppDelegate 注入，跟桌宠下面的 InlineChatBar 共用同一份对话历史。
    @ObservedObject var model: ChatModel

    /// 当前正在朗读哪条 assistant 消息（按 displayEntries 索引），nil = 没在念
    @State private var readingIndex: Int?
    @State private var ttsAlert: String?

    init(state: PetStateMachine, petStore: PetStore, voice: VoicePlayer, model: ChatModel) {
        self.state = state
        self.petStore = petStore
        self.voice = voice
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.displayEntries.enumerated()), id: \.element.id) { idx, entry in
                            MessageBubble(
                                message: entry.message,
                                assetPrefix: model.assetPrefix(forPetID: entry.petID),
                                canRead: canRead(at: idx, message: entry.message),
                                isReading: readingIndex == idx,
                                onToggleRead: { toggleRead(at: idx, text: entry.message.content) }
                            )
                            .id(idx)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.displayEntries.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
                .onChange(of: model.streaming) { _, _ in
                    let n = model.displayEntries.count
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }

            if let err = model.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("和小宠说点什么…", text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                    .onSubmit { model.send() }

                if voice.isPlaying {
                    Button {
                        voice.cancel()
                    } label: {
                        Image(systemName: "speaker.slash.fill")
                    }
                    .controlSize(.large)
                    .help("停止朗读")
                }

                if model.sending {
                    Button("停") { model.stop() }
                        .controlSize(.large)
                } else {
                    Button("发送") { model.send() }
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(8)
        }
        .alert("还没配置 TTS", isPresented: Binding(
            get: { ttsAlert != nil },
            set: { if !$0 { ttsAlert = nil } }
        )) {
            Button("好") { ttsAlert = nil }
        } message: {
            Text(ttsAlert ?? "")
        }
        .onChange(of: voice.isPlaying) { _, playing in
            // 用户从输入栏 / 桌宠那边的 cancel，也把按钮状态收回去
            if !playing { readingIndex = nil }
        }
    }

    /// 只有"已经成型的 assistant 回复"能朗读 —— 排除用户消息和正在 streaming 的临时尾巴。
    private func canRead(at idx: Int, message: LLMMessage) -> Bool {
        guard message.role == .assistant else { return false }
        let isStreamingTail = !model.streaming.isEmpty && idx == model.displayEntries.count - 1
        return !isStreamingTail
    }

    private func toggleRead(at idx: Int, text: String) {
        if readingIndex == idx {
            voice.cancel()        // 让 state.say 的 onFinish(false) 把 readingIndex 收回
            return
        }
        guard SettingsView.makeTTSProvider(for: petStore.active) != nil else {
            ttsAlert = "请先到 设置 → 语音 打开「说话时念出来」并选好 TTS 后端（ElevenLabs 或本地 Bert-VITS2）。"
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        readingIndex = idx
        state.say(trimmed, mood: state.mood, autoHideAfter: 30) { _ in
            // 被另一条抢走时 readingIndex 已经被改成新 idx —— 只在还是自己时清掉
            if readingIndex == idx {
                readingIndex = nil
            }
        }
    }
}

private struct MessageBubble: View {
    let message: LLMMessage
    let assetPrefix: String
    var canRead: Bool = false
    var isReading: Bool = false
    var onToggleRead: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                avatar
                HStack(alignment: .center, spacing: 6) {
                    bubble
                    if canRead { speakerButton }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var speakerButton: some View {
        Button(action: onToggleRead) {
            Image(systemName: isReading ? "stop.circle.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isReading ? Color.accentColor : Color.secondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isReading ? "停止朗读" : "让桌宠念这句")
    }

    private var avatar: some View {
        Group {
            if let img = avatarImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Text("🐾").font(.system(size: 22))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .overlay(Circle().stroke(.secondary.opacity(0.2), lineWidth: 0.5))
    }

    /// 用静态首帧做头像（不让小 GIF 一直动，列表里太分散注意力）。
    /// 先看用户给这只宠物导入的 idle 图，再退 bundle 内置，最后退全局 pet。
    private var avatarImage: NSImage? {
        if let url = PetSprites.customSpriteURL(prefix: assetPrefix, mood: "idle"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        for name in ["\(assetPrefix)-idle", "pet-idle"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "gif"),
               let img = NSImage(contentsOf: url) {
                return img
            }
            if let img = NSImage(named: name) {
                return img
            }
        }
        return nil
    }

    private var bubble: some View {
        Text(message.content)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(message.role == .user
                          ? Color.accentColor.opacity(0.18)
                          : Color.secondary.opacity(0.10))
            )
            .textSelection(.enabled)
    }
}
