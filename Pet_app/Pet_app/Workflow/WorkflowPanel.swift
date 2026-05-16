import AppKit
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

    /// 当前 doneIDs 对应的日期 key。跨过 00:00 后跟 doneKey 不一致就触发归零。
    private var loadedDoneKey: String = ""
    private var midnightTimer: Timer?

    init() {
        reload()
        scheduleMidnightRollover()
        // 电脑睡过整夜 timer 不一定准点触发；前台激活时再补一次检查。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillBecomeActive),
            name: NSApplication.willBecomeActiveNotification,
            object: nil
        )
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

        let key = doneKey
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        self.doneIDs = Set(stored)
        self.loadedDoneKey = key
    }

    func toggle(_ stepID: String) {
        // 先确认当前 doneIDs 还是今天的 —— 防止跨午夜后写入了错的内存集合。
        rolloverIfNeeded()
        if doneIDs.contains(stepID) { doneIDs.remove(stepID) }
        else { doneIDs.insert(stepID) }
        UserDefaults.standard.set(Array(doneIDs), forKey: doneKey)
    }

    // MARK: - 每日零点归零

    @objc private func handleWillBecomeActive() {
        rolloverIfNeeded()
    }

    /// 如果今天的 key 跟 loadedDoneKey 不一样了，就把 doneIDs 切到今天那份
    /// （新一天通常是空集，于是所有任务都重新可勾选）。
    private func rolloverIfNeeded() {
        let today = doneKey
        guard loadedDoneKey != today else { return }
        let stored = UserDefaults.standard.stringArray(forKey: today) ?? []
        doneIDs = Set(stored)
        loadedDoneKey = today
        // 既然刚刚触发了一次，重排下一次以保证之后每天都准点。
        scheduleMidnightRollover()
    }

    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        let cal = Calendar.current
        guard let nextMidnight = cal.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return }
        // 比零点多 1 秒，避开调度抖动导致 fire 时 doneKey 还停在昨天。
        let fireDate = nextMidnight.addingTimeInterval(1)
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.rolloverIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
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
    /// 编辑器单独开一个浮动 NSWindow（而不是 .sheet）—— 这样可以拖到旁边，
    /// 不挡住后面的工作流面板。生命周期跟随 WorkflowPanel。
    @StateObject private var editorWindow = StepEditorWindow()

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
                        onEdit: { editorWindow.show(mode: .edit(original: step), store: store) },
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
                editorWindow.show(mode: .create, store: store)
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
                editorWindow.show(mode: .create, store: store)
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
            // 双击文字区域 → 打开编辑器；按钮自己会拦截单击，不冲突
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onEdit() }

            Spacer()

            Button(runLabel) { onRun() }
                .controlSize(.small)

            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.5))
                .frame(maxHeight: .infinity, alignment: .center)
                .help("拖动调整顺序")

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .frame(maxHeight: .infinity, alignment: .center)
            .help("删除（双击行可编辑）")
        }
        .padding(.vertical, 4)
    }

    /// "启动" / "念一下" / "启动 ×3" — 取决于这个步骤挂了几个动作
    private var runLabel: String {
        let count = step.resolvedActions.count
        if count == 0 { return "念一下" }
        if count == 1 { return "启动" }
        return "启动 ×\(count)"
    }

    private var stepDetail: String? {
        let actions = step.resolvedActions
        if actions.isEmpty { return "提醒" }
        if actions.count == 1 {
            return summarize(actions[0])
        }
        let first = summarize(actions[0]) ?? "…"
        return "\(actions.count) 个动作：\(first) …"
    }

    private func summarize(_ a: StepAction) -> String? {
        switch a.kind {
        case .app:
            if let app = a.openApp, let path = a.openPath {
                return "\(app) → \(path)"
            }
            return a.openApp.map { "app: \($0)" }
        case .url: return a.openURL.map { "url: \($0)" }
        case .path: return a.openPath.map { "path: \($0)" }
        case .prompt: return "提醒"
        }
    }
}

