import Foundation
import Testing
@testable import ShoWorkCore

@Suite("PushGuard")
struct PushGuardTests {
    @Test("從 Bash 指令找出 git push：cd、-C、&&、引號；不是 push 的不算")
    func calls() {
        #expect(PushGuard.calls(command: "git status", cwd: "/w").isEmpty)
        #expect(PushGuard.calls(command: "echo 'git push'", cwd: "/w").isEmpty)
        let a = PushGuard.calls(command: "cd /r/ShoWork42 && git log --oneline -1 && git push origin main 2>&1 | tail -1", cwd: "/w")
        #expect(a == [PushCall(dir: "/r/ShoWork42", args: ["origin", "main"])])
        let b = PushGuard.calls(command: "git -C ../x push -f; FOO=1 git push --all", cwd: "/w/y")
        #expect(b.map(\.dir) == ["/w/x", "/w/y"] && b[0].args == ["-f"] && b[1].args == ["--all"])
        let v = PushGuard.calls(command: "S=/tmp/pg; cd $S/w && git push; cd ${S}/x && git push", cwd: "/w")
        #expect(v.map(\.dir) == ["/tmp/pg/w", "/tmp/pg/x"])
        #expect(PushGuard.calls(command: "cd $NOPE_UNSET_VAR/w && git push", cwd: "/w").first?.dir.contains("$") == true)
        #expect(PushGuard.repoName("git@github.com:Okle42/ghosts.git") == "Okle42/ghosts")
        #expect(PushGuard.repoName("https://github.com/Okle42/ShoWork42.git") == "Okle42/ShoWork42")
    }

