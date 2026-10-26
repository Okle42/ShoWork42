import Foundation

// 1 樓保全：push 守門（10-22 Kang：「以後保全要幫忙看一下」）。
// 10-22 起隊長叫 push 就直接推、不再等 Kang 本人按，保全就是最後一道關。PreToolUse hook（`showork guard-push`）
// 在 AI 跑 `git push` 之前檢查要推出去的東西；擋下就回 deny，AI 看得到原因。每次檢查都記在 board/guard/pushes.jsonl，
// 前台・保全面板看得到「今天檢查幾次、擋下幾次」。
//   擋（block）：ghosts（遠端重寫過歷史）、old-history/* 分支、force push 或刪除 main／master、
//               ProjectC 的 data/、finance*.json、像金鑰的字串（私鑰、Anthropic／OpenAI／GitHub／AWS／Google／Slack token）
//   提醒（warn）：關鍵字（board/guard/keywords.txt，一行一個，不進任何 repo）；
//               推到公開或公司 repo（board/guard/strict-repos.txt）時關鍵字也算擋
// Kang 確定要推：他自己在終端機打 `! git push …`（使用者自己跑的指令不經過 hook）。

public struct PushCall: Sendable, Equatable {
    public var dir: String
    public var args: [String]        // push 後面的參數
    public init(dir: String, args: [String]) { self.dir = dir; self.args = args }
}

public struct PushEvent: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable { case ok, warn, block }
    public var at: Date
    public var session: String?
    public var name: String?         // 英文名
    public var repo: String          // owner/name（看不出來就資料夾名）
    public var dir: String
    public var refs: [String]
    public var commits: Int
    public var verdict: Verdict
    public var reasons: [String]
    public var secret = false        // 擋下的原因裡有金鑰（保全亮紅燈）
    public var head: String? = nil   // 檢查時的 HEAD（保全面板「放行一次」認這個）
    public init(at: Date, session: String? = nil, name: String? = nil, repo: String, dir: String, refs: [String], commits: Int,
                verdict: Verdict, reasons: [String], secret: Bool = false) {
        self.at = at; self.session = session; self.name = name; self.repo = repo; self.dir = dir; self.refs = refs
        self.commits = commits; self.verdict = verdict; self.reasons = reasons; self.secret = secret
    }
}

public enum PushGuard {
    public typealias Git = (_ dir: String, _ args: [String]) -> (code: Int32, out: String)

    public static var dir: URL { Paths.supportDir.appendingPathComponent("board/guard", isDirectory: true) }
    public static var logURL: URL { dir.appendingPathComponent("pushes.jsonl") }

    // MARK: 從 Bash 指令找出 git push

