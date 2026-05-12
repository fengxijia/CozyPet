import Combine
import SwiftUI
import PetCore

@MainActor
final class WorkflowStore: ObservableObject {
    @Published var workflow: Workflow?
    @Published var doneIDs: Set<String> = []
    @Published var lastError: String?

    private var doneKey: String { AppPaths.todayDoneKey() }
    private let loader = WorkflowLoader()

    init() {
        reload()
    }

    func reload() {
        let userURL = AppPaths.workflowFile
        let bundleURL = Bundle.main.url(forResource: "sample-workflow", withExtension: "yaml")
        let url = FileManager.default.fileExists(atPath: userURL.path) ? userURL : bundleURL

        guard let url else {
            self.workflow = nil
            self.lastError = "找不到工作流文件。把 sample-workflow.yaml 复制到 \(userURL.path) 并改成你的日常。"
            return
        }
        do {
            self.workflow = try loader.load(from: url)
            self.lastError = nil
        } catch {
            self.workflow = nil
            self.lastError = "解析工作流失败：\(error)"
        }

        let stored = UserDefaults.standard.stringArray(forKey: doneKey) ?? []
        self.doneIDs = Set(stored)
    }

    func toggle(_ stepID: String) {
        if doneIDs.contains(stepID) { doneIDs.remove(stepID) }
        else { doneIDs.insert(stepID) }
        UserDefaults.standard.set(Array(doneIDs), forKey: doneKey)
    }

    // MARK: - CRUD

    /// 用户第一次编辑前，工作流可能来自 bundle。任何修改都要落到 user yaml，
    /// 同时保证 self.workflow 非 nil。
    private func ensureWorkflow() -> Workflow {
        if let wf = workflow { return wf }
        let wf = Workflow(name: "今日工作流", steps: [])
        workflow = wf
        return wf
    }

    func addStep(_ step: WorkflowStep) {
        var wf = ensureWorkflow()
        wf.steps.append(step)
        workflow = wf
        persist()
    }

    func updateStep(_ step: WorkflowStep) {
        guard var wf = workflow,
              let idx = wf.steps.firstIndex(where: { $0.id == step.id }) else { return }
        wf.steps[idx] = step
        workflow = wf
        persist()
    }

    func deleteStep(id: String) {
        guard var wf = workflow else { return }
        wf.steps.removeAll { $0.id == id }
        workflow = wf
        doneIDs.remove(id)
        UserDefaults.standard.set(Array(doneIDs), forKey: doneKey)
        persist()
    }

    func moveSteps(from offsets: IndexSet, to destination: Int) {
        guard var wf = workflow else { return }
        wf.steps.move(fromOffsets: offsets, toOffset: destination)
        workflow = wf
        persist()
    }

    /// 检查给定 id 在当前 workflow 里是否已存在（排除 excluding 自己用于编辑场景）。
    func idExists(_ id: String, excluding: String? = nil) -> Bool {
        guard let wf = workflow else { return false }
        return wf.steps.contains { $0.id == id && $0.id != excluding }
    }

    private func persist() {
        guard let wf = workflow else { return }
        do {
            try loader.save(wf, to: AppPaths.workflowFile)
            lastError = nil
        } catch {
            lastError = "保存工作流失败：\(error)"
        }
    }
}

struct WorkflowPanel: View {
    @Bindable var state: PetStateMachine
    @ObservedObject var store: WorkflowStore
    @ObservedObject var voice: VoicePlayer
    @StateObject private var notesStore = NotesStore()

    @State private var editingStep: WorkflowStep?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VSplitView {
                stepsArea
                    .frame(minHeight: 120)
                NotesPanel(state: state, store: notesStore, voice: voice)
                    .frame(minHeight: 80)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(idealWidth: 540, idealHeight: 600)
        .sheet(item: $editingStep) { step in
            StepEditor(
                mode: .edit(original: step),
                store: store,
                onClose: { editingStep = nil }
            )
        }
        .sheet(isPresented: $isCreating) {
            StepEditor(
                mode: .create,
                store: store,
                onClose: { isCreating = false }
            )
        }
    }

