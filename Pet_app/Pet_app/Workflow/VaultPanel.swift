import AppKit
import Combine
import SwiftUI
import PetCore

// MARK: - 保险箱 (网站 / 账号 / 密码)

/// 一条「保险箱」记录：网站名 + 网址 + 账号 + 密码 + 备注。
/// 跟便签、todo 完全隔离，单独落盘到 vault.json。
struct VaultEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    var url: String = ""
    var account: String = ""
    var password: String = ""
    var note: String = ""

    enum CodingKeys: String, CodingKey { case id, title, url, account, password, note }

    init(id: UUID = UUID(), title: String = "", url: String = "",
         account: String = "", password: String = "", note: String = "") {
        self.id = id
        self.title = title
        self.url = url
        self.account = account
        self.password = password
        self.note = note
    }

    // 缺字段也别让整组解码失败 —— 每个字段单独 try?，缺了就用默认空串。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
        self.url = (try? c.decode(String.self, forKey: .url)) ?? ""
        self.account = (try? c.decode(String.self, forKey: .account)) ?? ""
        self.password = (try? c.decode(String.self, forKey: .password)) ?? ""
        self.note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

/// 保险箱的存储 —— 跟 NotesStore 一个套路：内存数组 + 落盘 JSON。
/// 注意：明文存盘，纯个人本机使用（跟 app 现有 API key 存法一致）。
@MainActor
final class VaultStore: ObservableObject {
    @Published var entries: [VaultEntry] = []
    private let file = AppPaths.vaultFile

    init() { reload() }

    func reload() {
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([VaultEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    func add() {
        // 新条目放最前面，刚加的最想先填。
        entries.insert(VaultEntry(), at: 0)
        persist()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// 通用字段更新 —— 拿到 entry id，闭包里改哪个字段都行。
    func update(_ id: UUID, _ mutate: (inout VaultEntry) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var copy = entries[idx]
        mutate(&copy)
        guard copy != entries[idx] else { return }
        entries[idx] = copy
        persist()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        entries.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    private func persist() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(entries)
            // 只让当前用户能读，别让别的账户翻到明文密码。
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path
            )
        } catch {
            // 安静失败 —— 下次保存还有机会
        }
    }
}

struct VaultPanel: View {
    @ObservedObject var store: VaultStore

    private var subtitle: String {
        store.entries.isEmpty ? "" : "\(store.entries.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    store.add()
                } label: {
                    Label("添加", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("加一条网站 / 账号 / 密码")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if store.entries.isEmpty {
                VStack(spacing: 4) {
                    Text("存网站 / 账号 / 密码的小抄")
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
                    ForEach(store.entries) { entry in
                        VaultRow(
                            entry: entry,
                            onChange: { mutate in store.update(entry.id, mutate) },
                            onDelete: { store.delete(entry.id) }
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
    }
}

private struct VaultRow: View {
    let entry: VaultEntry
    let onChange: (@escaping (inout VaultEntry) -> Void) -> Void
    let onDelete: () -> Void

    @State private var revealed = false
    @State private var copied = false
    @State private var expanded = false

    private func field(_ keyPath: WritableKeyPath<VaultEntry, String>) -> Binding<String> {
        Binding(
            get: { entry[keyPath: keyPath] },
            set: { newValue in onChange { $0[keyPath: keyPath] = newValue } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：标题 + 展开 / 打开网址 / 删除
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("网站 / 名称", text: field(\.title))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))

                if !entry.url.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        openURL(entry.url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("在浏览器打开")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(expanded ? "收起" : "展开网址 / 备注")
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.borderless)
                .help("删除")
            }

            // 账号
            HStack(spacing: 6) {
                Text("账号").font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                TextField("用户名 / 邮箱", text: field(\.account))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Button {
                    copy(entry.account)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("复制账号")
            }

            // 密码（默认遮罩，眼睛切换明文，一键复制）
            HStack(spacing: 6) {
                Text("密码").font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                Group {
                    if revealed {
                        TextField("••••••", text: field(\.password))
                    } else {
                        SecureField("••••••", text: field(\.password))
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help(revealed ? "隐藏" : "显示明文")
                Button {
                    copy(entry.password)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help("复制密码")
            }

            if expanded {
                HStack(spacing: 6) {
                    Text("网址").font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                    TextField("https://…", text: field(\.url))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                HStack(spacing: 6) {
                    Text("备注").font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                    TextField("可空", text: field(\.note), axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.indigo.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.indigo.opacity(0.16), lineWidth: 0.5)
        )
    }

    private func copy(_ s: String) {
        let trimmed = s
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }

    private func openURL(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        // 没写协议就补 https://
        if !s.contains("://") { s = "https://\(s)" }
        if let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }
}
