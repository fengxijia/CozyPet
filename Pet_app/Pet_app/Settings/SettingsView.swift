import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PetCore

enum LLMBackend: String, CaseIterable {
    case claude = "claude"
    case openai = "openai"   // OpenAI / Gemini / OpenRouter / Ollama 等兼容协议

    var label: String {
        switch self {
        case .claude: "Claude (Anthropic 协议)"
        case .openai: "OpenAI 兼容 (OpenAI / Gemini / OpenRouter / Ollama)"
        }
    }
}

enum SettingsKeys {
    static let backend = "llm.backend"

    // Claude / Anthropic
    static let anthropicAPIKey = "anthropic.api_key"
    static let anthropicBaseURL = "anthropic.base_url"
    static let anthropicAuthMode = "anthropic.auth_mode"
    static let claudeModel = "claude.model"

    // OpenAI 兼容
    static let openaiAPIKey = "openai.api_key"
    static let openaiBaseURL = "openai.base_url"
    static let openaiModel = "openai.model"

    // TTS（ElevenLabs）
    static let ttsEnabled = "tts.enabled"
    static let ttsAPIKey = "tts.elevenlabs.api_key"
    static let ttsVoiceID = "tts.elevenlabs.voice_id"
    static let ttsModel = "tts.elevenlabs.model"
    static let ttsStability = "tts.elevenlabs.stability"
    static let ttsSimilarity = "tts.elevenlabs.similarity"
}

struct SettingsView: View {
    @ObservedObject var petStore: PetStore

    @AppStorage(SettingsKeys.backend) private var backend: String = LLMBackend.claude.rawValue

    @AppStorage(SettingsKeys.anthropicAPIKey) private var anthropicKey: String = ""
    @AppStorage(SettingsKeys.anthropicBaseURL) private var anthropicBase: String = "https://api.anthropic.com"
    @AppStorage(SettingsKeys.anthropicAuthMode) private var authMode: String = ClaudeAuthMode.apiKey.rawValue
    @AppStorage(SettingsKeys.claudeModel) private var claudeModel: String = "claude-opus-4-7"

    @AppStorage(SettingsKeys.openaiAPIKey) private var openaiKey: String = ""
    @AppStorage(SettingsKeys.openaiBaseURL) private var openaiBase: String = "https://generativelanguage.googleapis.com/v1beta/openai/"
    @AppStorage(SettingsKeys.openaiModel) private var openaiModel: String = "gemini-2.5-flash"

    @AppStorage(SettingsKeys.ttsEnabled) private var ttsEnabled: Bool = false
    @AppStorage(SettingsKeys.ttsAPIKey) private var ttsKey: String = ""
    @AppStorage(SettingsKeys.ttsVoiceID) private var ttsVoiceID: String = ""
    @AppStorage(SettingsKeys.ttsModel) private var ttsModel: String = "eleven_multilingual_v2"
    @AppStorage(SettingsKeys.ttsStability) private var ttsStability: Double = 0.5
    @AppStorage(SettingsKeys.ttsSimilarity) private var ttsSimilarity: Double = 0.75

    @State private var showAnthropicKey: Bool = false
    @State private var showOpenAIKey: Bool = false
    @State private var showTTSKey: Bool = false
    @State private var newPetName: String = ""

    // —— 自启动状态（每次 onAppear 刷新一次；切换后也刷新）
    @State private var loginItemEnabled: Bool = false
    @State private var loginItemNeedsApproval: Bool = false
    @State private var loginItemError: String?

    // —— 音色克隆相关状态
    @State private var pickedAudioURLs: [URL] = []
    @State private var cloneName: String = ""
    @State private var isCloning: Bool = false
    @State private var cloneError: String?
    @State private var cloneSuccessMsg: String?