    @ViewBuilder
    private var stepsArea: some View {
        if let wf = store.workflow, !wf.steps.isEmpty {
            List {
                ForEach(wf.steps) { step in
                    StepRow(
                        step: step,
                        done: store.doneIDs.contains(step.id),
                        onRun: { run(step) },
                        onToggle: { store.toggle(step.id) },
                        onEdit: { editingStep = step },
                        onDelete: { store.deleteStep(id: step.id) }
                    )
                }
                .onMove { offsets, dest in
                    store.moveSteps(from: offsets, to: dest)
                }
            }
            .listStyle(.plain)
        } else if let err = store.lastError {
            ScrollView { Text(err).padding() }
        } else if store.workflow != nil {
            emptyHint
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(store.workflow?.name ?? "今日工作流")
                    .font(.title3.weight(.semibold))
                if let wf = store.workflow {
                    Text("\(store.doneIDs.intersection(Set(wf.steps.map(\.id))).count) / \(wf.steps.count) 已完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                isCreating = true
            } label: {
                Label("新建", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("从磁盘重新加载")
        }
        .padding()
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Text("还没有任何步骤")
                .foregroundStyle(.secondary)
            Button {
                isCreating = true
            } label: {
                Label("添加第一步", systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("配置文件：~/Library/Application Support/Pet/workflow.yaml")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("打开配置目录") {
                _ = AppLauncher.openPath(AppPaths.supportDir.path)
            }
            .controlSize(.small)
        }
        .padding(8)
    }

    private func run(_ step: WorkflowStep) {
        state.noteInteraction()
        let say = step.say ?? "开始下一步"
        let ok = WorkflowRunner.run(step)
        if !ok {
            state.say("没打开成功，检查一下 bundle id / URL", mood: .confused)
            return
        }
        state.say(say, mood: .cheer)
        if !store.doneIDs.contains(step.id) {
            store.toggle(step.id)
        }
    }
}

private struct StepRow: View {
    let step: WorkflowStep
    let done: Bool
    let onRun: () -> Void
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.say ?? step.id)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                if let detail = stepDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button(step.resolvedKind == .prompt ? "念一下" : "启动") { onRun() }
                .controlSize(.small)

            Menu {
                Button("编辑…") { onEdit() }
                Divider()
                Button("删除", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private var stepDetail: String? {
        switch step.resolvedKind {
        case .app:
            // app + path 组合：让 X app 打开 Y 路径
            if let app = step.openApp, let path = step.openPath {
                return "\(app) → \(path)"
            }
            return step.openApp.map { "app: \($0)" }
        case .url: return step.openURL.map { "url: \($0)" }
        case .path: return step.openPath.map { "path: \($0)" }
        case .prompt: return "提醒"
        }
    }
}

// MARK: - Step Editor sheet

private enum EditorMode {
    case create
    case edit(original: WorkflowStep)
}

private struct StepEditor: View {
    let mode: EditorMode
    @ObservedObject var store: WorkflowStore
    let onClose: () -> Void

    @State private var stepID: String = ""
    @State private var say: String = ""
    @State private var kind: StepKind = .prompt
    @State private var target: String = ""
    /// 仅当 kind == .app 时使用：可选的路径，会被传给那个 app 打开
    /// （比如 VSCode + 项目文件夹路径）。
    @State private var appOpenPath: String = ""
    @State private var thenPrompt: String = ""
    @State private var error: String?

    /// 常用 app 的 bundle ID 预设
    private static let appPresets: [(label: String, bundleID: String)] = [
        ("VSCode", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Terminal", "com.apple.Terminal"),
        ("Safari", "com.apple.Safari"),
        ("Chrome", "com.google.Chrome"),
        ("Notion", "notion.id"),
        ("Finder", "com.apple.finder"),
    ]

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var originalID: String? {
        if case .edit(let s) = mode { return s.id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isEditing ? "编辑步骤" : "新建步骤")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding()
            Divider()

            Form {
                Section {
                    TextField("ID（英文标识，比如 emnlp-check）", text: $stepID)
                        .textFieldStyle(.roundedBorder)
                    TextField("说点什么（桌宠会念这句）", text: $say, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                }

                Section("动作") {
                    Picker("类型", selection: $kind) {
                        Text("打开 App").tag(StepKind.app)
                        Text("打开 URL").tag(StepKind.url)
                        Text("打开路径").tag(StepKind.path)
                        Text("纯提醒（无动作）").tag(StepKind.prompt)
                    }
                    .pickerStyle(.segmented)

                    switch kind {
                    case .app:
                        HStack {
                            TextField("Bundle ID，如 com.apple.Safari", text: $target)
                                .textFieldStyle(.roundedBorder)
                            Menu("常用") {
                                ForEach(Self.appPresets, id: \.bundleID) { p in
                                    Button("\(p.label) — \(p.bundleID)") { target = p.bundleID }
                                }
                            }
                            .controlSize(.small)
                            .frame(width: 70)
                        }
                        HStack {
                            TextField("可选：打开这个路径（让 app 接收）", text: $appOpenPath)
                                .textFieldStyle(.roundedBorder)
                            Button("选…") { pickAppOpenPath() }
                                .controlSize(.small)
                        }
                        Text("例：用 VSCode 打开项目 → Bundle ID 选 VSCode，路径选 EMNLP26_SnowballCost 文件夹")
                            .font(.caption2).foregroundStyle(.secondary)
                    case .url:
                        TextField("https://… 或 notion://…", text: $target)
                            .textFieldStyle(.roundedBorder)
                    case .path:
                        HStack {
                            TextField("/Users/.../folder", text: $target)
                                .textFieldStyle(.roundedBorder)
                            Button("选…") { pickPath() }
                                .controlSize(.small)
                        }
                        Text("默认会用 Finder 打开。想用某个 app 打开请换上面的「打开 App」类型。")
                            .font(.caption2).foregroundStyle(.secondary)
                    case .prompt:
                        EmptyView()
                    }
                }

                Section("可选") {
                    TextField("then_prompt（点完后追加的提示，可空）", text: $thenPrompt, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .keyboardShortcut(.escape)
                Button(isEditing ? "保存" : "添加") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 460, idealHeight: 520)
        .onAppear { loadInitial() }
    }

    private func loadInitial() {
        if case .edit(let s) = mode {
            stepID = s.id
            say = s.say ?? ""
            kind = s.resolvedKind
            switch s.resolvedKind {
            case .app:
                target = s.openApp ?? ""
                appOpenPath = s.openPath ?? ""   // 「用 X app 打开 Y 路径」的 Y
            case .url: target = s.openURL ?? ""
            case .path: target = s.openPath ?? ""
            case .prompt: target = ""
            }
            thenPrompt = s.thenPrompt ?? ""
        } else {
            stepID = "step-\(Int(Date().timeIntervalSince1970))"
        }
    }

    private func pickPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            target = url.path
        }
    }

    private func pickAppOpenPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            appOpenPath = url.path
        }
    }

    private func save() {
        let trimmedID = stepID.trimmingCharacters(in: .whitespaces)
        guard !trimmedID.isEmpty else {
            error = "ID 不能为空"
            return
        }
        if store.idExists(trimmedID, excluding: originalID) {
            error = "已经有步骤用了这个 ID，换一个"
            return
        }

        // 路径字段只去换行，不去空格 —— 文件夹名末尾可以合法地带空格
        // （macOS 完全允许，NSOpenPanel 也会原样返回）。
        let pathOnlyTarget = target.trimmingCharacters(in: .newlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)

        if kind != .prompt {
            let hasTarget = (kind == .path)
                ? !pathOnlyTarget.isEmpty
                : !trimmedTarget.isEmpty
            if !hasTarget {
                error = "这个动作类型必须填目标"
                return
            }
        }

        let trimmedSay = say.trimmingCharacters(in: .whitespaces)
        let trimmedThen = thenPrompt.trimmingCharacters(in: .whitespaces)
        let pathOnlyAppPath = appOpenPath.trimmingCharacters(in: .newlines)

        // .app 类型可以额外带一个路径，runner 会把路径交给 app 打开。
        // .path 类型则单独走 path，没有伴随 bundle id。
        let openPathField: String? = {
            switch kind {
            case .app: return pathOnlyAppPath.isEmpty ? nil : pathOnlyAppPath
            case .path: return pathOnlyTarget
            default: return nil
            }
        }()

        let step = WorkflowStep(
            id: trimmedID,
            say: trimmedSay.isEmpty ? nil : trimmedSay,
            openApp: kind == .app ? trimmedTarget : nil,
            openURL: kind == .url ? trimmedTarget : nil,
            openPath: openPathField,
            kind: kind == .prompt ? .prompt : nil,
            thenPrompt: trimmedThen.isEmpty ? nil : trimmedThen
        )

        if isEditing {
            store.updateStep(step)
        } else {
            store.addStep(step)
        }
        onClose()
    }
}

// MARK: - 暖心便签 (Encouragement notes)

struct WorkflowNote: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String = ""
}

/// 跟 todo 完全隔离 —— 这边是给自己写鼓励 / 提醒 / 小温暖的，
/// 不需要勾选、不需要"今天完成"概念，落盘成一个 JSON 数组就够。
@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [WorkflowNote] = []
    private let file = AppPaths.notesFile

    init() { reload() }

    func reload() {
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([WorkflowNote].self, from: data) else {
            // 第一次打开（没文件）：塞几条默认的暖心便签；用户随时可改可删。
            notes = NotesStore.defaultNotes
            persist()
            return
        }
        notes = decoded
    }

    private static let defaultNotes: [WorkflowNote] = [
        WorkflowNote(text: "开心最重要！"),
        WorkflowNote(text: "早睡早起，开心一整天～"),
        WorkflowNote(text: "主人已经超优秀了！知足常乐哟～"),
    ]

    func add() {
        notes.append(WorkflowNote(text: ""))
        persist()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        persist()
    }

    func updateText(_ id: UUID, _ text: String) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[idx].text != text else { return }
        notes[idx].text = text
        persist()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        notes.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    private func persist() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(notes)
            try data.write(to: file, options: .atomic)
        } catch {
            // 安静失败 —— 下次保存还有机会
        }
    }
}

private struct NotesPanel: View {
    let state: PetStateMachine
    @ObservedObject var store: NotesStore
    @ObservedObject var voice: VoicePlayer
    @State private var ttsAlert: String?
    /// 下一条要念的便签下标。被工作流打断后用它续读；念完整轮归零。
    @State private var currentIndex: Int = 0
    /// 真正在念便签（区别于"工作流也在用 voice"）。
    /// 喇叭按钮只看这个，不看全局 voice.isPlaying，否则工作流播 todo 时这边喇叭也会跟着切成停止图标。
    @State private var isReadingNotes: Bool = false

