import AppKit
import SDWebImage
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

enum TTSBackend: String, CaseIterable {
    case hybridTaffy = "hybrid_taffy"        // 中文本地 Bert-VITS2 Taffy，英文 ElevenLabs Taffy
    case elevenlabs = "elevenlabs"
    case bertVITS2Local = "bertvits2_local"  // 本地跑 Bert-VITS2，xzjosh 的 Taffy 音色

    var label: String {
        switch self {
        case .hybridTaffy: "混合塔菲（中文本地 / 英文 ElevenLabs）"
        case .elevenlabs: "ElevenLabs（云端）"
        case .bertVITS2Local: "本地 Bert-VITS2 Taffy"
        }
    }
}

/// Settings 里切了 TTS backend 之后发这个；AppDelegate 监听后决定 start / stop Python server。
extension Notification.Name {
    static let ttsBackendChanged = Notification.Name("pet.tts.backendChanged")
    /// 用户在 Settings 里换 / 删了自定义形象后发这个；浮动桌宠窗口监听后重抽当前 mood 的图。
    static let petSpritesChanged = Notification.Name("pet.sprites.changed")
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

    // TTS 通用
    static let ttsEnabled = "tts.enabled"
    static let ttsBackend = "tts.backend"      // TTSBackend.rawValue

    // TTS（ElevenLabs）
    static let ttsAPIKey = "tts.elevenlabs.api_key"
    static let ttsBaseURL = "tts.elevenlabs.base_url"
    static let ttsVoiceID = "tts.elevenlabs.voice_id"
    static let ttsModel = "tts.elevenlabs.model"
    static let ttsStability = "tts.elevenlabs.stability"
    static let ttsSimilarity = "tts.elevenlabs.similarity"
}

private let defaultTTSEnabled = true