    /// 簡單的 shell 斷詞：引號、跳脫；&& || ; | 換行 當成獨立的分隔符號
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", has = false
        var q: Character? = nil, esc = false
        let cs = Array(s)
        var i = 0
        func flush() { if has { out.append(cur) }; cur = ""; has = false }
        while i < cs.count {
            let c = cs[i]
            if esc { cur.append(c); esc = false; i += 1; continue }
            if let qq = q {
                if c == qq { q = nil } else if c == "\\" && qq == "\"" { esc = true } else { cur.append(c) }
                i += 1; continue
            }
            switch c {
            case "\\": esc = true; has = true
            case "'", "\"": q = c; has = true
            case " ", "\t": flush()
            case "\n", ";": flush(); out.append(";")
            case "&" where cur.hasSuffix(">"):                       // 2>&1
                cur.append(c)
            case "&", "|":
                flush()
                if i + 1 < cs.count, cs[i + 1] == c { out.append(String([c, c])); i += 1 } else { out.append(String(c)) }
            default: cur.append(c); has = true
            }
            i += 1
        }
        flush()
        return out
    }

    /// 指令裡每一個 git push（跟著 cd 與 -C 算出在哪個資料夾跑）
    public static func calls(command: String, cwd: String) -> [PushCall] {
        guard command.contains("push") else { return [] }
        var dir = cwd, out: [PushCall] = []
        var seg: [String] = []
        var vars = ProcessInfo.processInfo.environment
        // $X、${X}：前面 X=… 設過的或環境變數；展不開的留著 $（check 會因為找不到 repo 而擋）
        func expand(_ s: String) -> String {
            guard s.contains("$") else { return s }
            var r = s
            for (k, v) in vars.sorted(by: { $0.key.count > $1.key.count }) {
                r = r.replacingOccurrences(of: "${\(k)}", with: v).replacingOccurrences(of: "$\(k)", with: v)
            }
            return r
        }
        func resolve(_ p: String, from base: String) -> String {
            let e = (expand(p) as NSString).expandingTildeInPath
            return e.hasPrefix("/") ? (e as NSString).standardizingPath : ((base as NSString).appendingPathComponent(e) as NSString).standardizingPath
        }
        func handle(_ seg: [String]) {
            var t = seg[...]
            while let f = t.first, f.contains("=") && !f.hasPrefix("-") && !f.hasPrefix("/") {               // FOO=bar
                let kv = f.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { vars[kv[0]] = expand(kv[1]) }
                t.removeFirst()
            }
            while let f = t.first, ["command", "env", "time", "nohup", "exec", "sudo"].contains(f) { t.removeFirst() }
            guard let g = t.first else { return }
            if g == "cd" { if t.count >= 2 { dir = resolve(t[t.startIndex + 1], from: dir) }; return }
            guard g == "git" || g.hasSuffix("/git") else { return }
            t.removeFirst()
            var d = dir
            while let f = t.first, f.hasPrefix("-") {
                t.removeFirst()
                if f == "-C", let v = t.first { d = resolve(v, from: d); t.removeFirst() }
                else if f == "-c", t.first != nil { t.removeFirst() }
            }
            guard t.first == "push" else { return }
            // 去掉轉向（2>&1、> log、>>x）
            var args: [String] = [], skip = false
            for x in t.dropFirst() {
                if skip { skip = false; continue }
                if ["<", ">", ">>", "2>", "&>"].contains(x) { skip = true; continue }
                if x.first.map({ $0 == "<" || $0 == ">" || $0.isNumber && x.dropFirst().first.map { $0 == ">" || $0 == "<" } == true }) == true || x.hasPrefix("&>") { continue }
                args.append(x)
            }
            out.append(PushCall(dir: d, args: args))
        }
        for tok in tokenize(command) {
            if [";", "&&", "||", "|", "&"].contains(tok) { handle(seg); seg = [] } else { seg.append(tok) }
        }
        handle(seg)
        return out
    }

    // MARK: 檢查

    struct Args {
        var remote: String?
        var refspecs: [String] = []
        var force = false, all = false, delete = false
    }

    static func parse(_ a: [String]) -> Args {
        var r = Args(), pos: [String] = []
        var it = a[...]
        let takesValue: Set<String> = ["-o", "--push-option", "--receive-pack", "--exec", "--repo"]
        while let x = it.popFirst() {
            if x == "--" { pos += it; break }
            if x.hasPrefix("-") {
                if takesValue.contains(x) { _ = it.popFirst(); continue }
                if x == "--force" || x == "--force-if-includes" || x.hasPrefix("--force-with-lease") { r.force = true }
                else if x == "--all" || x == "--mirror" || x == "--branches" { r.all = true; if x == "--mirror" { r.force = true } }
                else if x == "--delete" { r.delete = true }
                else if !x.hasPrefix("--"), x.count > 1 {                // -fu、-d
                    if x.contains("f") { r.force = true }
                    if x.contains("d") { r.delete = true }
                }
                continue
            }
            pos.append(x)
        }
        r.remote = pos.first
        r.refspecs = Array(pos.dropFirst())
        return r
    }

    /// 遠端網址 → owner/name
    public static func repoName(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).map(String.init)
        return parts.suffix(2).joined(separator: "/")
    }

    static let secretPatterns: [(String, String)] = [
        ("私鑰", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("Anthropic 金鑰", #"sk-ant-[A-Za-z0-9_\-]{20,}"#),
        ("OpenAI 金鑰", #"\bsk-(proj-)?[A-Za-z0-9]{32,}"#),
        ("GitHub token", #"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#),
        ("AWS 金鑰", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("Google API 金鑰", #"\bAIza[0-9A-Za-z_\-]{35}"#),
        ("Slack token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        ("Claude Code 收件鑰匙", #""peerToken"\s*:\s*"[^"]{16,}""#),
    ]

    /// 新增的那幾行（git log -p 的 + 行）裡找金鑰與關鍵字；回傳（金鑰命中, 關鍵字命中），各是「檔案：什麼」
    static func scan(patch: String, keywords: [String]) -> (secrets: [String], words: [String]) {
        let res = secretPatterns.compactMap { n, p in (try? NSRegularExpression(pattern: p)).map { (n, $0) } }
        var file = "?", secrets: [String] = [], words: [String] = []
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("+++ ") { file = raw.hasPrefix("+++ b/") ? String(raw.dropFirst(6)) : String(raw.dropFirst(4)); continue }
            guard raw.hasPrefix("+") else { continue }
            let line = String(raw.dropFirst())
            let ns = line as NSString
            for (n, re) in res where re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                let s = "\(file)：\(n)"
                if !secrets.contains(s) { secrets.append(s) }
            }
            for w in keywords where line.localizedCaseInsensitiveContains(w) {
                let s = "\(file)：「\(w)」"
                if !words.contains(s) { words.append(s) }
            }
        }
        return (secrets, words)
    }

    /// 一行一個，# 開頭是註解
    public static func list(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static func check(_ c: PushCall, git: Git, keywords: [String], strict: [String], now: Date = Date()) -> PushEvent {
        let a = parse(c.args.map { $0 })
        var block: [String] = [], warn: [String] = [], secret = false
        // 看不出在哪個 repo（路徑用了展不開的變數、或不是 git 資料夾）就擋：不能檢查的 push 不放行
        if c.dir.contains("$") || c.dir.contains("`") || git(c.dir, ["rev-parse", "--git-dir"]).code != 0 {
            return PushEvent(at: now, repo: (c.dir as NSString).lastPathComponent, dir: c.dir, refs: [], commits: 0, verdict: .block,
                             reasons: ["保全看不出要推的是哪個 repo（\(c.dir)）；請 cd 到實際路徑、不要用變數，再推一次"])
        }
        let branch = git(c.dir, ["symbolic-ref", "--quiet", "--short", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamRemote = branch.isEmpty ? "" : git(c.dir, ["config", "branch.\(branch).remote"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = a.remote ?? (upstreamRemote.isEmpty ? "origin" : upstreamRemote)
        let isURL = remote.contains("/") || remote.contains(":")
        let url = isURL ? remote : git(c.dir, ["remote", "get-url", remote]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = url.isEmpty ? (c.dir as NSString).lastPathComponent : repoName(url)
        let short = repo.split(separator: "/").last.map(String.init) ?? repo

        // 要推哪些分支
        var specs = a.refspecs
        if a.all {
            specs = git(c.dir, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]).out.split(separator: "\n").map(String.init)
        } else if specs.isEmpty, !branch.isEmpty {
            specs = [branch]
        }
        var srcs: [String] = [], refs: [String] = []
        for s in specs {
            let plus = s.hasPrefix("+")
            let body = plus ? String(s.dropFirst()) : s
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let src = parts[0], dst = parts.count > 1 ? parts[1] : (a.delete ? src : src)
            let dstName = dst.replacingOccurrences(of: "refs/heads/", with: "")
            refs.append(dstName.isEmpty ? src : dstName)
            if src.contains("old-history/") || dst.contains("old-history/") { block.append("old-history/ 分支是改名前的舊歷史，絕不推（\(s)）") }
            let main = ["main", "master"].contains(dstName)
            if main && (a.force || plus) { block.append("force push 到 \(dstName) 會改寫遠端歷史") }
            if main && (a.delete || (parts.count > 1 && src.isEmpty)) { block.append("要刪除遠端的 \(dstName)") }
            if !src.isEmpty && !a.delete && !src.hasPrefix("refs/tags/") { srcs.append(src) }
        }
        if short.lowercased() == "ghosts" {
            block.append("ghosts 的遠端因為資安重寫過歷史，本機的「領先」是舊歷史，推了會把清掉的東西推回去；要同步用 reset --hard")
        }

        // 要推出去的 commit 與內容
        var commits = 0
        if !srcs.isEmpty {
            let not = isURL ? ["--not", "--remotes"] : ["--not", "--remotes=\(remote)"]
            let revs = git(c.dir, ["rev-list", "--max-count=500"] + srcs + not)
            commits = revs.out.split(separator: "\n").count
            if commits > 0 {
                let paths = git(c.dir, ["log", "--format=", "--name-only", "--diff-filter=AM", "--max-count=500"] + srcs + not).out
                    .split(separator: "\n").map(String.init)
                if short == "ProjectC", let p = paths.first(where: { $0.hasPrefix("data/") }) {
                    block.append("ProjectC 的 data/ 是私人內容（財務、家人、LINE 原文），不進 git：\(p)")
                }
                if let p = paths.first(where: { (($0 as NSString).lastPathComponent).lowercased().hasPrefix("finance") && $0.hasSuffix(".json") }) {
                    block.append("財務資料檔不進 git：\(p)")
                }
                let patch = git(c.dir, ["log", "-p", "--format=", "--no-color", "-U0", "--no-ext-diff", "--max-count=500"] + srcs + not).out
                let (sec, words) = scan(patch: patch, keywords: keywords)
                if !sec.isEmpty { secret = true; block.append("像金鑰的字串：" + sec.prefix(5).joined(separator: "、") + (sec.count > 5 ? " 等 \(sec.count) 處" : "")) }
                if !words.isEmpty {
                    let w = "客戶／機密關鍵字：" + words.prefix(5).joined(separator: "、") + (words.count > 5 ? " 等 \(words.count) 處" : "")
                    if strict.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame || $0.caseInsensitiveCompare(short) == .orderedSame }) {
                        block.append(w + "（\(repo) 是公開或公司 repo）")
                    } else { warn.append(w) }
                }
            }
        }
        let verdict: PushEvent.Verdict = !block.isEmpty ? .block : !warn.isEmpty ? .warn : .ok
        var e = PushEvent(at: now, repo: repo, dir: c.dir, refs: refs, commits: commits, verdict: verdict, reasons: block + warn, secret: secret)
        e.head = git(c.dir, ["rev-parse", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return e
    }

    // MARK: hook 輸出、紀錄

    /// PreToolUse 的回應：擋下就 deny；只是提醒就附 additionalContext；沒事回 nil（不輸出，照常走）
    public static func hookOutput(_ evs: [PushEvent]) -> String? {
        let blocked = evs.filter { $0.verdict == .block }
        let warned = evs.filter { $0.verdict == .warn }
        var o: [String: Any] = ["hookEventName": "PreToolUse"]
        if !blocked.isEmpty {
            o["permissionDecision"] = "deny"
            o["permissionDecisionReason"] = "🛡️ 這次 push 被 1 樓保全擋下（不是 git 或網路壞了，不要重試同一個指令）。\n"
                + "repo：\(blocked.map(\.repo).joined(separator: "、"))\n原因：\n"
                + blocked.flatMap(\.reasons).map { "・" + $0 }.joined(separator: "\n")
                + "\n該怎麼做：能處理的先處理（改寫那幾個 commit、移掉檔案或金鑰）再推；不要換個寫法繞過保全。"
                + "如果你認為是誤擋，請找 Kang 核可：他在戰情中心 1 樓保全面板按「放行一次」（認這次的 HEAD，30 分鐘內有效）後你再推一次，"
                + "或他自己在終端機打 `! git push …`。用 showork card --status blocked 回報被擋的原因。"
        } else if !warned.isEmpty {
            o["additionalContext"] = "🛡️ 1 樓保全提醒（\(warned.map(\.repo).joined(separator: "、"))）：" + warned.flatMap(\.reasons).joined(separator: "；")
                + "。這個 repo 不是公開／公司 repo，所以沒擋；如果這些字不該出現，推完後跟使用者說一聲。"
        } else { return nil }
        let d = (try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": o])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: 放行一次（Kang 在保全面板按）

    public struct Allow: Codable, Sendable, Equatable {
        public var dir: String
        public var head: String
        public var until: Date
        public init(dir: String, head: String, until: Date) { self.dir = dir; self.head = head; self.until = until }
    }
    public static var allowURL: URL { dir.appendingPathComponent("allow.json") }
    public static let allowFor: TimeInterval = 30 * 60

    public static func allows(_ url: URL = allowURL) -> [Allow] {
        (try? Data(contentsOf: url)).flatMap { try? BoardJSON.decoder.decode([Allow].self, from: $0) } ?? []
    }
    public static func saveAllows(_ xs: [Allow], _ url: URL = allowURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(xs) { try? d.write(to: url, options: .atomic) }
    }

    /// 面板按「放行一次」：這個資料夾、這個 HEAD，30 分鐘內推一次不擋
    public static func allow(_ e: PushEvent, now: Date = Date(), url: URL = allowURL) {
        guard let h = e.head, !h.isEmpty else { return }
        saveAllows(allows(url).filter { $0.until > now && !($0.dir == e.dir && $0.head == h) } + [Allow(dir: e.dir, head: h, until: now + allowFor)], url)
    }

    /// 被擋的這筆如果 Kang 放行過（同資料夾、同 HEAD、沒過期）⇒ 改成放行，用掉那張放行單；回傳剩下的放行單
    public static func apply(_ e: inout PushEvent, allows xs: [Allow], now: Date) -> [Allow] {
        let live = xs.filter { $0.until > now }
        guard e.verdict == .block, let h = e.head, let i = live.firstIndex(where: { $0.dir == e.dir && $0.head == h }) else { return live }
        e.verdict = .ok
        e.reasons = ["Kang 在保全面板放行一次：" + e.reasons.joined(separator: "；")]
        var rest = live; rest.remove(at: i)
        return rest
    }

    public static func append(_ e: PushEvent, to url: URL = logURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard var d = try? BoardJSON.encoder.encode(e) else { return }
        d.removeAll { $0 == 0x0A }
        d.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: url) }
    }

    /// 最近的紀錄（新的在前）
    public static func recent(_ data: Data?, since: Date) -> [PushEvent] {
        (data ?? Data()).split(separator: 0x0A).compactMap { try? BoardJSON.decoder.decode(PushEvent.self, from: Data($0)) }
            .filter { $0.at >= since }.sorted { $0.at > $1.at }
    }
}
