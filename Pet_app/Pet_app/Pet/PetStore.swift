import Combine
import Foundation
import PetCore

/// 多宠物档案管理：加载 pets.yaml、切换激活、增删改。
@MainActor
final class PetStore: ObservableObject {
    @Published private(set) var roster: PetRoster
    @Published var lastError: String?

    private let loader = PetRosterLoader()
    private let url: URL

    init(url: URL = AppPaths.petsFile) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                self.roster = try loader.load(from: url)
                self.lastError = nil
                return
            } catch {
                self.lastError = "读 pets.yaml 失败：\(error.localizedDescription)，已用默认档案"
            }
        }
        // 首次启动 / 文件读失败：建一个 doro 作为第一只宠物
        let doro = PetProfile(
            id: "doro",
            name: "Doro",
            assetPrefix: "doro",
            persona: Persona(
                name: "Doro",
                systemPrompt: """
                你是 Doro，一只可爱的桌面宠物。主人是一位 ML 研究员，最近压力大、记性差。
                - 用中文回复，语气温柔、轻松，偶尔卖萌
                - 主人厌学时给她支持，不说教
                - 主人想偷懒时温柔但坚定地推她回到正事
                - 回复简短，1-3 句话，必要时一次只问一个问题
                """
            )
        )
        self.roster = PetRoster(active: doro.id, pets: [doro])
        try? persistSilently()
    }

    var active: PetProfile {
        roster.activeProfile ?? PetProfile(
            id: "default",
            name: "小宠",
            assetPrefix: "pet",
            persona: .default
        )
    }

    func setActive(id: String) {
        guard roster.pets.contains(where: { $0.id == id }) else { return }
        roster.active = id
        persist()
    }

    @discardableResult
    func addNew(name: String) -> PetProfile {
        let baseSlug = PetProfile.slugify(name.isEmpty ? "pet" : name)
        let id = uniqueID(starting: baseSlug)
        let profile = PetProfile(
            id: id,
            name: name.isEmpty ? id : name,
            assetPrefix: id,
            persona: .default
        )
        roster.pets.append(profile)
        roster.active = id
        persist()
        return profile
    }

    func delete(id: String) {
        guard roster.pets.count > 1 else {
            lastError = "至少要留一只宠物"
            return
        }
        roster.pets.removeAll { $0.id == id }
        if roster.active == id {
            roster.active = roster.pets.first?.id ?? ""
        }
        persist()
    }

    /// 改当前激活宠物的某些字段
    func updateActive(_ transform: (inout PetProfile) -> Void) {
        guard let idx = roster.pets.firstIndex(where: { $0.id == roster.active }) else { return }
        transform(&roster.pets[idx])
        persist()
    }

    private func uniqueID(starting base: String) -> String {
        var candidate = base
        var n = 2
        let existing = Set(roster.pets.map(\.id))
        while existing.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    private func persist() {
        do {
            try persistSilently()
            lastError = nil
        } catch {
            lastError = "写 pets.yaml 失败：\(error.localizedDescription)"
        }
    }

    private func persistSilently() throws {
        try loader.save(roster, to: url)
    }
}