// MARK: - Step Editor sheet

private enum EditorMode {
    case create
    case edit(original: WorkflowStep)
}

/// 编辑器里临时持有的动作（带 UI 用的 id 与一个可选的"app 打开路径"分栏）。
/// app 类型时 `target` = bundle ID、`appOpenPath` = 可选的传给 app 的路径；
/// path 类型 `target` = 路径本身；url 类型 `target` = URL。
private struct EditableAction: Identifiable, Hashable {
    let id: UUID
    var kind: StepKind
    var target: String
    var appOpenPath: String

    init(kind: StepKind = .app, target: String = "", appOpenPath: String = "") {
        self.id = UUID()
        self.kind = kind
        self.target = target
        self.appOpenPath = appOpenPath
    }
}

/// 常用 app 的 bundle ID 预设
private let appPresets: [(label: String, bundleID: String)] = [
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

/// 常用 URL 预设 —— 给 .url 类型动作的快速填充菜单
private let urlPresets: [(label: String, url: String)] = [
    ("ChatGPT", "https://chatgpt.com"),
    ("Claude", "https://claude.ai"),
    ("Gemini", "https://gemini.google.com"),
    ("LobeChat", "https://chat.lobehub.com"),
    ("Google", "https://www.google.com"),
    ("Google Scholar", "https://scholar.google.com"),
    ("YouTube", "https://www.youtube.com"),
    ("GitHub", "https://github.com"),
    ("Bilibili", "https://www.bilibili.com"),
    ("X / Twitter", "https://x.com"),
    ("知乎", "https://www.zhihu.com"),
    ("arXiv", "https://arxiv.org"),
    ("Notion", "https://www.notion.so"),
]

/// 把"新建 / 编辑步骤"做成可拖动的独立 NSWindow，而不是模态 .sheet。
/// 这样用户可以把编辑器拖到旁边，一边对照工作流列表一边改。
/// 同一时刻只保留一个编辑窗口 —— 再次调用 show() 会把旧窗口关掉换内容。
@MainActor
final class StepEditorWindow: ObservableObject {
    private var window: NSWindow?

    fileprivate func show(mode: EditorMode, store: WorkflowStore) {
        close()

        let title: String
        switch mode {
        case .create: title = "新建步骤"
        case .edit:   title = "编辑步骤"
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // 弱引用 self，避免 onClose 把 window 抓住后两边互持
        let view = StepEditor(
            mode: mode,
            store: store,
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        win.title = title
        win.contentMinSize = NSSize(width: 460, height: 480)
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    fileprivate func close() {
        window?.close()
        window = nil
    }
}

private struct StepEditor: View {
    let mode: EditorMode
    @ObservedObject var store: WorkflowStore
    let onClose: () -> Void

    @State private var stepID: String = ""
    @State private var say: String = ""
    @State private var actions: [EditableAction] = []
    @State private var thenPrompt: String = ""
    @State private var error: String?

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

                Section {
                    if actions.isEmpty {
                        Text("没有动作 —— 这个步骤会作为纯提醒（点「念一下」时只念话）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($actions) { $action in
                            ActionEditorRow(
                                action: $action,
                                onDelete: {
                                    actions.removeAll { $0.id == action.id }
                                }
                            )
                        }
                    }
                    Button {
                        actions.append(EditableAction(kind: .app))
                    } label: {
                        Label("添加一个动作", systemImage: "plus.circle")
                    }
                    .controlSize(.small)
                } header: {
                    HStack {
                        Text("动作")
                        Spacer()
                        if !actions.isEmpty {
                            Text("点「启动」时会一起触发 \(actions.count) 个")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 600)
        .onAppear { loadInitial() }
    }

    private func loadInitial() {
        if case .edit(let s) = mode {
            stepID = s.id
            say = s.say ?? ""
            thenPrompt = s.thenPrompt ?? ""
            // 已有的步骤：通过 resolvedActions 统一拿到动作数组（兼容老 yaml 的单字段）
            actions = s.resolvedActions.map { a in
                EditableAction(
                    kind: a.kind,
                    target: target(for: a),
                    appOpenPath: a.kind == .app ? (a.openPath ?? "") : ""
                )
            }
        } else {
            stepID = "step-\(Int(Date().timeIntervalSince1970))"
            actions = []
        }
    }

    private func target(for a: StepAction) -> String {
        switch a.kind {
        case .app: return a.openApp ?? ""
        case .url: return a.openURL ?? ""
        case .path: return a.openPath ?? ""
        case .prompt: return ""
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

        // 校验每个动作；路径字段只去换行不去空格
        var cleaned: [(kind: StepKind, target: String, appOpenPath: String)] = []
        for (idx, a) in actions.enumerated() {
            let pathOnlyTarget = a.target.trimmingCharacters(in: .newlines)
            let trimmedTarget = a.target.trimmingCharacters(in: .whitespaces)
            let hasTarget = (a.kind == .path) ? !pathOnlyTarget.isEmpty : !trimmedTarget.isEmpty
            if !hasTarget {
                error = "第 \(idx + 1) 个动作的目标没填"
                return
            }
            let t: String = (a.kind == .path) ? pathOnlyTarget : trimmedTarget
            let appPath = a.appOpenPath.trimmingCharacters(in: .newlines)
            cleaned.append((a.kind, t, appPath))
        }

        let trimmedSay = say.trimmingCharacters(in: .whitespaces)
        let trimmedThen = thenPrompt.trimmingCharacters(in: .whitespaces)
        let saySafe: String? = trimmedSay.isEmpty ? nil : trimmedSay
        let thenSafe: String? = trimmedThen.isEmpty ? nil : trimmedThen

        let step: WorkflowStep
        switch cleaned.count {
        case 0:
            // 纯提醒
            step = WorkflowStep(
                id: trimmedID,
                say: saySafe,
                kind: .prompt,
                thenPrompt: thenSafe
            )
        case 1:
            // 单动作 —— 写到老字段保持 yaml 简洁、向后可读
            let c = cleaned[0]
            let openPathField: String? = {
                switch c.kind {
                case .app: return c.appOpenPath.isEmpty ? nil : c.appOpenPath
                case .path: return c.target
                default: return nil
                }
            }()
            step = WorkflowStep(
                id: trimmedID,
                say: saySafe,
                openApp: c.kind == .app ? c.target : nil,
                openURL: c.kind == .url ? c.target : nil,
                openPath: openPathField,
                kind: nil,
                thenPrompt: thenSafe
            )
        default:
            // 多动作 —— 写到 actions 数组，老字段全部留空
            let list: [StepAction] = cleaned.map { c in
                StepAction(
                    kind: c.kind,
                    openApp: c.kind == .app ? c.target : nil,
                    openURL: c.kind == .url ? c.target : nil,
                    openPath: c.kind == .app
                        ? (c.appOpenPath.isEmpty ? nil : c.appOpenPath)
                        : (c.kind == .path ? c.target : nil)
                )
            }
            step = WorkflowStep(
                id: trimmedID,
                say: saySafe,
                kind: nil,
                thenPrompt: thenSafe,
                actions: list
            )
        }

        if isEditing {
            store.updateStep(step)
        } else {
            store.addStep(step)
        }
        onClose()
    }
}

private struct ActionEditorRow: View {
    @Binding var action: EditableAction
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $action.kind) {
                    Text("打开 App").tag(StepKind.app)
                    Text("打开 URL").tag(StepKind.url)
                    Text("打开路径").tag(StepKind.path)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("删除这个动作")
            }

            switch action.kind {
            case .app:
                HStack {
                    TextField("Bundle ID，如 com.apple.Safari", text: $action.target)
                        .textFieldStyle(.roundedBorder)
                    Menu("常用") {
                        ForEach(appPresets, id: \.bundleID) { p in
                            Button("\(p.label) — \(p.bundleID)") { action.target = p.bundleID }
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 70)
                }
                HStack {
                    TextField("可选：让该 app 打开这个路径", text: $action.appOpenPath)
                        .textFieldStyle(.roundedBorder)
                    Button("选…") { pickAppOpenPath() }
                        .controlSize(.small)
                }
            case .url:
                HStack {
                    TextField("https://… 或 notion://…", text: $action.target)
                        .textFieldStyle(.roundedBorder)
                    Menu("常用") {
                        ForEach(urlPresets, id: \.url) { p in
                            Button("\(p.label) — \(p.url)") { action.target = p.url }
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 70)
                }
            case .path:
                HStack {
                    TextField("/Users/.../folder", text: $action.target)
                        .textFieldStyle(.roundedBorder)
                    Button("选…") { pickPath() }
                        .controlSize(.small)
                }
            case .prompt:
                // 多动作场景里不会出现 prompt 类型 —— 它由"没有动作"表达
                EmptyView()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.08))
        )
    }

    private func pickPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            action.target = url.path
        }
    }

    private func pickAppOpenPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            action.appOpenPath = url.path
        }
    }
}

