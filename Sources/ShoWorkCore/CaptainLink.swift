import Foundation

// 隊長連動（派工 T1024033803，10-24 Kang 拍板）：隊長原本只在組員發卡後才知道，開工與高風險步驟都事後才看到。
//   ① 開工卡：使用者直接下指令（UserPromptSubmit，不含 cross-session 訊息、看板轉送、背景通知）⇒ hook 提醒組員動手前先發
//      showork card --kind start（--doing／--how／--touch／--outward），看板轉給隊長時前綴【開工】（CardRelay.text）。
//      組員不等隊長；隊長的修正下一輪送達。只轉組員寫的摘要，不轉使用者指令全文。
//   ② 動作預告：PreToolUse(Bash) 比對高風險指令（清單在 board/guard/preview.tsv，可改），執行前送「【動作預告】名字：類別・指令摘要」給隊長，不阻擋。
//      git push 不在這裡（1 樓保全守門照舊）。只看 Bash；Write／Edit 工具寫進 ~/.claude 不會經過這裡。
public enum CaptainLink {
    // MARK: ① 開工卡

    /// 這則 prompt 是不是使用者直接下的指令（要發開工卡）
    public static func needsStart(prompt: String?) -> Bool {
        guard let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return false }
        // 其他 session 的訊息、看板轉送、背景工作通知、系統訊息：都是包在 <…> 標籤裡進來的
        for tag in ["<cross-session-message", "<task-notification", "<system-reminder", "<local-command", "<command-name>", "<bash-"] where p.hasPrefix(tag) { return false }
        return true
    }

    /// 距上一道使用者指令多久以上算新任務（Penny 補規格 ②）
    public static let newTaskGap: TimeInterval = 10 * 60
    static func promptMark(_ sid: String) -> URL { Captain.dir.appendingPathComponent("prompts/\(sid)") }
    public static func lastPrompt(_ sid: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: promptMark(sid).path))?[.modificationDate] as? Date
    }
    public static func touchPrompt(_ sid: String) {
        let f = promptMark(sid)
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: f)
    }

    /// 10 分鐘內的連續指令：只有換了任務才發
    public static func sameTaskContext(showork: String, doing: String?) -> String {
        "【開工卡】你手上的任務是「\(doing ?? "（還沒報）")」。這道指令如果是同一件事接著做，不用發開工卡；換成新任務才在動手前發："
            + "\"\(showork)\" card --kind start --doing \"<新任務>\" --summary \"<要做什麼>\" --how \"<打算怎麼做>\" --touch \"<會動到什麼>\" --outward \"<對外動作或「無」>\""
    }

    /// 注入給組員的提醒（UserPromptSubmit 的 additionalContext）
    public static func startContext(showork: String) -> String {
        """
        【開工卡】這是使用者直接下的指令。動手（讀檔以外的任何改動、跑會改東西的指令）之前，先用 Bash 發一張開工卡給隊長，發完直接開始做、不用等回覆：
        "\(showork)" card --kind start --doing "<這件事，10 個字內>" --summary "<要做什麼，一句話>" --how "<打算怎麼做>" --touch "<會動到哪些檔／repo／系統設定；沒有寫「無」>" --outward "<要不要 push、部署、對外傳訊息；沒有寫「無」>"
        只是聊天、回答問題、不動手的回合不用發。不要把使用者的原話整段貼進卡片。
        """
    }

    // MARK: ② 動作預告（兩級：擋＝等放行；告＝只通知）

    public struct Rule: Sendable, Equatable {
        public var name: String
        public var block: Bool               // true＝擋下等放行；false＝只預告
        public var pattern: String
        public init(name: String, block: Bool, pattern: String) { self.name = name; self.block = block; self.pattern = pattern }
    }

    /// 暫存區（rm／mv 到這些地方不擋）
    static let temp = #"['"]?(?:/tmp/|/private/tmp/|/private/var/folders/|/var/folders/|\$\{?TMPDIR|\$TMP\b|[^\s;&|]*scratchpad)"#
    static let claudeDir = #"(?:~|\$HOME|\$\{HOME\}|/Users/[^/\s]+)/\.claude/(?:scripts|data)\b"#

    /// 預設清單（第一次用會寫成 preview.tsv，之後以檔案為準）。
    /// 比對的對象是「一段指令」（見 segments：以 ; && || | 換行切開、去掉 sudo／env 這類前綴、引號內容換成 Q），所以 ^ 就是指令的第一個詞
    public static var defaultRules: [Rule] { rules(LocalConfig.current) }
    public static func rules(_ local: LocalConfig) -> [Rule] { [
        Rule(name: "rm 刪除（暫存區以外）", block: true,
             // 重導向（2>/dev/null、>log）不是要刪的目標（10-24 BJ6M2：rm -rf "/tmp/WT" 2>/dev/null 被擋）
             pattern: #"^rm\s+(?:-[a-zA-Z]+\s+)*(?:[^\s;&|]+\s+)*?(?!"# + temp + #")(?!-)(?![0-9&]*[<>])[^\s;&|]+"#),
        Rule(name: "mv 到非暫存區", block: true,
             pattern: #"^mv\s+(?:[^\n]*?\s)?(?!"# + temp + #")(?![0-9&]*[<>])[^\s]+(?:\s+[0-9&]*[<>]>?\s*\S+)*\s*$"#),
        Rule(name: "firebase 部署", block: true, pattern: #"^(?:npx\s+)?firebase\s+deploy\b"#),
        Rule(name: "App 封裝／上傳 App Store Connect", block: true,
             // 10-24 隊長：-exportArchive 前面是「-」，原本的 \b(-exportArchive) 永遠比不到 ⇒ Sam 的上傳沒擋到。匯出不論有沒有 upload 都擋
             pattern: #"^xcodebuild\b.*(?:\barchive\b|\s-exportArchive\b)|^(?:xcrun\s+)?(?:altool\b|notarytool\s+submit\b)|^\S*(?:iTMSTransporter|Transporter)\b|^(?:bundle\s+exec\s+)?fastlane\s+(?:\S+\s+)?(?:deliver|pilot|upload_to_app_store|upload_to_testflight)\b"#),
        Rule(name: "LINE 對外傳訊（line_send.py）", block: true, pattern: #"^(?:python3?\s+(?:-\S+\s+)*)?\S*line_send\.py\b"#),
        // 10-24 隊長：Sam 在公開 repo 用 gh 留言／開 PR，開工卡回覆前就送出去了。這裡粗篩，Okle42 私有 repo 免擋的細判在 GHGuard
        Rule(name: "GitHub 公開發言（gh）", block: true,
             pattern: #"^(?:\S*/)?gh\s+(?:.*\s)?(?:issue\s+(?:comment|create)|pr\s+(?:create|comment|review)|release\s+create)\b|^(?:\S*/)?gh\s+(?:.*\s)?api\b.*\s(?:-X\s*|--method[\s=]+)(?:POST|PATCH|PUT|DELETE)\b|^(?:\S*/)?gh\s+(?:.*\s)?api\b.*\s(?:-f|-F|--field|--raw-field|--input)(?:\s|=)"#),
        Rule(name: "改系統設定（defaults write）", block: false, pattern: #"^defaults\s+(?:-currentHost\s+)?write\b"#),
        Rule(name: "寫入 ~/.claude/scripts 或 data", block: false,
             pattern: #"^(?:cp|mv|tee|install|ln|rsync)\b.*\s"# + claudeDir + #"\S*\s*$|>>?\s*"# + claudeDir + #"|^sed\s+-i\S*\s.*"# + claudeDir),
    ] + (local.winHosts ?? []).map { h in
        // 遠端 Windows 主機別名在本機設定 local.json 的 winHosts（LocalConfig）
        Rule(name: "遠端 Windows 寫入（ssh \(h)）", block: false,
             pattern: #"^ssh\s+"# + NSRegularExpression.escapedPattern(for: h) + #"\b.*\b(?:Set-|Remove-|New-Item|Rename-|Move-Item|Copy-Item|Stop-|Restart-|Install-|Uninstall-|reg(?:\.exe)?\s+(?:add|delete|import))"#)
    } }
    /// preview.tsv 格式版本（舊格式的檔案會被換成新的預設）
    static let rulesVersion = "格式 v5"

    public static var rulesFile: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_PREVIEW_RULES"] { return URL(fileURLWithPath: p) }
        return Captain.dir.appendingPathComponent("guard/preview.tsv")
    }

    /// preview.tsv：一行「類別<TAB>擋|告<TAB>正規表示式」，# 開頭是註解；檔案不在就寫預設的
    public static func loadRules() -> [Rule] {
        let f = rulesFile
        guard let d = FileManager.default.contents(atPath: f.path), String(decoding: d, as: UTF8.self).contains(rulesVersion) else {
            let owner = LocalConfig.current.ownerName
            let head = "# 動作預告（T1024033803 ②，\(rulesVersion)）：一行「類別<TAB>擋|告<TAB>正規表示式」，不分大小寫。\n"
                + "# 比對的是「一段指令」：以 ; && || | 換行切開、去掉 sudo／env／VAR=值 前綴，引號內容換成 Q（ssh 那段保留引號內容），heredoc 內文拿掉 ⇒ ^ 就是指令的第一個詞。\n"
                + "# 擋＝先擋下、等隊長轉述\(owner)的決定（showork release）或\(owner)在那個 session 打「放行」；告＝只通知隊長不擋。# 開頭是註解，刪掉這個檔會重寫預設\n"
            let body = defaultRules.map { "\($0.name)\t\($0.block ? "擋" : "告")\t\($0.pattern)" }.joined(separator: "\n") + "\n"
            try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (head + body).write(to: f, atomically: true, encoding: .utf8)
            return defaultRules
        }
        return parseRules(String(decoding: d, as: UTF8.self))
    }

    public static func parseRules(_ text: String) -> [Rule] {
        text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count == 3, !f[0].isEmpty, !f[2].isEmpty else { return nil }
            return Rule(name: f[0], block: f[1] == "擋", pattern: f[2])
        }
    }

    /// 把整條 Bash 指令切成會被執行的「一段段指令」（隊長 10-24：關鍵字只算出現在指令層級的，引號、heredoc、python -c 參數內的不算）
    ///   1. 拿掉 heredoc 內文  2. 依引號外的 ; && || | & 換行切段  3. 去掉 sudo／env／VAR=值／time／nohup／( { ! 這類前綴
    ///   4. 引號內容換成 Q（ssh 開頭的那段保留：遠端要跑的指令就在引號裡）
    public static func segments(_ cmd: String) -> [String] { segmentPairs(cmd).map(\.norm) }

    /// (原文, 比對用)：原文給預告摘要（隊長要看到「命中的那一段」，10-24 BR9R8 只看開頭判錯）
    public static func segmentPairs(_ cmd: String) -> [(raw: String, norm: String)] {
        var t = cmd
        // 同一條指令前面把變數設成暫存路徑（T=$(mktemp -d)、S=/private/tmp/…、D="$TMPDIR/x"）⇒ 後面的 $T、${T} 當成 /tmp/ 底下（隊長 10-24：BKZQP 誤擋）
        if let re = try? NSRegularExpression(pattern: #"(?:^|[;&|\n(]|\s)(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=["']?(?:\$\(\s*mktemp\b|/tmp/|/private/tmp/|/private/var/folders/|/var/folders/|\$\{?TMPDIR\b|\$\{?TMP\b|[^\s;&|"']*scratchpad)"#) {
            let names = Set(re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { Range($0.range(at: 1), in: t).map { String(t[$0]) } })
            for n in names {
                if let v = try? NSRegularExpression(pattern: "\\$\\{?" + n + "\\b\\}?") {
                    t = v.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "/tmp/" + n)
                }
            }
        }
        if let re = try? NSRegularExpression(pattern: #"<<-?\s*['"]?(\w+)['"]?([^\n]*)\n.*?\n\s*\1\b"#, options: [.dotMatchesLineSeparators]) {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$2")
        }
        // 引號外的分隔符切段（保留原文，第 4 步才換引號內容）
        var raw: [String] = [], cur = "", q: Character? = nil, esc = false
        let cs = Array(t)
        var i = 0
        while i < cs.count {
            let c = cs[i]
            if esc { cur.append(c); esc = false; i += 1; continue }
            if c == "\\", q != "'" { esc = true; cur.append(c); i += 1; continue }
            if let qq = q { if c == qq { q = nil }; cur.append(c); i += 1; continue }
            if c == "'" || c == "\"" { q = c; cur.append(c); i += 1; continue }
            if c == ";" || c == "|" || c == "&" || c == "\n" || c == "(" || c == ")" || c == "`" {
                raw.append(cur); cur = ""
                if i + 1 < cs.count, (c == "|" || c == "&"), cs[i + 1] == c { i += 1 }
                i += 1; continue
            }
            if c == "$", i + 1 < cs.count, cs[i + 1] == "(" { raw.append(cur); cur = ""; i += 2; continue }   // $( … ) 裡也是指令
            cur.append(c); i += 1
        }
        raw.append(cur)
        let prefix = try? NSRegularExpression(pattern: #"^(?:\s+|[{!]\s*|(?:sudo|env|time|nohup|exec|command|then|do|else|if|while|until)\s+(?:-\S+\s+)*|[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|"(?:[^"\\]|\\.)*"|\S*)\s*)+"#)
        let quoted = try? NSRegularExpression(pattern: #"'[^']*'|"(?:[^"\\]|\\.)*""#)
        return raw.compactMap { seg -> (raw: String, norm: String)? in
            var s = seg
            if let prefix { s = prefix.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "") }
            s = s.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !isShowork(s) else { return nil }        // showork 自己的指令（card／b1／release…）整段不看
            let r = s
            if !s.hasPrefix("ssh ") { s = Self.blankQuotes(s) }        // 引號內容換成 Q（ssh 那段保留：遠端指令在引號裡）
            _ = quoted
            return (r, s)
        }
    }

    /// 這段指令是不是 showork 本身（"…/ShoWork42/bin/showork" card …、showork b1 post …）
    static func isShowork(_ s: String) -> Bool {
        var first = s
        if let q = s.first, q == "\"" || q == "'" { first = String(s.dropFirst().prefix { $0 != q }) }
        else { first = String(s.prefix { !$0.isWhitespace }) }
        return first == "showork" || first.hasSuffix("/showork")
    }

    /// 引號內容換成 Q，但開頭的暫存路徑字首留著（"/tmp/… → "/tmp/Q"），讓 rm／mv 的暫存區判斷還看得到
    static func blankQuotes(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(['"])([^'"]*)\1"#) else { return s }
        var out = "", last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s), let br = Range(m.range(at: 2), in: s), let qr = Range(m.range(at: 1), in: s) else { continue }
            out += s[last..<r.lowerBound]
            let body = String(s[br]), qc = String(s[qr])
            let keep = ["/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/", "$TMPDIR", "${TMPDIR", "$TMP/"].first { body.hasPrefix($0) }
                ?? (body.contains("scratchpad") ? "scratchpad/" : nil)
            out += qc + (keep ?? "") + "Q" + qc
            last = r.upperBound
        }
        return out + s[last...]
    }

    /// 命中的規則（依清單順序；任一段指令符合就算）
    public static func match(_ cmd: String, rules: [Rule]) -> [Rule] { hits(cmd, rules: rules).map(\.rule) }

    /// 命中的規則＋命中的那一段原文（第一段符合的）
    public static func hits(_ cmd: String, rules: [Rule]) -> [(rule: Rule, segment: String)] {
        let segs = segmentPairs(cmd)
        return rules.compactMap { r in
            guard let re = try? NSRegularExpression(pattern: r.pattern, options: [.caseInsensitive]),
                  let seg = segs.first(where: { re.firstMatch(in: $0.norm, range: NSRange($0.norm.startIndex..., in: $0.norm)) != nil }) else { return nil }
            return (r, seg.raw)
        }
    }

    /// 預告摘要：命中的那幾段（去重複）；整條指令比命中段長就標「（整條共 N 段）」
    public static func hitSummary(_ cmd: String, _ hs: [(rule: Rule, segment: String)]) -> String {
        var segs: [String] = []
        for h in hs where !segs.contains(h.segment) { segs.append(h.segment) }
        let n = segmentPairs(cmd).count
        return segs.map { summary($0) }.joined(separator: " ／ ") + (n > segs.count ? "（整條共 \(n) 段，只列命中的）" : "")
    }

    /// 指令摘要：壓成一行、長字串（金鑰、token 長相）遮掉、LINE 訊息內容不帶、最多 160 字
    public static func summary(_ cmd: String) -> String {
        var t = cmd
        if let r = t.range(of: "line_send.py") { t = String(t[..<r.upperBound]) + " ‹訊息內容略›" }
        t = t.replacingOccurrences(of: "\n", with: " ⏎ ")
        if let re = try? NSRegularExpression(pattern: #"[A-Za-z0-9_\-+=]{32,}"#) {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "‹長字串›")
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.count > 160 ? String(t.prefix(160)) + "⋯" : t
    }

    /// 擋下等放行用的指紋：只看命中「擋」規則的那幾段（規則名＋那段原文，去掉多的空白）。
    /// T1025044431（10-24 Tina BKDDE → B6Q44）：原本拿整條指令算，第一次前面多一行 showork card（開工卡）、重跑時沒有，
    /// 指紋就對不上 ⇒ 放行後一字不差重跑又被擋。cd、tail、showork 這些沒命中的段落不影響；真的換了要擋的動作才算新指令
    public static func blockFingerprint(_ cmd: String, rules: [Rule]) -> String {
        let segs = segmentPairs(cmd)
        var parts: [String] = []
        for r in rules where r.block {
            guard let re = try? NSRegularExpression(pattern: r.pattern, options: [.caseInsensitive]) else { continue }
            for sg in segs where re.firstMatch(in: sg.norm, range: NSRange(sg.norm.startIndex..., in: sg.norm)) != nil {
                parts.append(r.name + "\t" + sg.raw.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            }
        }
        return parts.isEmpty ? fingerprint(cmd) : fingerprint(parts.joined(separator: "\n"))
    }

    /// 指令指紋（放行比對用；FNV-1a 64）
    public static func fingerprint(_ cmd: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in cmd.trimmingCharacters(in: .whitespacesAndNewlines).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    public static func label(_ name: String, _ project: String?) -> String { name + ((project ?? "").isEmpty ? "" : "（\(project!)）") }

    /// 擋下時給 AI 的理由
    public static func denyReason(_ item: CaptainInboxItem) -> String {
        let owner = LocalConfig.current.ownerName
        return "⛔️ 這個指令需要放行才能跑（\(item.kinds.joined(separator: "、"))，單號 \(item.id)）。已通知隊長，不要重試、不要換寫法繞過，也不要自己跑 showork release。\n"
            + "要放行請隊長轉述\(owner)的決定（隊長跑 showork release \(item.id)），或\(owner)在這個 session 直接打「放行」。放行後再跑一次同一個指令（30 分鐘內有效、只能用一次）。\n"
            + "等的時候用 showork card --status blocked 回報卡在哪；能改用暫存區（scratchpad、/tmp）的就改用。"
    }

    /// 擋下：立即送隊長
    public static func blockText(_ item: CaptainInboxItem) -> String {
        let owner = LocalConfig.current.ownerName
        return "【動作預告・擋下 \(item.id)】\(label(item.name, item.project))：\(item.kinds.joined(separator: "、"))・\(item.text)\n"
            + "（已擋下等放行。\(owner)明說同意這個動作才 showork release \(item.id)；隊長不能自己決定放行對外動作）"
    }

    /// 不擋的預告：同一 session 的合成一則
    public static func noticeText(_ items: [CaptainInboxItem]) -> String {
        guard let f = items.first else { return "" }
        var lines = ["【動作預告】\(label(f.name, f.project))：\(items.count) 個動作（不擋，已在跑）"]
        for i in items { lines.append("・\(i.kinds.joined(separator: "、"))：\(i.text)") }
        lines.append("（有疑慮馬上 SendMessage 叫它停）")
        return lines.joined(separator: "\n")
    }

    // MARK: 合併預告：同一 session 安靜 quiet 秒（最多等 maxWait）才送

    public static let quiet: TimeInterval = 5, maxWait: TimeInterval = 30, staleAfter: TimeInterval = 600

    /// 現在該送的預告（依 session 分組）；太舊的（10 分鐘）不送，留給新隊長 showork captain 時印
    public static func dueNotices(_ items: [CaptainInboxItem], now: Date) -> [[CaptainInboxItem]] {
        let open = items.filter { $0.kind == .notice && !$0.delivered && now.timeIntervalSince($0.at) < staleAfter }
        return Dictionary(grouping: open, by: \.sid).values.compactMap { g in
            let g = g.sorted { $0.at < $1.at }
            guard let first = g.first, let last = g.last else { return nil }
            return now.timeIntervalSince(last.at) >= quiet || now.timeIntervalSince(first.at) >= maxWait ? g : nil
        }.sorted { $0[0].at < $1[0].at }
    }

    // MARK: ③ 隊長鬧鐘

    public static let alarmKey = "captain.alarmMinutes"
    public static let idleAfter: TimeInterval = 30 * 60

    /// 名冊一行摘要＋指紋（沒變化就只送一行）
    public static func alarm(_ r: Roster, pending: Int, now: Date) -> (text: String, sig: String) {
        let crew = r.entries.filter { !$0.captain }.sorted { $0.name < $1.name }
        let idle = crew.filter { e in e.lastActivity.map { now.timeIntervalSince($0) > idleAfter } ?? true }.map(\.name)
        let ctx = crew.map { "\($0.name) \($0.ctx.map { "\($0)%" } ?? "–")" }
        let base = crew.map { "\($0.name):\(($0.ctx ?? -10) / 10)" }.joined(separator: ",") + "|" + idle.joined(separator: ",") + "|\(pending)"
        let wrapped = crew.compactMap { e in e.handover.map { "\(e.name)（\($0)）" } }
        let sig = base + "|" + wrapped.joined(separator: ",")
        var t = "【巡檢時間】在線 \(crew.count) 人（不含隊長）"
        if !ctx.isEmpty { t += "；ctx：" + ctx.joined(separator: "、") }
        t += "；閒置超過 30 分鐘：" + (idle.isEmpty ? "沒有" : idle.joined(separator: "、"))
        if !wrapped.isEmpty { t += "；已收尾、還沒 /clear：" + wrapped.joined(separator: "、") }
        if pending > 0 { t += "；收件匣未處理 \(pending) 則（showork captain 看）" }
        t += "\n（看 showork roster、showork tasks、showork b1 read）"
        return (t, sig)
    }
    public static func alarmUnchanged(crew n: Int) -> String { "【巡檢時間】無變化（在線 \(n) 人，跟上次一樣）" }
}

// MARK: ④ 隊長收件匣（board/captain-inbox/<id>.json：開工卡、預告、擋下；新隊長 showork captain 先印未處理的）

public struct CaptainInboxItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case start, notice, block }
    public var id: String
    public var kind: Kind
    public var at: Date
    public var sid: String
    public var name: String
    public var project: String?
    public var kinds: [String]            // 預告的類別（開工卡＝空）
    public var text: String               // 指令摘要／開工卡一句話
    public var fingerprint: String?       // 擋下的指令指紋
    public var delivered = false          // 送到隊長了
    public var released: Date?            // 擋下的：放行時間
    public var used: Date?                // 放行後真的跑了
    public var acked: Date?               // 隊長處理過（showork captain ack）：不再算「未處理」
    public init(id: String, kind: Kind, at: Date, sid: String, name: String, project: String?, kinds: [String] = [], text: String, fingerprint: String? = nil) {
        self.id = id; self.kind = kind; self.at = at; self.sid = sid; self.name = name; self.project = project; self.kinds = kinds; self.text = text; self.fingerprint = fingerprint
    }
    /// 一行（showork captain 印）
    public var line: String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        let tag = kind == .start ? "開工" : kind == .notice ? "預告" : (released == nil ? "擋下・等放行" : "已放行")
        return "\(id) \(f.string(from: at)) [\(tag)] \(CaptainLink.label(name, project))：" + (kinds.isEmpty ? "" : kinds.joined(separator: "、") + "・") + text
    }
}

/// 放行紀錄（board/permits/releases.jsonl；事後稽核：誰、什麼時候、用哪種方式放行了哪一個）
public struct ReleaseRecord: Codable, Sendable, Equatable {
    public var at: Date
    public var id: String
    public var by: String                 // 放行者 sessionId
    public var byName: String
    public var target: String             // 被擋的 session
    public var summary: String
    public var source: String             // "release 指令"／"使用者輸入"
    public init(at: Date, id: String, by: String, byName: String, target: String, summary: String, source: String) {
        self.at = at; self.id = id; self.by = by; self.byName = byName; self.target = target; self.summary = summary; self.source = source
    }
}

public enum CaptainInbox {
    public static var dir: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_CAPTAIN_INBOX"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return Captain.dir.appendingPathComponent("captain-inbox", isDirectory: true)
    }
    public static var releaseLog: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_RELEASE_LOG"] { return URL(fileURLWithPath: p) }
        return Captain.dir.appendingPathComponent("permits/releases.jsonl")
    }
    /// 放行有效時間
    public static let releaseTTL: TimeInterval = 30 * 60

    public static func newID(_ kind: CaptainInboxItem.Kind) -> String {
        let a = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return (kind == .block ? "B" : kind == .notice ? "N" : "S") + String((0..<4).map { _ in a.randomElement()! })
    }

    @discardableResult
    public static func save(_ i: CaptainInboxItem) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d = try? BoardJSON.encoder.encode(i) else { return false }
        return (try? d.write(to: dir.appendingPathComponent(i.id + ".json"), options: .atomic)) != nil
    }

    public static func all() -> [CaptainInboxItem] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.compactMap {
            fm.contents(atPath: dir.appendingPathComponent($0).path).flatMap { try? BoardJSON.decoder.decode(CaptainInboxItem.self, from: $0) }
        }.sorted { $0.at < $1.at }
    }

    public static func item(_ id: String) -> CaptainInboxItem? {
        FileManager.default.contents(atPath: dir.appendingPathComponent(id.uppercased() + ".json").path).flatMap { try? BoardJSON.decoder.decode(CaptainInboxItem.self, from: $0) }
    }

    /// 7 天前的刪掉（看板刷新時順便）
    public static func prune(now: Date) {
        for i in all() where now.timeIntervalSince(i.at) > 7 * 86400 { try? FileManager.default.removeItem(at: dir.appendingPathComponent(i.id + ".json")) }
    }

    /// 未處理：隊長還沒 ack、而且沒送到隊長的或還在等放行的（24 小時內）
    public static func pending(now: Date) -> [CaptainInboxItem] {
        all().filter { $0.acked == nil && now.timeIntervalSince($0.at) < 86400 && (!$0.delivered || ($0.kind == .block && $0.released == nil)) }
    }

    /// 隊長標已處理：單號或 all（全部未處理的）；回傳標了幾筆
    @discardableResult
    public static func ack(_ id: String, now: Date) -> Int {
        let xs = id.lowercased() == "all" ? pending(now: now) : all().filter { $0.id == id.uppercased() && $0.acked == nil }
        for var i in xs { i.acked = now; save(i) }
        return xs.count
    }

    /// 這個 session 的這個指令有沒有有效的放行；有就用掉（回 true＝可以跑）
    public static func consume(sid: String, fingerprint fp: String, now: Date) -> Bool {
        guard var i = all().last(where: { $0.kind == .block && $0.sid == sid && $0.fingerprint == fp && $0.used == nil
            && $0.released.map { now.timeIntervalSince($0) < releaseTTL } == true }) else { return false }
        i.used = now; save(i)
        return true
    }

    /// 還在等放行的同一個指令（重試時不再開新單）
    public static func waiting(sid: String, fingerprint fp: String) -> CaptainInboxItem? {
        all().last { $0.kind == .block && $0.sid == sid && $0.fingerprint == fp && $0.released == nil }
    }

    /// 放行：寫紀錄（releases.jsonl）。id＝nil ⇒ 這個 session 最近一張等放行的
    public static func release(id: String?, target sid: String?, by: String, byName: String, source: String, now: Date) -> CaptainInboxItem? {
        let waiting = all().filter { $0.kind == .block && $0.released == nil && now.timeIntervalSince($0.at) < 86400 }
        guard var i = id.map({ x in waiting.first { $0.id == x.uppercased() } }) ?? waiting.last(where: { $0.sid == sid }) else { return nil }
        if let sid, i.sid != sid { return nil }
        i.released = now; save(i)
        let r = ReleaseRecord(at: now, id: i.id, by: by, byName: byName, target: i.sid, summary: i.text, source: source)
        if var d = try? BoardJSON.encoder.encode(r) {
            d.append(0x0A)
            try? FileManager.default.createDirectory(at: releaseLog.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: releaseLog) { _ = try? h.seekToEnd(); try? h.write(contentsOf: d); try? h.close() }
            else { try? d.write(to: releaseLog, options: .atomic) }
        }
        return i
    }

    public static func releases() -> [ReleaseRecord] {
        guard let d = FileManager.default.contents(atPath: releaseLog.path) else { return [] }
        return d.split(separator: 0x0A).compactMap { try? BoardJSON.decoder.decode(ReleaseRecord.self, from: Data($0)) }
    }
}

/// 戰情中心回答＝事先放行（10-31 使用者：「我交代你做事還要放行」）。
/// 使用者在戰情中心按選項／打字回答某個 AI 的問題時，答案裡明說的對外動作（例如「開 PR」「LINE 通知」）
/// 之後被「擋」規則攔下就直接算放行：同一個 session、30 分鐘內、每種動作一次，照樣寫 releases.jsonl（source＝戰情中心回答）並通知隊長。
/// 點名這個動作的小句有否定字（不要／先不／別⋯）就不算；沒點名的動作照擋。rm／mv 不在內（刪檔搬檔一律要明確放行）。
public struct Preapproval: Codable, Sendable, Equatable {
    public var at: Date
    public var sid: String
    public var answer: String
    public var question: String?
    public var used: [String] = []        // 已經用掉的規則名
    public init(at: Date, sid: String, answer: String, question: String?) {
        self.at = at; self.sid = sid; self.answer = answer; self.question = question
    }
}

extension CaptainInbox {
    public static var preapprovalLog: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_PREAPPROVAL_LOG"] { return URL(fileURLWithPath: p) }
        return Captain.dir.appendingPathComponent("permits/preapprovals.json")
    }

    /// 擋規則 → 答案裡要出現的字（點名這個動作）
    static let preapprovalWords: [(rule: String, words: [String])] = [
        ("GitHub 公開發言", ["PR", "pull request", "issue", "留言", "GitHub", "發 release", "發布"]),
        ("LINE 對外傳訊", ["LINE", "傳訊", "私訊", "通知"]),
        ("firebase 部署", ["部署", "deploy", "firebase", "上線"]),
        ("App 封裝／上傳", ["上傳", "送審", "TestFlight", "上架", "archive"]),
    ]
    static let negations = ["不要", "先不", "別", "不用", "暫緩", "取消", "不准", "禁止", "等一下", "等等", "先等"]

    /// 這則答案有沒有點名放行這條擋規則：按逗號、分號、句號切成小句，
    /// 有小句點名、而且點名它的小句都沒有否定字才算（「先開 PR，不通知」＝PR 算、LINE 不算）
    public static func authorizes(_ answer: String, rule: String) -> Bool {
        guard let ws = preapprovalWords.first(where: { rule.hasPrefix($0.rule) })?.words else { return false }
        let clauses = answer.lowercased().split(whereSeparator: { "，,、；;。！!？?\n".contains($0) }).map(String.init)
        let named = clauses.filter { c in ws.contains { c.contains($0.lowercased()) } }
        return !named.isEmpty && named.allSatisfy { c in !negations.contains { c.contains($0) } && !c.contains("不") }
    }

    static func loadPreapprovals() -> [Preapproval] {
        guard let d = FileManager.default.contents(atPath: preapprovalLog.path) else { return [] }
        return (try? BoardJSON.decoder.decode([Preapproval].self, from: d)) ?? []
    }
    static func savePreapprovals(_ xs: [Preapproval]) {
        try? FileManager.default.createDirectory(at: preapprovalLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(xs) { try? d.write(to: preapprovalLog, options: .atomic) }
    }

    /// 戰情中心送出回答時記下（只留 24 小時內）
    public static func recordAnswer(sid: String, answer: String, question: String?, now: Date) {
        let xs = loadPreapprovals().filter { now.timeIntervalSince($0.at) < 86400 }
        savePreapprovals(xs + [Preapproval(at: now, sid: sid, answer: answer, question: question)])
    }

    /// 被擋的這些規則是不是都已經被這個 session 30 分鐘內的戰情中心回答點名放行；是就記用掉、回那則答案
    public static func usePreapproval(sid: String, rules: [String], now: Date) -> Preapproval? {
        guard !rules.isEmpty else { return nil }
        var xs = loadPreapprovals()
        guard let k = xs.indices.last(where: { i in
            let p = xs[i]
            return p.sid == sid && now.timeIntervalSince(p.at) < releaseTTL && now >= p.at
                && rules.allSatisfy { r in !p.used.contains(r) && authorizes(p.answer, rule: r) }
        }) else { return nil }
        xs[k].used += rules
        savePreapprovals(xs)
        return xs[k]
    }

    /// 事先放行的擋單：直接記成已放行＋已用，寫稽核紀錄
    @discardableResult
    public static func releaseByAnswer(_ item: CaptainInboxItem, answer: Preapproval, now: Date) -> CaptainInboxItem {
        var i = item
        save(i)
        _ = release(id: i.id, target: i.sid, by: "戰情中心", byName: "使用者（戰情中心回答：\(answer.answer)）", source: "戰情中心回答", now: now)
        i = self.item(i.id) ?? i
        i.used = now; save(i)
        return i
    }
}
