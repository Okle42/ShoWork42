import Foundation

// 動作預告「GitHub 公開發言（gh）」的細判（隊長 Penny 10-24：Sam 在公開 repo 用 gh issue comment／gh pr create，開工卡回覆前就送出去了）。
// preview.tsv 的正規表示式先粗篩（gh issue comment／create、gh pr create／comment／review、gh release create、gh api 寫入），
// 命中後這裡逐段看真正的目標 repo：全部都是 Okle42 自己的私有 repo ⇒ 不擋；其他帳號、公開、判不出來（gh 失敗、路徑用變數）⇒ 照擋等放行。
// gh api 只算 repos/… 路徑，而且是寫入（-X POST／PATCH／PUT／DELETE，或帶 -f／-F／--input 這類會預設成 POST 的欄位）。

public enum GHGuard {
    public static let ruleName = "GitHub 公開發言（gh）"
    /// 自己的帳號：私有 repo 不擋
    public static let ownOwners: Set<String> = ["okle42"]

    /// 一段 gh 指令的目標
    public enum Target: Equatable, Sendable {
        case none                 // 不是對外發言（讀取、gh api 非 repos/ 路徑⋯）
        case repos([String])      // owner/name（沒指定 -R 時是資料夾所有 remote 的 repo，每一個都要過）
        case unknown(String)      // 判不出來：原因
    }

    public typealias View = (_ repo: String) -> (owner: String, isPrivate: Bool)?

    /// 這段（已拆好的參數，第一個是 gh）是要對哪個 repo 發言
    public static func target(_ tok: [String], dir: String, git: PushGuard.Git) -> Target {
        guard let g = tok.first, g == "gh" || g.hasSuffix("/gh"), tok.count >= 2 else { return .none }
        var a = Array(tok.dropFirst())
        // -R／--repo 可以出現在任何位置
        var repo: String?
        var i = 0
        while i < a.count {
            let x = a[i]
            if (x == "-R" || x == "--repo"), i + 1 < a.count { repo = a[i + 1]; a.removeSubrange(i...(i + 1)); continue }
            if x.hasPrefix("--repo=") { repo = String(x.dropFirst(7)); a.remove(at: i); continue }
            if x.hasPrefix("-R"), x.count > 2 { repo = String(x.dropFirst(2)); a.remove(at: i); continue }
            i += 1
        }
        let sub = a.first ?? "", verb = a.count > 1 ? a[1] : ""
        let outward: Set<String> = ["issue comment", "issue create", "pr create", "pr comment", "pr review", "release create"]
        if sub == "api" {
            return apiTarget(Array(a.dropFirst()), dir: dir, git: git)
        }
        guard outward.contains(sub + " " + verb) else { return .none }
        if let repo { return .repos([PushGuard.repoName(repo)]) }
        // 參數是網址（gh issue comment https://github.com/o/n/issues/5）
        for x in a.dropFirst(2) {
            if let r = urlRepo(x) { return .repos([r]) }
        }
        return dirRepos(dir, git: git)
    }

    static func apiTarget(_ a: [String], dir: String, git: PushGuard.Git) -> Target {
        var method: String?, fields = false, path: String?
        var i = 0
        while i < a.count {
            let x = a[i]
            if x == "-X" || x == "--method" { method = i + 1 < a.count ? a[i + 1].uppercased() : nil; i += 2; continue }
            if x.hasPrefix("--method=") { method = String(x.dropFirst(9)).uppercased() }
            else if x.hasPrefix("-X"), x.count > 2 { method = String(x.dropFirst(2)).uppercased() }
            else if ["-f", "-F", "--field", "--raw-field", "--input"].contains(x) { fields = true; i += 2; continue }
            else if x.hasPrefix("--field=") || x.hasPrefix("--raw-field=") || x.hasPrefix("--input=") { fields = true }
            else if ["-H", "--header", "-q", "--jq", "-t", "--template", "--hostname", "--cache", "-p", "--preview"].contains(x) { i += 2; continue }
            else if !x.hasPrefix("-"), path == nil { path = x }
            i += 1
        }
        let m = method ?? (fields ? "POST" : "GET")
        guard ["POST", "PATCH", "PUT", "DELETE"].contains(m), let p = path else { return .none }
        let parts = p.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
        guard parts.first == "repos" else { return .none }
        guard parts.count >= 3 else { return .unknown("gh api 路徑看不出 repo（\(p)）") }
        if parts[1] == "{owner}" || parts[2] == "{repo}" { return dirRepos(dir, git: git) }
        if parts[1].contains("$") || parts[2].contains("$") { return .unknown("gh api 路徑用了變數（\(p)）") }
        return .repos([parts[1] + "/" + parts[2]])
    }