    private var hasContent: Bool {
        store.notes.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(.pink.opacity(0.7))
                Text("暖心便签")
                    .font(.subheadline.weight(.semibold))
                Text("\(store.notes.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    toggleSpeak()
                } label: {
                    Image(systemName: isReadingNotes ? "stop.circle.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(isReadingNotes ? .pink : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!hasContent && !isReadingNotes)
                .help(isReadingNotes ? "停止" : "依次念出全部便签")

                Button {
                    store.add()
                } label: {
                    Label("添加", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("加一句给自己的鼓励")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if store.notes.isEmpty {
                VStack(spacing: 4) {
                    Text("写点强心 / 温馨的话留给未来的自己")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("点 +「添加」")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(store.notes) { note in
                        NoteRow(
                            text: Binding(
                                get: { note.text },
                                set: { store.updateText(note.id, $0) }
                            ),
                            onDelete: { store.delete(note.id) }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { ttsAlert != nil },
            set: { if !$0 { ttsAlert = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(ttsAlert ?? "")
        }
        // 增 / 删 / 调顺序后重新从头读，不要继续指着可能错位的下标。
        // 改文字（同一组 id）不重置，保持续读体验。
        .onChange(of: store.notes.map(\.id)) { _, _ in
            currentIndex = 0
        }
    }

    private func toggleSpeak() {
        if isReadingNotes {
            // voice.cancel() 会触发当前 state.say 的 onFinish(false)，那里会把 isReadingNotes 设回 false
            voice.cancel()
            return
        }
        guard SettingsView.makeTTSProvider() != nil else {
            ttsAlert = "请先到 设置 → 语音 打开「说话时念出来」并填好 ElevenLabs key + Voice ID。"
            return
        }
        if currentIndex >= store.notes.count { currentIndex = 0 }
        isReadingNotes = true
        playNote(at: currentIndex)
    }

    /// 逐条念：走 state.say —— 桌宠头顶的气泡同步显示该便签文字 + 不切表情（沿用当前表情）。
    /// 自然播完才往下一条；被打断时 currentIndex 不动，下次按喇叭续读。
    private func playNote(at idx: Int) {
        guard idx < store.notes.count else {
            currentIndex = 0
            isReadingNotes = false
            return
        }
        let text = store.notes[idx].text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            playNote(at: idx + 1)
            return
        }
        currentIndex = idx
        state.say(text, mood: state.mood, autoHideAfter: 6) { natural in
            if !natural {
                isReadingNotes = false
                return
            }
            playNote(at: idx + 1)
        }
    }
}

private struct NoteRow: View {
    @Binding var text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.caption2)
                .foregroundStyle(.pink.opacity(0.55))
                .padding(.top, 9)

            TextField("写点鼓励的话…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.pink.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.pink.opacity(0.18), lineWidth: 0.5)
                )

            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.5))
                .padding(.top, 9)
                .help("拖动调整顺序")

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .padding(.top, 8)
            .help("删除")
        }
    }
}
