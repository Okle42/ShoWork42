import Foundation
import Testing
@testable import ShoWorkCore

@Suite("LocalConfig")
struct LocalConfigTests {
    @Test("沒有 local.json＝通用預設：稱呼「使用者」、沒有個人規則；壞檔也當沒有")
    func defaults() throws {
        let none = LocalConfig.load(from: URL(fileURLWithPath: "/nonexistent/local.json"))
        #expect(none == LocalConfig() && none.ownerName == "使用者")
        #expect(!none.isPrivateDataRepo("A") && !none.skipsKickoff(cwd: "/x/A"))
        #expect(CaptainLink.rules(none).allSatisfy { !$0.name.hasPrefix("遠端 Windows") })
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("local-bad-\(UUID().uuidString).json")
        try Data("壞掉".utf8).write(to: bad); defer { try? FileManager.default.removeItem(at: bad) }
        #expect(LocalConfig.load(from: bad) == LocalConfig())
    }

    @Test("有設定：私人 repo 不分大小寫、cwd 任一段相符才不提醒開工卡、每台遠端主機一條預告規則")
    func configured() {
        let c = LocalConfig(owner: "小明", privateDataRepos: ["Secret42"], noKickoffRepos: ["Secret42"])
        #expect(c.ownerName == "小明" && c.isPrivateDataRepo("secret42") && !c.isPrivateDataRepo("Secret"))
        #expect(c.skipsKickoff(cwd: "/Users/k/repos/Secret42/app") && !c.skipsKickoff(cwd: "/Users/k/repos/Secret42x"))
        let win = CaptainLink.rules(LocalConfig(winHosts: ["a.b", "c"])).filter { $0.name.hasPrefix("遠端 Windows") }
        #expect(win.map(\.name) == ["遠端 Windows 寫入（ssh a.b）", "遠端 Windows 寫入（ssh c）"])
        #expect(CaptainLink.match("ssh axb 'Set-Item x'", rules: win).isEmpty)          // 主機名的 . 不當萬用字元
        #expect(CaptainLink.match("ssh a.b 'Set-Item x'", rules: win).count == 1)
    }
}
