import Foundation

// 本機私人設定（10-27 Kang 改成直接在公開 repo 開發，T 無單號）：
// 跟這台電腦、這個人有關的名字（私人 repo、遠端主機、使用者稱呼）不寫進原始碼，改放
// ~/Library/Application Support/ShoWork42/local.json（不進 git）。沒有這個檔＝通用預設，功能照常、只是沒有個人規則。
// 測試或另一台機器用 SHOWORK_LOCAL_CONFIG 換路徑。每次讀檔（檔很小；改了不用重開看板）。
//
// {
//   "owner": "Kang",                          // 提示詞裡怎麼稱呼使用者（預設「使用者」）
//   "headsetProjects": ["Secretary42"],       // 回訊息類專案：小人戴耳機
//   "privateDataRepos": ["Secretary42"],      // 這些 repo 的 data/ 是私人內容，push 一律擋
//   "winHosts": ["winbox"],                   // ssh 到這些遠端 Windows 的寫入動作要預告
//   "noKickoffRepos": ["Secretary42"]         // 在這些 repo 裡的 session 不提醒發開工卡
// }
public struct LocalConfig: Codable, Sendable, Equatable {
    public var owner: String?
    public var headsetProjects: [String]?
    public var privateDataRepos: [String]?
    public var winHosts: [String]?
    public var noKickoffRepos: [String]?

    public init(owner: String? = nil, headsetProjects: [String]? = nil, privateDataRepos: [String]? = nil,
                winHosts: [String]? = nil, noKickoffRepos: [String]? = nil) {
        self.owner = owner; self.headsetProjects = headsetProjects; self.privateDataRepos = privateDataRepos
        self.winHosts = winHosts; self.noKickoffRepos = noKickoffRepos
    }

    public static var file: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_LOCAL_CONFIG"] { return URL(fileURLWithPath: p) }
        return Paths.supportDir.appendingPathComponent("local.json")
    }

    public static func load(from url: URL = file) -> LocalConfig {
        guard let d = FileManager.default.contents(atPath: url.path) else { return LocalConfig() }
        return (try? JSONDecoder().decode(LocalConfig.self, from: d)) ?? LocalConfig()
    }

    public static var current: LocalConfig { load() }

    /// 提示詞裡的使用者稱呼
    public var ownerName: String { owner.flatMap { $0.isEmpty ? nil : $0 } ?? "使用者" }

    /// 名字是否在清單裡（不分大小寫）
    static func has(_ list: [String]?, _ name: String) -> Bool {
        (list ?? []).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
    public func isPrivateDataRepo(_ name: String) -> Bool { Self.has(privateDataRepos, name) }

    /// cwd 在不提醒開工卡的 repo 裡（路徑任一段等於清單裡的名字）
    public func skipsKickoff(cwd: String) -> Bool {
        cwd.split(separator: "/").contains { Self.has(noKickoffRepos, String($0)) }
    }
}