struct SettingsView: View {
    static func isTTSEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: SettingsKeys.ttsEnabled) != nil else {
            return defaultTTSEnabled
        }
        return defaults.bool(forKey: SettingsKeys.ttsEnabled)
    }

    @ObservedObject var petStore: PetStore

    @AppStorage(SettingsKeys.backend) private var backend: String = LLMBackend.claude.rawValue

    @AppStorage(SettingsKeys.anthropicAPIKey) private var anthropicKey: String = ProxyConfig.prefillProxyOnFirstLaunch ? ProxyConfig.clientToken : ""
    @AppStorage(SettingsKeys.anthropicBaseURL) private var anthropicBase: String = ProxyConfig.prefillProxyOnFirstLaunch ? ProxyConfig.anthropicBaseURL : "https://api.anthropic.com"
    @AppStorage(SettingsKeys.anthropicAuthMode) private var authMode: String = ClaudeAuthMode.apiKey.rawValue
    @AppStorage(SettingsKeys.claudeModel) private var claudeModel: String = "claude-opus-4-7"

    @AppStorage(SettingsKeys.openaiAPIKey) private var openaiKey: String = ""
    @AppStorage(SettingsKeys.openaiBaseURL) private var openaiBase: String = "https://generativelanguage.googleapis.com/v1beta/openai/"
    @AppStorage(SettingsKeys.openaiModel) private var openaiModel: String = "gemini-2.5-flash"

    @AppStorage(SettingsKeys.ttsEnabled) private var ttsEnabled: Bool = defaultTTSEnabled
    @AppStorage(SettingsKeys.ttsBackend) private var ttsBackend: String = TTSBackend.hybridTaffy.rawValue
    @AppStorage(SettingsKeys.ttsAPIKey) private var ttsKey: String = ProxyConfig.prefillProxyOnFirstLaunch ? ProxyConfig.clientToken : ""
    @AppStorage(SettingsKeys.ttsBaseURL) private var ttsBase: String = ProxyConfig.prefillProxyOnFirstLaunch ? ProxyConfig.elevenlabsBaseURL : "https://api.elevenlabs.io"
    @AppStorage(SettingsKeys.ttsVoiceID) private var ttsVoiceID: String = ProxyConfig.defaultVoiceID
    @AppStorage(SettingsKeys.ttsModel) private var ttsModel: String = "eleven_multilingual_v2"
    @AppStorage(SettingsKeys.ttsStability) private var ttsStability: Double = 0.5
    @AppStorage(SettingsKeys.ttsSimilarity) private var ttsSimilarity: Double = 0.75

    @ObservedObject private var localTTSServer = LocalTTSServer.shared

    @State private var showAnthropicKey: Bool = false
    @State private var showOpenAIKey: Bool = false
    @State private var showTTSKey: Bool = false
    @State private var newPetName: String = ""

    // —— 自定义形象相关状态
    @State private var spriteImportError: String?
    /// 换 / 删图后自增，强制形象区重算各状态的「已自定义 / 内置 / 缺」标签。
    @State private var spriteRefreshToken: Int = 0

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
                Picker("当前宠物", selection: Binding(
                    get: { petStore.roster.active },
                    set: { petStore.setActive(id: $0) }
                )) {
                    ForEach(petStore.roster.pets, id: \.id) { p in
                        Text(p.name).tag(p.id)
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

            // —— 新建一只全新的宠物（建完自动切过去）
            VStack(alignment: .leading, spacing: 4) {
                Text("新建一只宠物").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("新宠物的名字（如 mochi）", text: $newPetName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { createPet() }
                    Button("新建并切换") { createPet() }
                        .disabled(newPetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("建好后会自动切到这只新宠物，再到下面「形象」区给它逐个状态导入 GIF / 图片。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider()

            // —— 以下都是在编辑「当前激活」的那只宠物
            Text("编辑当前宠物「\(petStore.active.name)」").font(.caption).foregroundStyle(.secondary)

            TextField("重命名", text: Binding(
                get: { petStore.active.name },
                set: { v in petStore.updateActive { $0.name = v } }
            ))
            .textFieldStyle(.roundedBorder)

            HStack {
                Text("资源前缀").font(.caption).foregroundStyle(.secondary)
                Text(petStore.active.assetPrefix)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Text("内置 Assets 名：\(petStore.active.assetPrefix)-idle / -cheer …（没有就用下面导入的）")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            petVoicePicker

            spriteCustomizer

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

    /// 这只宠物用什么声音 —— 空串 = 跟随默认（塔菲混合、其它 ElevenLabs）。
    /// ElevenLabs 的 key / voice id 等仍在「语音」标签页里共用配置。
    @ViewBuilder
    private var petVoicePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker("声音", selection: Binding(
                get: { petStore.active.voiceBackend ?? "" },
                set: { v in
                    petStore.updateActive { $0.voiceBackend = v.isEmpty ? nil : v }
                    NotificationCenter.default.post(name: .ttsBackendChanged, object: nil)
                }
            )) {
                Text("跟随默认").tag("")
                Text(TTSBackend.hybridTaffy.label).tag(TTSBackend.hybridTaffy.rawValue)
                Text(TTSBackend.elevenlabs.label).tag(TTSBackend.elevenlabs.rawValue)
                Text(TTSBackend.bertVITS2Local.label).tag(TTSBackend.bertVITS2Local.rawValue)
            }
            Text("默认：永雏塔菲走「混合塔菲」（本地中文 + ElevenLabs 英文），其它宠物走 ElevenLabs（需在「语音」页填 key 与 voice id）。当前生效：\(currentVoiceLabel)")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentVoiceLabel: String {
        TTSBackend(rawValue: petStore.active.resolvedVoiceBackend)?.label ?? petStore.active.resolvedVoiceBackend
    }

    /// 当前宠物的自定义形象区：逐状态选图 + 打开素材文件夹 + 刷新。
    /// 折叠在 DisclosureGroup 里，11 个状态不至于把宠物档案撑得太长。
    private var spriteCustomizer: some View {
        DisclosureGroup("形象（每个状态一张动图）") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("打开素材文件夹") { openSpriteFolder() }
                    Button("刷新") { refreshSprites() }
                    Spacer()
                }
                Text("每一行：🔍 浏览器搜「角色 + 状态」的 GIF（保存到本机再回来导入）；「选图…」从本机导入。文件名规则：idle.gif / cheer.gif…，变体加 -2…-5。")
                    .font(.caption2).foregroundStyle(.secondary)
                if let err = spriteImportError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
                ForEach(PetMood.allCases, id: \.self) { mood in
                    spriteRow(mood)
                }
            }
            .id(spriteRefreshToken)   // 换图后强制重算下面各行状态
        }
    }

    private func spriteRow(_ mood: PetMood) -> some View {
        let prefix = petStore.active.assetPrefix
        let isCustom = PetSprites.customSpriteURL(prefix: prefix, mood: mood.rawValue) != nil
        let hasBundle = bundleSpriteExists(prefix: prefix, mood: mood.rawValue)
        return HStack(spacing: 8) {
            Text(mood.label).frame(width: 52, alignment: .leading)
            if isCustom {
                Text("已自定义").foregroundStyle(.green)
            } else if hasBundle {
                Text("内置").foregroundStyle(.secondary)
            } else {
                Text("缺").foregroundStyle(.orange)
            }
            Spacer()
            Button {
                searchGifInBrowser(for: mood)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("浏览器搜「\(petStore.active.name) \(mood.label) gif」(动图),找到合适的存下来再点旁边「选图…」导入")
            Button(isCustom ? "换图…" : "选图…") { pickSprite(for: mood) }
            if isCustom {
                Button {
                    PetSprites.removeUserSprites(prefix: prefix, mood: mood.rawValue)
                    refreshSprites()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("删掉自定义，恢复内置")
            }
        }
        .font(.caption)
    }

    /// 拼「宠物名 + 状态 + gif」给 Google Images,带 `itp:animated` 滤掉静态图。
    /// 不在 app 里嵌搜索 UI / 调 API —— 用户右键存图后回来点「选图…」即可。
    /// 中文 / 英文 / 混搜都吃,UTF-8 percent-encoding 走 urlQueryAllowed。
    private func searchGifInBrowser(for mood: PetMood) {
        let petName = petStore.active.name.trimmingCharacters(in: .whitespaces)
        let query = "\(petName) \(mood.label) gif"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "https://www.google.com/search?q=\(encoded)&tbm=isch&tbs=itp:animated"
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    private func createPet() {
        let trimmed = newPetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = petStore.addNew(name: trimmed)   // addNew 会自动把新宠物设为激活
        newPetName = ""
    }

    private func bundleSpriteExists(prefix: String, mood: String) -> Bool {
        let name = "\(prefix)-\(mood)"
        if Bundle.main.url(forResource: name, withExtension: "gif") != nil { return true }
        return NSImage(named: name) != nil
    }

    private func pickSprite(for mood: PetMood) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.gif, .png, .webP, .heic]
        panel.title = "选「\(mood.label)」的动图"
        panel.message = "选一张 GIF / PNG / WebP，会成为当前宠物「\(mood.label)」状态的形象。建议用会动的 GIF。"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        do {
            let dest = try PetSprites.importSprite(
                from: src, prefix: petStore.active.assetPrefix, mood: mood.rawValue
            )
            SDImageCache.shared.removeImage(forKey: dest.absoluteString, fromDisk: true)
            spriteImportError = nil
            spriteRefreshToken += 1
            NotificationCenter.default.post(name: .petSpritesChanged, object: nil)
        } catch {
            spriteImportError = "导入失败：\(error.localizedDescription)"
        }
    }

    private func openSpriteFolder() {
        let dir = AppPaths.spritesDir(prefix: petStore.active.assetPrefix, create: true)
        NSWorkspace.shared.open(dir)
    }

    private func refreshSprites() {
        for url in PetSprites.allUserSpriteURLs() {
            SDImageCache.shared.removeImage(forKey: url.absoluteString, fromDisk: true)
        }
        SDImageCache.shared.clearMemory()
        spriteImportError = nil
        spriteRefreshToken += 1
        NotificationCenter.default.post(name: .petSpritesChanged, object: nil)
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
                .help("Gemini OpenAI 兼容：https://generativelanguage.googleapis.com/v1beta/openai/\nOpenAI 官方：https://api.openai.com/v1\naihubmix：https://aihubmix.com/v1\nOllama 本地：http://localhost:11434/v1")
            HStack {
                TextField("模型名", text: $openaiModel)
                    .textFieldStyle(.roundedBorder)
                    .help("Gemini: gemini-2.5-flash / gemini-2.5-pro / gemini-2.0-flash\nOpenAI: gpt-5 / gpt-4o-mini\naihubmix 支持上面所有模型名\nOllama: llama3.1:8b 之类")
                Menu("常用预设") {
                    Button("Gemini 2.5 Flash（快、便宜）") { openaiModel = "gemini-2.5-flash" }
                    Button("Gemini 2.5 Pro（强、贵）") { openaiModel = "gemini-2.5-pro" }
                    Button("Gemini 2.0 Flash") { openaiModel = "gemini-2.0-flash" }
                    Divider()
                    Button("GPT-5") { openaiModel = "gpt-5" }
                    Button("GPT-4o mini") { openaiModel = "gpt-4o-mini" }
                    Divider()
                    Section("aihubmix（一个 Key 多家模型）") {
                        Button("aihubmix · Gemini 2.5 Pro") {
                            openaiBase = "https://aihubmix.com/v1"
                            openaiModel = "gemini-2.5-pro"
                        }
                        Button("aihubmix · Gemini 2.5 Flash") {
                            openaiBase = "https://aihubmix.com/v1"
                            openaiModel = "gemini-2.5-flash"
                        }
                        Button("aihubmix · Claude Sonnet 4.6") {
                            openaiBase = "https://aihubmix.com/v1"
                            openaiModel = "claude-sonnet-4-6"
                        }
                        Button("aihubmix · GPT-5") {
                            openaiBase = "https://aihubmix.com/v1"
                            openaiModel = "gpt-5"
                        }
                    }
                }
                .frame(width: 110)
            }
            HStack {
                Spacer()
                Button("前往 aihubmix 注册（一个 Key 用 Gemini/Claude/GPT）") {
                    if let url = URL(string: "https://aihubmix.com") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var ttsSection: some View {
        Section("语音") {
            Toggle("说话时念出来（聊天回复 + 桌宠提醒）", isOn: $ttsEnabled)
                .onChange(of: ttsEnabled) { _, _ in
                    NotificationCenter.default.post(name: .ttsBackendChanged, object: nil)
                }
            Picker("TTS 后端", selection: $ttsBackend) {
                ForEach(TTSBackend.allCases, id: \.rawValue) { b in
                    Text(b.label).tag(b.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: ttsBackend) { _, _ in
                NotificationCenter.default.post(name: .ttsBackendChanged, object: nil)
            }

            if ttsBackend == TTSBackend.hybridTaffy.rawValue {
                hybridTaffySection
            } else if ttsBackend == TTSBackend.bertVITS2Local.rawValue {
                localTTSSection
            } else {
                elevenLabsSection
            }
        }
    }

    @ViewBuilder
    private var hybridTaffySection: some View {
        Text("中文默认走本地 Bert-VITS2 永雏塔菲；英文 / 拉丁字母片段走 ElevenLabs 里的塔菲 Voice ID。只有切到 ElevenLabs 或克隆新 voice id 时，才会全段使用云端音色。")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        localTTSSection

        Divider()
        Text("英文段 ElevenLabs 音色")
            .font(.subheadline.weight(.medium))
        elevenLabsSection
    }

    /// ElevenLabs（云端）面板 —— 老的字段都迁过来。
    @ViewBuilder
    private var elevenLabsSection: some View {
        keyField(placeholder: "ELEVENLABS_API_KEY", text: $ttsKey, visible: $showTTSKey)
        TextField("Base URL", text: $ttsBase)
            .textFieldStyle(.roundedBorder)
            .help("官方：https://api.elevenlabs.io    自建代理：https://your-proxy.example.com")
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

    /// 本地 Bert-VITS2 Taffy 面板 —— 状态 pill + 操作按钮。
    @ViewBuilder
    private var localTTSSection: some View {
        Text("跑的是 xzjosh 永雏塔菲音色（Bert-VITS2 v2.3）。中文最自然；英文 / 日文也能念，但毕竟是中文音色训出来的，混排时口音会偏「塔菲念英语」—— 如果觉得太假可以切回 ElevenLabs。")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
            Text("状态")
            statusPill(localTTSServer.status)
            Spacer()
        }

        if !localTTSServer.isInstalled {
            HStack {
                Text("还没装好（缺 venv 或 server.py）").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("一键安装") { localTTSServer.openInstallerInTerminal() }
                    .controlSize(.small)
            }
            Text("安装会在 Terminal 弹个新窗口跑 ~/Code/pet/tts-server/setup.sh，大概 15-30 分钟（要 git-lfs 拉 ~4GB 模型）。装完点上面的「重启服务」。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Button("重启服务") { localTTSServer.restart() }
                .controlSize(.small)
                .disabled(!localTTSServer.isInstalled)
            Button("打开模型目录") { localTTSServer.openServerDirectoryInFinder() }
                .controlSize(.small)
            Button("看 server.log") { localTTSServer.openLog() }
                .controlSize(.small)
            Button("重新安装") { localTTSServer.openInstallerInTerminal() }
                .controlSize(.small)
        }

        if case .crashed(let msg) = localTTSServer.status {
            Text(msg)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .lineLimit(8)
        }
    }

    @ViewBuilder
    private func statusPill(_ status: LocalTTSServer.Status) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .notInstalled: return ("❌ 未安装", .orange)
            case .stopped:      return ("⏸ 未启动", .secondary)
            case .starting:     return ("⏳ 启动中…", .blue)
            case .ready:        return ("✅ 运行中", .green)
            case .crashed:      return ("💥 崩了", .red)
            }
        }()
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
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

        let baseURL = URL(string: ttsBase) ?? URL(string: "https://api.elevenlabs.io")!
        let voices = ElevenLabsVoices(apiKey: ttsKey, baseURL: baseURL)
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

    /// 当 TTS 开关打开且对应 backend 配置齐全时返回 provider，否则 nil。
    /// 声音是「按宠物」的：传进来的 pet 决定走哪个后端 —— 塔菲走「混合塔菲」（本地中文 +
    /// ElevenLabs 英文），其它宠物默认走 ElevenLabs（见 PetProfile.resolvedVoiceBackend）。
    /// 不传 pet 时退回全局设置里的默认后端。两边缓存 voiceKey 不同所以不会打架。
    static func makeTTSProvider(for pet: PetProfile? = nil) -> (any TTSProvider)? {
        let d = UserDefaults.standard
        guard isTTSEnabled(d) else { return nil }
        let backend: TTSBackend = {
            if let raw = pet?.resolvedVoiceBackend, let b = TTSBackend(rawValue: raw) { return b }
            return TTSBackend(rawValue: d.string(forKey: SettingsKeys.ttsBackend) ?? "") ?? .hybridTaffy
        }()

        switch backend {
        case .hybridTaffy:
            let local = CachingTTSProvider(
                inner: LocalBertVITS2TTS(),
                cacheDir: AppPaths.ttsCacheDir,
                voiceKey: "bert-vits2-taffy-zh-2.3"
            )
            let key = d.string(forKey: SettingsKeys.ttsAPIKey) ?? ""
            let voice = d.string(forKey: SettingsKeys.ttsVoiceID) ?? ""
            let cloud: (any TTSProvider)?
            if !key.trimmingCharacters(in: .whitespaces).isEmpty,
               !voice.trimmingCharacters(in: .whitespaces).isEmpty {
                let baseURLString = d.string(forKey: SettingsKeys.ttsBaseURL) ?? "https://api.elevenlabs.io"
                let baseURL = URL(string: baseURLString) ?? URL(string: "https://api.elevenlabs.io")!
                let model = d.string(forKey: SettingsKeys.ttsModel) ?? "eleven_multilingual_v2"
                let stability = (d.object(forKey: SettingsKeys.ttsStability) as? Double) ?? 0.5
                let similarity = (d.object(forKey: SettingsKeys.ttsSimilarity) as? Double) ?? 0.75
                let eleven = ElevenLabsTTS(
                    apiKey: key,
                    voiceID: voice,
                    modelID: model,
                    baseURL: baseURL,
                    stability: stability,
                    similarityBoost: similarity
                )
                cloud = CachingTTSProvider(
                    inner: eleven,
                    cacheDir: AppPaths.ttsCacheDir,
                    voiceKey: "elevenlabs-taffy-en|\(baseURLString)|\(voice)|\(model)|s=\(stability)|b=\(similarity)"
                )
            } else {
                cloud = nil
            }
            return HybridTaffyTTSProvider(localTaffy: local, elevenLabs: cloud)

        case .elevenlabs:
            let key = d.string(forKey: SettingsKeys.ttsAPIKey) ?? ""
            let voice = d.string(forKey: SettingsKeys.ttsVoiceID) ?? ""
            guard !key.trimmingCharacters(in: .whitespaces).isEmpty,
                  !voice.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let baseURLString = d.string(forKey: SettingsKeys.ttsBaseURL) ?? "https://api.elevenlabs.io"
            let baseURL = URL(string: baseURLString) ?? URL(string: "https://api.elevenlabs.io")!
            let model = d.string(forKey: SettingsKeys.ttsModel) ?? "eleven_multilingual_v2"
            let stability = (d.object(forKey: SettingsKeys.ttsStability) as? Double) ?? 0.5
            let similarity = (d.object(forKey: SettingsKeys.ttsSimilarity) as? Double) ?? 0.75
            let base = ElevenLabsTTS(
                apiKey: key,
                voiceID: voice,
                modelID: model,
                baseURL: baseURL,
                stability: stability,
                similarityBoost: similarity
            )
            let voiceKey = "elevenlabs|\(baseURLString)|\(voice)|\(model)|s=\(stability)|b=\(similarity)"
            return CachingTTSProvider(
                inner: base,
                cacheDir: AppPaths.ttsCacheDir,
                voiceKey: voiceKey
            )

        case .bertVITS2Local:
            let inner = LocalBertVITS2TTS()
            // 跟 ElevenLabs 缓存不打架：voiceKey 加固定 prefix
            return CachingTTSProvider(
                inner: inner,
                cacheDir: AppPaths.ttsCacheDir,
                voiceKey: "bert-vits2-taffy-2.3"
            )
        }
    }
}