    var body: some View {
        TabView {
            petsTab
                .tabItem { Label("宠物", systemImage: "pawprint") }

            modelTab
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }

            voiceTab
                .tabItem { Label("语音", systemImage: "waveform") }

            generalTab
                .tabItem { Label("常规", systemImage: "gearshape") }
        }
        // 每个 tab 内部都包 ScrollView，所以窗口可以缩到很小，
        // 同时仍然允许用户拖大显示更多内容。
        .frame(minWidth: 480, idealWidth: 580, minHeight: 380, idealHeight: 560)
        .onAppear { refreshLoginItem() }
    }

    private var modelTab: some View {
        ScrollView {
            Form {
                Section("当前后端") {
                    Picker("Backend", selection: $backend) {
                        ForEach(LLMBackend.allCases, id: \.rawValue) { b in
                            Text(b.label).tag(b.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if backend == LLMBackend.claude.rawValue {
                    claudeSection
                } else {
                    openaiSection
                }
            }
            .padding(20)
        }
    }

    private var petsTab: some View {
        ScrollView {
            Form { petsSection }
                .padding(20)
        }
    }

    private var voiceTab: some View {
        ScrollView {
            Form { ttsSection }
                .padding(20)
        }
    }

    private var generalTab: some View {
        ScrollView {
            Form {
                startupSection

                Section("配置目录") {
                    HStack {
                        Text(AppPaths.supportDir.path).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("打开") { _ = AppLauncher.openPath(AppPaths.supportDir.path) }
                    }
                    if let e = petStore.lastError {
                        Text(e).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            .padding(20)
        }
    }

    private var startupSection: some View {
        Section("自启动") {
            Toggle("开机时自动启动", isOn: Binding(
                get: { loginItemEnabled },
                set: { toggleLoginItem($0) }
            ))
            if loginItemNeedsApproval {
                HStack {
                    Text("需要去系统设置里点「允许」")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("打开系统设置") {
                        LoginItem.openSystemLoginItemsSettings()
                    }
                    .controlSize(.small)
                }
            }
            if let err = loginItemError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Text("提示：要稳定生效，把 CozyPet.app 放到 /Applications。从 Xcode 直接 Run 的那份在 DerivedData 里，Clean Build 后路径会失效。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func refreshLoginItem() {
        loginItemEnabled = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.needsApproval
    }

    private func toggleLoginItem(_ on: Bool) {
        loginItemError = nil
        do {
            if on {
                try LoginItem.enable()
            } else {
                try LoginItem.disable()
            }
        } catch {
            loginItemError = "切换失败：\(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    private var petsSection: some View {
        Section("宠物档案") {
            HStack {
                Picker("当前", selection: Binding(
                    get: { petStore.roster.active },
                    set: { petStore.setActive(id: $0) }
                )) {
                    ForEach(petStore.roster.pets, id: \.id) { p in
                        Text("\(p.name)（\(p.id)）").tag(p.id)
                    }
                }
                Button(role: .destructive) {
                    petStore.delete(id: petStore.active.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("删除当前宠物（至少保留一只）")
                .disabled(petStore.roster.pets.count <= 1)
            }

            HStack {
                TextField("新宠物名字（如 mochi）", text: $newPetName)
                    .textFieldStyle(.roundedBorder)
                Button("新建") {
                    let trimmed = newPetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    _ = petStore.addNew(name: trimmed)
                    newPetName = ""
                }
                .disabled(newPetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            TextField("名字", text: Binding(
                get: { petStore.active.name },
                set: { v in petStore.updateActive { $0.name = v } }
            ))
            .textFieldStyle(.roundedBorder)

            HStack {
                Text("资源前缀").font(.caption).foregroundStyle(.secondary)
                Text(petStore.active.assetPrefix)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Text("Assets 名：\(petStore.active.assetPrefix)-idle / -talk / -think / -sleep ...")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Persona（system prompt）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { petStore.active.persona.systemPrompt },
                    set: { v in petStore.updateActive { $0.persona.systemPrompt = v } }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .border(.quaternary)
            }

            Text("档案文件：\(AppPaths.petsFile.path)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var claudeSection: some View {
        Section("Claude") {
            keyField(
                placeholder: authMode == ClaudeAuthMode.apiKey.rawValue ? "ANTHROPIC_API_KEY" : "ANTHROPIC_AUTH_TOKEN",
                text: $anthropicKey,
                visible: $showAnthropicKey
            )
            TextField("Base URL", text: $anthropicBase)
                .textFieldStyle(.roundedBorder)
                .help("官方：https://api.anthropic.com    aihubmix：https://aihubmix.com")
            Picker("Auth 模式", selection: $authMode) {
                Text("x-api-key（官方）").tag(ClaudeAuthMode.apiKey.rawValue)
                Text("Authorization: Bearer（aihubmix / 第三方代理）").tag(ClaudeAuthMode.authToken.rawValue)
            }
            Picker("模型", selection: $claudeModel) {
                Text("claude-opus-4-7（默认）").tag("claude-opus-4-7")
                Text("claude-sonnet-4-6（便宜）").tag("claude-sonnet-4-6")
                Text("claude-haiku-4-5-20251001（最便宜）").tag("claude-haiku-4-5-20251001")
            }
        }
    }

    private var openaiSection: some View {
        Section("OpenAI 兼容") {
            keyField(placeholder: "API Key", text: $openaiKey, visible: $showOpenAIKey)
            TextField("Base URL", text: $openaiBase)
                .textFieldStyle(.roundedBorder)
                .help("Gemini OpenAI 兼容：https://generativelanguage.googleapis.com/v1beta/openai/\nOpenAI 官方：https://api.openai.com/v1\nOllama 本地：http://localhost:11434/v1")
            HStack {
                TextField("模型名", text: $openaiModel)
                    .textFieldStyle(.roundedBorder)
                    .help("Gemini: gemini-2.5-flash / gemini-2.5-pro / gemini-2.0-flash\nOpenAI: gpt-5 / gpt-4o-mini\nOllama: llama3.1:8b 之类")
                Menu("常用预设") {
                    Button("Gemini 2.5 Flash（快、便宜）") { openaiModel = "gemini-2.5-flash" }
                    Button("Gemini 2.5 Pro（强、贵）") { openaiModel = "gemini-2.5-pro" }
                    Button("Gemini 2.0 Flash") { openaiModel = "gemini-2.0-flash" }
                    Divider()
                    Button("GPT-5") { openaiModel = "gpt-5" }
                    Button("GPT-4o mini") { openaiModel = "gpt-4o-mini" }
                }
                .frame(width: 110)
            }
        }
    }

    private var ttsSection: some View {
        Section("语音 (ElevenLabs TTS)") {
            Toggle("说话时念出来（聊天回复 + 桌宠提醒）", isOn: $ttsEnabled)
            keyField(placeholder: "ELEVENLABS_API_KEY", text: $ttsKey, visible: $showTTSKey)
            HStack {
                Button("前往 elevenlabs.io 注册") {
                    if let url = URL(string: "https://elevenlabs.io/sign-up") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                Text("没账号点这里").font(.caption2).foregroundStyle(.secondary)
            }
            TextField("Voice ID", text: $ttsVoiceID)
                .textFieldStyle(.roundedBorder)
                .help("用下面的克隆功能自动填，或自己去 Voice Lab 复制粘贴")
            Picker("模型", selection: $ttsModel) {
                Text("eleven_multilingual_v2（推荐 / 中英混读）").tag("eleven_multilingual_v2")
                Text("eleven_turbo_v2_5（快 / 便宜）").tag("eleven_turbo_v2_5")
                Text("eleven_v3（最新 / 表现力强）").tag("eleven_v3")
            }
            HStack {
                Text("稳定度 \(String(format: "%.2f", ttsStability))").frame(width: 100, alignment: .leading)
                Slider(value: $ttsStability, in: 0...1)
            }
            HStack {
                Text("相似度 \(String(format: "%.2f", ttsSimilarity))").frame(width: 100, alignment: .leading)
                Slider(value: $ttsSimilarity, in: 0...1)
            }

            Divider()
            voiceCloneSection
        }
    }

    /// 上传 30s+ 音频 → ElevenLabs Voice Lab → 自动写回 voice_id。
    /// 注意：免费档不支持，需要 Starter（$5/月）的 Instant Voice Cloning。
    @ViewBuilder
    private var voiceCloneSection: some View {
        Text("克隆 Taffy 的音色")
            .font(.subheadline.weight(.medium))
        Text("上传 30 秒以上的音频样本（mp3/wav/m4a），自动调 Voice Lab 克隆。需要 ElevenLabs Starter（$5/月）档。")
            .font(.caption2).foregroundStyle(.secondary)

        TextField("音色名字（如 Taffy）", text: $cloneName)
            .textFieldStyle(.roundedBorder)

        HStack {
            Button("选音频") { pickAudioFiles() }
                .controlSize(.small)
                .disabled(isCloning)
            if pickedAudioURLs.isEmpty {
                Text("还没选").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(pickedAudioURLs.map(\.lastPathComponent).joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }

        HStack {
            Button(isCloning ? "克隆中…" : "开始克隆") { Task { await runClone() } }
                .controlSize(.small)
                .disabled(isCloning
                          || ttsKey.trimmingCharacters(in: .whitespaces).isEmpty
                          || pickedAudioURLs.isEmpty
                          || cloneName.trimmingCharacters(in: .whitespaces).isEmpty)
            if isCloning {
                ProgressView().controlSize(.small)
            }
        }

        if let msg = cloneSuccessMsg {
            Text(msg).font(.caption).foregroundStyle(.green)
        }
        if let err = cloneError {
            Text(err).font(.caption).foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func pickAudioFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // 限制为常见音频类型；未识别后缀 ElevenLabs 也会拒，所以提前挡掉
        panel.allowedContentTypes = [.mp3, .wav, .mpeg4Audio, .audio]
        panel.title = "选 Taffy 的音色样本"
        panel.message = "选 ≥30s 的清晰人声，越长越像。多文件会拼起来一起给 Voice Lab。"
        if panel.runModal() == .OK {
            pickedAudioURLs = panel.urls
            cloneError = nil
            cloneSuccessMsg = nil
        }
    }

    private func runClone() async {
        cloneError = nil
        cloneSuccessMsg = nil
        isCloning = true
        defer { isCloning = false }

        let voices = ElevenLabsVoices(apiKey: ttsKey)
        do {
            let voiceID = try await voices.clone(
                name: cloneName.trimmingCharacters(in: .whitespacesAndNewlines),
                description: nil,
                audioFiles: pickedAudioURLs
            )
            ttsVoiceID = voiceID
            cloneSuccessMsg = "克隆成功！voice_id 已自动填好，开关打开就能用了。"
        } catch {
            cloneError = "克隆失败：\(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func keyField(placeholder: String, text: Binding<String>, visible: Binding<Bool>) -> some View {
        HStack {
            if visible.wrappedValue {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .textContentType(.password)
            } else {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                visible.wrappedValue.toggle()
            } label: {
                Image(systemName: visible.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(visible.wrappedValue ? "隐藏" : "显示")
        }
    }

    /// 根据当前 backend 选项构造合适的 LLMProvider —— ChatModel 用这个
    static func makeProvider() -> any LLMProvider {
        let d = UserDefaults.standard
        let backend = LLMBackend(rawValue: d.string(forKey: SettingsKeys.backend) ?? "") ?? .claude
        switch backend {
        case .claude:
            let baseURLString = d.string(forKey: SettingsKeys.anthropicBaseURL) ?? "https://api.anthropic.com"
            let baseURL = URL(string: baseURLString) ?? URL(string: "https://api.anthropic.com")!
            let mode = ClaudeAuthMode(rawValue: d.string(forKey: SettingsKeys.anthropicAuthMode) ?? "")
                ?? .apiKey
            return ClaudeProvider(
                apiKey: d.string(forKey: SettingsKeys.anthropicAPIKey) ?? "",
                model: d.string(forKey: SettingsKeys.claudeModel) ?? "claude-opus-4-7",
                baseURL: baseURL,
                authMode: mode
            )
        case .openai:
            let baseURLString = d.string(forKey: SettingsKeys.openaiBaseURL)
                ?? "https://generativelanguage.googleapis.com/v1beta/openai/"
            let baseURL = URL(string: baseURLString)
                ?? URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
            return OpenAIProvider(
                apiKey: d.string(forKey: SettingsKeys.openaiAPIKey) ?? "",
                model: d.string(forKey: SettingsKeys.openaiModel) ?? "gemini-2.5-flash",
                baseURL: baseURL
            )
        }
    }

    /// 当 TTS 开关打开且 key/voice_id 都有时返回 provider，否则 nil
    static func makeTTSProvider() -> (any TTSProvider)? {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKeys.ttsEnabled) else { return nil }
        let key = d.string(forKey: SettingsKeys.ttsAPIKey) ?? ""
        let voice = d.string(forKey: SettingsKeys.ttsVoiceID) ?? ""
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty,
              !voice.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let model = d.string(forKey: SettingsKeys.ttsModel) ?? "eleven_multilingual_v2"
        let stability = (d.object(forKey: SettingsKeys.ttsStability) as? Double) ?? 0.5
        let similarity = (d.object(forKey: SettingsKeys.ttsSimilarity) as? Double) ?? 0.75
        let base = ElevenLabsTTS(
            apiKey: key,
            voiceID: voice,
            modelID: model,
            stability: stability,
            similarityBoost: similarity
        )
        // 同样的文本 + 同样的音色参数命中缓存，免去重复在线合成。
        let voiceKey = "\(voice)|\(model)|s=\(stability)|b=\(similarity)"
        return CachingTTSProvider(
            inner: base,
            cacheDir: AppPaths.ttsCacheDir,
            voiceKey: voiceKey
        )
    }
}