    /// 真的 git：一個 bare 遠端＋一個 clone
    final class Repo {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)").path
        var work: String { root + "/w" }
        let git: PushGuard.Git = { dir, a in
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + a
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try? p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: d, as: UTF8.self))
        }
        init(name: String) {
            let remote = root + "/Okle42/\(name).git"
            try? FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            _ = git(remote, ["init", "-q", "--bare", "-b", "main"])
            _ = git(work, ["init", "-q", "-b", "main"])
            _ = git(work, ["remote", "add", "origin", remote])
            commit("README.md", "hi\n")
            _ = git(work, ["push", "-q", "-u", "origin", "main"])
        }
        func commit(_ path: String, _ text: String) {
            let u = URL(fileURLWithPath: work + "/" + path)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
            _ = git(work, ["add", "-A"]); _ = git(work, ["commit", "-q", "-m", "c"])
        }
        func check(_ args: [String], keywords: [String] = [], strict: [String] = []) -> PushEvent {
            PushGuard.check(PushCall(dir: work, args: args), git: git, keywords: keywords, strict: strict)
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }
    }

    @Test("一般 push 放行，算得出要推幾個 commit")
    func ok() {
        let r = Repo(name: "ProjectA")
        r.commit("a.swift", "let x = 1\n"); r.commit("b.swift", "let y = 2\n")
        let e = r.check([])
        #expect(e.verdict == .ok && e.commits == 2 && e.repo.hasSuffix("Okle42/ProjectA") && e.refs == ["main"])
        #expect(PushGuard.hookOutput([e]) == nil)
    }

    @Test("擋：ghosts、old-history、force／刪除 main")
    func blocks() {
        let g = Repo(name: "ghosts")
        g.commit("a.txt", "x\n")
        #expect(g.check(["origin", "main"]).verdict == .block)
        let r = Repo(name: "cool42")
        #expect(r.check(["origin", "old-history/main"]).verdict == .block)
        #expect(PushGuard.check(PushCall(dir: "/w/$X", args: []), git: r.git, keywords: [], strict: []).verdict == .block)
        #expect(PushGuard.check(PushCall(dir: r.root, args: []), git: r.git, keywords: [], strict: []).verdict == .block)   // 不是 git 資料夾
        #expect(r.check(["-f"]).verdict == .block)
        #expect(r.check(["origin", "+main"]).verdict == .block)
        #expect(r.check(["--force", "origin", "feature"]).verdict == .ok)          // force 推自己的分支可以
        #expect(r.check(["origin", ":main"]).verdict == .block)
        #expect(r.check(["--delete", "origin", "main"]).verdict == .block)
        let out = PushGuard.hookOutput([r.check(["-f"])]) ?? ""
        #expect(out.contains(#""permissionDecision":"deny""#) && out.contains("! git push"))
    }

    @Test("擋：金鑰、ProjectC 的 data/、財務檔")
    func content() {
        let r = Repo(name: "ProjectA")
        r.commit("cfg.swift", "let key = \"" + "sk-" + "ant-api03-" + String(repeating: "A", count: 40) + "\"\n")
        let e = r.check([])
        #expect(e.verdict == .block && e.secret && e.reasons.joined().contains("cfg.swift：Anthropic 金鑰"))
        let m = Repo(name: "ProjectC")
        m.commit("data/family.json", "{}\n")
        #expect(m.check([]).verdict == .block)
        let f = Repo(name: "MoneyBot42")
        f.commit("x/finance_2026.json", "{}\n")
        #expect(f.check([]).verdict == .block)
    }

    @Test("關鍵字：一般 repo 只提醒，公開／公司 repo 擋")
    func keywords() {
        let r = Repo(name: "cool42")
        r.commit("README.md", "這是機密詞客戶的案子\n")
        let w = r.check([], keywords: ["機密詞"])
        #expect(w.verdict == .warn && (PushGuard.hookOutput([w]) ?? "").contains("additionalContext"))
        #expect(r.check([], keywords: ["機密詞"], strict: ["cool42"]).verdict == .block)
        #expect(r.check([], keywords: ["別的詞"]).verdict == .ok)
    }

    @Test("紀錄：一行一筆、讀得回來、新的在前")
    func log() {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: u) }
        let t0 = Date(timeIntervalSince1970: 1_792_600_000)
        PushGuard.append(PushEvent(at: t0, repo: "a/b", dir: "/x", refs: ["main"], commits: 1, verdict: .ok, reasons: []), to: u)
        PushGuard.append(PushEvent(at: t0.addingTimeInterval(60), repo: "a/c", dir: "/y", refs: ["main"], commits: 0, verdict: .block, reasons: ["r"]), to: u)
        let xs = PushGuard.recent(try? Data(contentsOf: u), since: t0)
        #expect(xs.map(\.repo) == ["a/c", "a/b"])
        #expect(PushGuard.recent(try? Data(contentsOf: u), since: t0.addingTimeInterval(30)).count == 1)
    }

    @Test("放行一次：同資料夾同 HEAD 才算、用掉就沒了、過期不算")
    func allowOnce() {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: u) }
        let t0 = Date(timeIntervalSince1970: 1_792_600_000)
        var e = PushEvent(at: t0, repo: "a/b", dir: "/x", refs: ["main"], commits: 1, verdict: .block, reasons: ["r"]); e.head = "h1"
        PushGuard.allow(e, now: t0, url: u)
        var other = e; other.head = "h2"
        #expect(PushGuard.apply(&other, allows: PushGuard.allows(u), now: t0 + 60).count == 1 && other.verdict == .block)
        var late = e
        #expect(PushGuard.apply(&late, allows: PushGuard.allows(u), now: t0 + PushGuard.allowFor + 1).isEmpty && late.verdict == .block)
        let rest = PushGuard.apply(&e, allows: PushGuard.allows(u), now: t0 + 60)
        #expect(e.verdict == .ok && rest.isEmpty && e.reasons[0].hasPrefix("Kang 在保全面板放行一次"))
        let out = PushGuard.hookOutput([PushEvent(at: t0, repo: "a/b", dir: "/x", refs: [], commits: 0, verdict: .block, reasons: ["r"])]) ?? ""
        #expect(out.contains("不要重試") && out.contains("找 Kang 核可") && out.contains("放行一次"))
    }
}