// MARK: - 爱心便签 (Encouragement notes)

struct WorkflowNote: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String = ""
    var icon: String = NoteIcon.default

    enum CodingKeys: String, CodingKey { case id, text, icon }

    init(id: UUID = UUID(), text: String = "", icon: String = NoteIcon.default) {
        self.id = id
        self.text = text
        self.icon = icon
    }

    // 老数据没有 icon 字段 —— 缺省给个 ❤️，不要让一次解码失败把整组便签都清空。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.text = try c.decode(String.self, forKey: .text)
        self.icon = (try? c.decode(String.self, forKey: .icon)) ?? NoteIcon.default
    }
}

/// 便签前面的小图案 —— 暖心 / 效率建议 / 灵感 等。用 emoji 而不是 SF Symbol，
/// 颜色和语义一眼能分清，列表里也不至于全是粉色心。
enum NoteIcon {
    static let `default` = "❤️"
    static let options: [(emoji: String, label: String)] = [
        ("❤️", "暖心"),
        ("💡", "效率建议"),
        ("⭐", "重要"),
        ("✨", "灵感"),
        ("☀️", "鼓励"),
        ("🌸", "放松"),
        ("🔥", "紧急"),
        ("📌", "待办"),
    ]
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
            // 第一次打开（没文件）：塞几条默认的爱心便签；用户随时可改可删。
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
        // 新便签放最前面 —— 刚写下的念头通常最想被看见 / 优先念出来。
        notes.insert(WorkflowNote(text: ""), at: 0)
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

    func updateIcon(_ id: UUID, _ icon: String) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[idx].icon != icon else { return }
        notes[idx].icon = icon
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
                Text("爱心便签")
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
                            icon: note.icon,
                            onIconChange: { store.updateIcon(note.id, $0) },
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
    let icon: String
    let onIconChange: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Menu {
                ForEach(NoteIcon.options, id: \.emoji) { opt in
                    Button {
                        onIconChange(opt.emoji)
                    } label: {
                        Text("\(opt.emoji)  \(opt.label)")
                    }
                }
            } label: {
                Text(icon)
                    .font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, 6)
            .help("换个图案")

            Group {
                if isEditing {
                    TextField("写点鼓励的话…", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onAppear { focused = true }
                        .onChange(of: focused) { _, isFocused in
                            // 失焦即提交：点其他地方就退出编辑态，
                            // 不靠 onSubmit —— axis: .vertical 下回车是插换行不是提交。
                            if !isFocused { isEditing = false }
                        }
                } else {
                    Text(text.isEmpty ? "写点鼓励的话…（双击编辑）" : text)
                        .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { isEditing = true }
                }
            }
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