    static func urlRepo(_ s: String) -> String? {
        guard let r = s.range(of: "github.com/") else { return nil }
        let p = s[r.upperBound...].split(separator: "/").map(String.init)
        return p.count >= 2 ? p[0] + "/" + p[1] : nil
    }

    /// 沒指定 repo：gh 用資料夾的 remote（fork 的 PR 會開到上游）⇒ 每個 remote 都算
    static func dirRepos(_ dir: String, git: PushGuard.Git) -> Target {
        if dir.contains("$") || dir.contains("`") { return .unknown("資料夾用了變數（\(dir)）") }
        let r = git(dir, ["remote", "-v"])
        let urls = r.out.split(separator: "\n").compactMap { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first.map(String.init) }
        var out: [String] = []
        for u in urls { let n = PushGuard.repoName(u); if !out.contains(n) { out.append(n) } }
        return r.code == 0 && !out.isEmpty ? .repos(out) : .unknown("\(dir) 不是有 remote 的 git 資料夾")
    }

    /// 命中「GitHub 公開發言」的指令能不能免擋：每一段 gh 發言的目標都是 Okle42 的私有 repo 才免。
    /// 回傳 nil＝免擋；否則是擋的原因（給預告摘要用）
    public static func blockReason(_ cmd: String, cwd: String, rule: CaptainLink.Rule, git: PushGuard.Git, view: View) -> String? {
        guard let re = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { return "規則讀不懂" }
        var dir = cwd, reasons: [String] = [], checked = [String: Bool]()
        for s in CaptainLink.segmentPairs(cmd) {
            let tok = PushGuard.tokenize(s.raw)
            if tok.first == "cd" {
                if tok.count >= 2 {
                    let e = (tok[1] as NSString).expandingTildeInPath
                    dir = e.hasPrefix("/") ? (e as NSString).standardizingPath : ((dir as NSString).appendingPathComponent(e) as NSString).standardizingPath
                } else { dir = NSHomeDirectory() }
                continue
            }
            guard re.firstMatch(in: s.norm, range: NSRange(s.norm.startIndex..., in: s.norm)) != nil else { continue }
            switch target(tok, dir: dir, git: git) {
            case .none:
                // 正規表示式抓到、這裡卻看不出是 gh 發言（包在別的指令裡）⇒ 不冒險
                if !(tok.first == "gh" || tok.first?.hasSuffix("/gh") == true) { reasons.append("看不出 gh 指令的目標") }
            case .unknown(let why): reasons.append(why)
            case .repos(let rs):
                for r in rs {
                    let ok: Bool
                    if let c = checked[r] { ok = c }
                    else if !ownOwners.contains(r.split(separator: "/").first.map { $0.lowercased() } ?? "") { ok = false }
                    else if let v = view(r) { ok = ownOwners.contains(v.owner.lowercased()) && v.isPrivate }
                    else { ok = false; reasons.append("查不到 \(r) 是不是私有") }
                    checked[r] = ok
                    if !ok, !reasons.contains(where: { $0.contains(r) }) { reasons.append("\(r) 不是 Okle42 的私有 repo") }
                }
            }
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "；")
    }
}
