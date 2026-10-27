import Foundation
import Testing
@testable import ShoWorkCore

// 隊長連動（T1024033803）：假名、假指令（10-22 規矩）
@Suite("CaptainLink")
struct CaptainLinkTests {
    let t0 = Date(timeIntervalSince1970: 1_792_650_000)

    @Test("① 只有使用者直接下的指令要開工卡")
    func needsStart() {
        #expect(CaptainLink.needsStart(prompt: "幫我把專案A的按鈕改成藍色"))
        #expect(!CaptainLink.needsStart(prompt: "  "))
        #expect(!CaptainLink.needsStart(prompt: nil))
        #expect(!CaptainLink.needsStart(prompt: "<cross-session-message from=\"uds:/tmp/x.sock\">【派工回報】</cross-session-message>"))
        #expect(!CaptainLink.needsStart(prompt: "<task-notification>背景工作完成</task-notification>"))
        let c = CaptainLink.startContext(showork: "/x/showork")
        #expect(c.hasPrefix("【開工卡】") && c.contains("\"/x/showork\" card --kind start") && c.contains("--touch") && c.contains("--outward"))
    }

    @Test("① 開工卡：不寫 --status 當 working；轉隊長前綴【開工】；不受 60 秒節流")
    func startCard() throws {
        let s = try SelfReport.parse(args: ["--kind", "start", "--doing", "改按鈕", "--summary", "按鈕改藍", "--how", "改 View.swift",
                                            "--touch", "專案A/View.swift", "--outward", "無"], now: t0).get()
        #expect(s.status == .working && s.isStart && s.touch == "專案A/View.swift" && s.outward == "無")
        if case .success = SelfReport.parse(args: ["--kind", "nope", "--status", "done"]) { Issue.record("--kind 只收 start") }
        let t = CardRelay.text(name: "小明", project: "專案A", report: s)
        #expect(t.hasPrefix("【開工】小明（專案A）：改按鈕") && t.contains("會動到：專案A/View.swift") && t.contains("對外動作：無"))
        var st = CardRelay.State(); st.seeded = true
        let work = SelfReport(status: .working, summary: "前一張", at: t0)
        #expect(CardRelay.plan(reports: ["a": work], captain: "c", captainLive: true, state: &st, now: t0) { _, r in r.summary ?? "" }.count == 1)
        var start = s; start.at = t0 + 5
        let out = CardRelay.plan(reports: ["a": start], captain: "c", captainLive: true, state: &st, now: t0 + 5) { _, r in CardRelay.text(name: "小明", project: nil, report: r) }
        #expect(out.count == 1 && out[0].text.hasPrefix("【開工】"))
    }

    @Test("① hook 輸出：有名字帶 sessionTitle＋提醒；沒名字只帶提醒")
    func hookOut() throws {
        let n = Nickname(name: "小明", doing: nil)
        let a = Nicknames.hookOutput(n, done: false, event: "UserPromptSubmit", context: "【開工卡】x")
        let o = try #require(JSONSerialization.jsonObject(with: Data(a.utf8)) as? [String: Any])
        let h = try #require(o["hookSpecificOutput"] as? [String: Any])
        #expect(h["sessionTitle"] as? String == "小明" && h["additionalContext"] as? String == "【開工卡】x")
        let b = Nicknames.hookOutput(nil, done: false, event: "UserPromptSubmit", context: "【開工卡】y")
        #expect(b.contains("additionalContext") && !b.contains("terminalSequence"))
        #expect(Nicknames.hookOutput(nil, done: false, event: "PostToolUse") == "")
    }

    func names(_ c: String) -> [String] { CaptainLink.match(c, rules: CaptainLink.rules(LocalFixture.config)).map { ($0.block ? "擋:" : "告:") + $0.name } }

    @Test("② 兩級規則：擋 rm／mv 非暫存區、firebase、上傳、LINE；告 defaults、~/.claude、winbox")
    func rules() {
        #expect(names("rm -rf build/") == ["擋:rm 刪除（暫存區以外）"])
        #expect(names("rm -f /tmp/x.png").isEmpty)
        #expect(names("rm -rf /private/tmp/claude-501/s/scratchpad/a").isEmpty)
        #expect(names("rm /tmp/a.txt src/main.swift") == ["擋:rm 刪除（暫存區以外）"])          // 有一個不在暫存區就擋
        #expect(names("git rm --cached a.txt").isEmpty)
        #expect(names("mv a.txt b.txt") == ["擋:mv 到非暫存區"])
        #expect(names("mv a.txt /tmp/trash/").isEmpty)
        #expect(names("mv \"$TMPDIR/x\" ~/Desktop/x") == ["擋:mv 到非暫存區"])
        #expect(names("git mv old.swift new.swift").isEmpty)
        #expect(names("git commit -m \"改 rm 規則、mv 也擋\"").isEmpty)                                  // commit 訊息裡的字不算
        #expect(names("python3 - <<'EOF'\nos.system('rm -rf x')\nEOF").isEmpty)                         // heredoc 內文不算
        #expect(names("firebase deploy --only hosting") == ["擋:firebase 部署"])
        #expect(names("xcodebuild -scheme App archive -archivePath /tmp/a") == ["擋:App 封裝／上傳 App Store Connect"])
        #expect(names("xcrun altool --upload-app -f a.ipa") == ["擋:App 封裝／上傳 App Store Connect"])
        // 10-24 隊長：Sam 的上傳漏擋（BM7NC 之後）
        for c in ["xcodebuild -exportArchive -archivePath /tmp/A.xcarchive -exportOptionsPlist opts.plist -exportPath /tmp/out",
                  "cd 專案A && xcodebuild -exportArchive -archivePath build/A.xcarchive -exportOptionsPlist ExportOptions.plist",
                  "xcrun altool --upload-package a.pkg --apple-id 1",
                  "xcrun notarytool submit a.zip --wait",
                  "/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter -m upload -f a.itmsp",
                  "bundle exec fastlane ios pilot upload", "fastlane deliver"] {
            #expect(names(c) == ["擋:App 封裝／上傳 App Store Connect"], "\(c)")
        }
        #expect(names("xcodebuild -scheme 專案A build").isEmpty && names("xcodebuild -showBuildSettings").isEmpty)
        #expect(names("python3 line_send.py 小明 '晚上見'") == ["擋:LINE 對外傳訊（line_send.py）"])
        #expect(names("defaults write com.acme.app key -bool true") == ["告:改系統設定（defaults write）"])
        #expect(names("cp a.py ~/.claude/scripts/a.py") == ["告:寫入 ~/.claude/scripts 或 data"])
        #expect(names("cat ~/.claude/scripts/a.py").isEmpty)
        #expect(names("ssh winbox 'Set-ItemProperty HKCU:\\X -Name Y -Value 1'") == ["告:遠端 Windows 寫入（ssh winbox）"])
        #expect(names("ssh winbox 'Get-ChildItem C:\\'").isEmpty)
        #expect(names("ls -la && swift build").isEmpty)
        // 指令層級才算：引號內、python -c、JSON 字串裡的關鍵字不算
        #expect(names("echo 'rm -rf /' | grep rm").isEmpty)
        #expect(names("python3 -c \"import os; os.system('defaults write x y')\"").isEmpty)
        #expect(names("cd 專案A && sudo rm -rf build") == ["擋:rm 刪除（暫存區以外）"])
        #expect(names("X=1 defaults write ai.acme.demo k -int 1") == ["告:改系統設定（defaults write）"])
        #expect(names("echo hi > ~/.claude/data/demo.json") == ["告:寫入 ~/.claude/scripts 或 data"])
        #expect(names("ls $(rm -rf build)") == ["擋:rm 刪除（暫存區以外）"])
        // 變數設成暫存路徑後的 rm／mv 不擋
        #expect(names("T=$(mktemp -d); touch $T/a; rm -rf $T").isEmpty)
        #expect(names("S=/private/tmp/claude-501/x/scratchpad/legs && rm -f $S/*.png").isEmpty)
        #expect(names("D=\"$TMPDIR/demo\"; mv a.txt \"$D/\"").isEmpty)
        #expect(names("T=$(mktemp -d); rm -rf $T ~/專案A") == ["擋:rm 刪除（暫存區以外）"])
        // BJ6M2：引號包住的暫存路徑＋重導向
        #expect(names("rm -rf \"/tmp/WT\" 2>/dev/null").isEmpty)
        #expect(names("rm -rf '/private/tmp/WT' >/dev/null 2>&1").isEmpty)
        #expect(names("mv a.txt \"/tmp/WT/\" 2>/dev/null").isEmpty)
        #expect(names("rm -rf ~/專案A 2>/dev/null") == ["擋:rm 刪除（暫存區以外）"])
        #expect(names("mv a.txt ~/專案A/ 2>/dev/null") == ["擋:mv 到非暫存區"])
    }

    @Test("② showork 自己的指令不看；串接時摘要只列命中的那段（BR9R8）")
    func hitSegment() {
        #expect(names("\"/Users/demo/Library/Application Support/ShoWork42/bin/showork\" card --kind start --how \"改 line_send.py 的 rm 判斷\"").isEmpty)
        #expect(names("showork b1 post --text \"mv 前先備份\"").isEmpty)
        let br9r8 = #""/Users/demo/Library/Application Support/ShoWork42/bin/showork" card --kind start --doing "傳訊" --how "line_send.py 傳給小明" && python3 ~/demo/line_send.py 小明 '晚上見'"#
        let hs = CaptainLink.hits(br9r8, rules: CaptainLink.defaultRules)
        #expect(hs.map(\.rule.name) == ["LINE 對外傳訊（line_send.py）"])
        let sum = CaptainLink.hitSummary(br9r8, hs)
        #expect(sum.hasPrefix("python3 ~/demo/line_send.py ‹訊息內容略›") && !sum.contains("showork") && !sum.contains("晚上見"))
    }

    @Test("② 隊長收集的誤擋樣本（10-24）：都不算")
    func falsePositives() {
        // 1. 讀收件匣 json 的指令：印出的內容裡有 defaults write／~/.claude/scripts／ssh winbox 字樣
        let inboxRead = #"D="/Users/demo/Library/Application Support/ShoWork42/board/captain-inbox"; for f in "$D"/*.json; do python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['id'],d['kind'],d['delivered'],d['text'][:50])" "$f"; done; B="/Users/demo/Library/Application Support/ShoWork42/bin/showork"; SID=demo; for c in "defaults write ai.okle42.demo key -bool true" "cp /tmp/demo.py ~/.claude/scripts/demo.py" "ssh winbox 'Remove-Item C:\demo\x.txt'"; do printf '%s' "{"session_id":"$SID","tool_input":{"command":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$c")}}" | "$B" guard-push; echo "rc=$?"; done"#
        #expect(names(inboxRead).isEmpty)
        // 2. BKZQP：build＋測試指令，測試樣本放在 JSON 字串裡，結尾清 mktemp 的暫存
        let bkzqp = #"cd ~/github-repos/ShoWork42 && swift build 2>&1 | grep -E "error|Build comp"; T=/private/tmp/claude-501/demo/scratchpad/rel; mkdir -p $T; export SHOWORK_CAPTAIN_INBOX=$T/inbox; B=.build/debug/showork; J="{"session_id":"x","tool_input":{"command":"rm -rf ~/demo-release-test"}}"; echo "$J" | $B guard-push | grep -o '單號 B[A-Z0-9]*' | head -1; rm -rf $T"#
        #expect(names(bkzqp).isEmpty)
        // 3. B2AQJ：安裝＋同一條裡又帶測試 JSON 樣本
        let b2aqj = #"cd ~/github-repos/ShoWork42 && SHOWORK_DEBUG=1 python3 scripts/showork_install.py install 2>&1 | tail -1; head -2 "/Users/demo/Library/Application Support/ShoWork42/board/guard/preview.tsv" | cut -c1-60; T=/private/tmp/claude-501/demo/scratchpad/rel; mkdir -p $T; export SHOWORK_CAPTAIN_INBOX=$T/inbox SHOWORK_RELEASE_LOG=$T/releases.jsonl; B=.build/debug/showork; SID=demo; J="{"session_id":"$SID","cwd":"/tmp","tool_input":{"command":"rm -rf ~/demo-release-test"}}"; echo "1 擋下：$(echo "$J" | $B guard-push | grep -o '單號 B[A-Z0-9]*' | head -1)"; echo "5 紀錄：$(cat $T/releases.jsonl)""#
        #expect(names(b2aqj).isEmpty)
    }

    @Test("② 設定檔解析；摘要遮長字串、LINE 不帶內容")
    func parseAndSummary() {
        let r = CaptainLink.parseRules("# 註解\n小明規則\t擋\t\\bfoo\\b\n壞行\n預告\t告\tbar\n")
        #expect(r == [CaptainLink.Rule(name: "小明規則", block: true, pattern: "\\bfoo\\b"), CaptainLink.Rule(name: "預告", block: false, pattern: "bar")])
        #expect(CaptainLink.summary("curl -H 'X: abcdefghijklmnopqrstuvwxyz0123456789ABCD' x") == "curl -H 'X: ‹長字串›' x")
        #expect(CaptainLink.summary("python3 ~/s/line_send.py 小明 '這是私人訊息'") == "python3 ~/s/line_send.py ‹訊息內容略›")
        #expect(CaptainLink.fingerprint("rm a ") == CaptainLink.fingerprint("rm a") && CaptainLink.fingerprint("rm a") != CaptainLink.fingerprint("rm b"))
    }

    func item(_ id: String, _ kind: CaptainInboxItem.Kind, sid: String, at: Date, fp: String? = nil) -> CaptainInboxItem {
        CaptainInboxItem(id: id, kind: kind, at: at, sid: sid, name: "小明", project: "專案A", kinds: ["rm 刪除（暫存區以外）"], text: "rm -rf build", fingerprint: fp)
    }

    @Test("③ 預告合併：同一 session 安靜 5 秒或等滿 30 秒才送；已送、太舊的不送")
    func merge() {
        let a1 = item("N1", .notice, sid: "a", at: t0), a2 = item("N2", .notice, sid: "a", at: t0 + 3), b1 = item("N3", .notice, sid: "b", at: t0 + 1)
        #expect(CaptainLink.dueNotices([a1, a2, b1], now: t0 + 4).isEmpty)
        let due = CaptainLink.dueNotices([a1, a2, b1], now: t0 + 8.5)
        #expect(due.map { $0.map(\.id) } == [["N1", "N2"]] || due.map { $0.map(\.id) } == [["N1", "N2"], ["N3"]])
        let chatty = (0..<16).map { item("C\($0)", .notice, sid: "c", at: t0 + Double($0) * 2) }
        #expect(CaptainLink.dueNotices(chatty, now: t0 + 31).first?.count == 16)           // 一直有新的：滿 30 秒也送
        var sent = a1; sent.delivered = true
        #expect(CaptainLink.dueNotices([sent, item("N9", .notice, sid: "a", at: t0 - 700)], now: t0 + 10).isEmpty)
        let t = CaptainLink.noticeText([a1, a2])
        #expect(t.hasPrefix("【動作預告】小明（專案A）：2 個動作") && t.components(separatedBy: "・rm").count == 3)
    }

    @Test("④ 收件匣：擋下 → 放行（寫稽核紀錄）→ 同一個指令用一次")
    func inbox() throws {
        LocalFixture.use()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capinbox-\(UUID().uuidString)")
        setenv("SHOWORK_CAPTAIN_INBOX", dir.appendingPathComponent("inbox").path, 1)
        setenv("SHOWORK_RELEASE_LOG", dir.appendingPathComponent("releases.jsonl").path, 1)
        defer { unsetenv("SHOWORK_CAPTAIN_INBOX"); unsetenv("SHOWORK_RELEASE_LOG"); try? FileManager.default.removeItem(at: dir) }
        let fp = CaptainLink.fingerprint("rm -rf build")
        CaptainInbox.save(item("BAAAA", .block, sid: "a", at: t0, fp: fp))
        #expect(!CaptainInbox.consume(sid: "a", fingerprint: fp, now: t0 + 10))                     // 還沒放行
        #expect(CaptainInbox.waiting(sid: "a", fingerprint: fp)?.id == "BAAAA")
        #expect(CaptainInbox.pending(now: t0 + 10).map(\.id) == ["BAAAA"])
        #expect(CaptainInbox.release(id: "bzzzz", target: nil, by: "cap", byName: "隊長", source: "release 指令", now: t0 + 20) == nil)
        #expect(CaptainInbox.release(id: nil, target: "b", by: "b", byName: "使用者", source: "使用者輸入", now: t0 + 20) == nil)   // 別人的單不能放
        let r = try #require(CaptainInbox.release(id: "baaaa", target: nil, by: "cap", byName: "隊長", source: "release 指令", now: t0 + 20))
        #expect(r.released == t0 + 20)
        #expect(!CaptainInbox.consume(sid: "a", fingerprint: CaptainLink.fingerprint("rm -rf src"), now: t0 + 30))   // 換指令不算
        #expect(CaptainInbox.consume(sid: "a", fingerprint: fp, now: t0 + 30))
        #expect(!CaptainInbox.consume(sid: "a", fingerprint: fp, now: t0 + 40))                      // 只能用一次
        let log = CaptainInbox.releases()
        #expect(log.count == 1 && log[0].id == "BAAAA" && log[0].by == "cap" && log[0].source == "release 指令" && log[0].target == "a")
        CaptainInbox.save(item("BBBBB", .block, sid: "a", at: t0, fp: fp))
        _ = CaptainInbox.release(id: nil, target: "a", by: "a", byName: "使用者", source: "使用者輸入", now: t0 + 50)
        #expect(!CaptainInbox.consume(sid: "a", fingerprint: fp, now: t0 + 50 + 1801))               // 30 分鐘過期
        CaptainInbox.save(item("BCCCC", .block, sid: "a", at: t0 + 60, fp: "x"))
        #expect(CaptainInbox.pending(now: t0 + 70).contains { $0.id == "BCCCC" })
        #expect(CaptainInbox.ack("bcccc", now: t0 + 70) == 1 && !CaptainInbox.pending(now: t0 + 70).contains { $0.id == "BCCCC" })
        CaptainInbox.save(item("BDDDD", .block, sid: "a", at: t0 + 60, fp: "y"))
        #expect(CaptainInbox.ack("all", now: t0 + 80) >= 1 && CaptainInbox.pending(now: t0 + 80).isEmpty)
        #expect(CaptainLink.denyReason(r).contains("隊長轉述小明的決定") && CaptainLink.blockText(r).contains("showork release BAAAA"))
    }

    @Test("⑤ 鬧鐘：名冊一行摘要；沒變化同指紋")
    func alarm() {
        func e(_ n: String, ctx: Int?, idle: Double, cap: Bool = false) -> RosterEntry {
            RosterEntry(name: n, sessionId: n, pid: 1, kind: nil, project: "專案A", root: nil, column: .done, reason: "", title: "", summary: nil,
                        ctx: ctx, lastActivity: t0 - idle, captain: cap, sameProject: [])
        }
        let r = Roster(at: t0, captain: "隊長", entries: [e("小明", ctx: 62, idle: 60), e("ACME", ctx: nil, idle: 3600), e("隊長", ctx: 10, idle: 0, cap: true)])
        let a = CaptainLink.alarm(r, pending: 2, now: t0)
        #expect(a.text.hasPrefix("【巡檢時間】在線 2 人（不含隊長）；ctx：ACME –、小明 62%；閒置超過 30 分鐘：ACME；收件匣未處理 2 則"))
        #expect(CaptainLink.alarm(r, pending: 2, now: t0 + 5).sig == a.sig)
        #expect(CaptainLink.alarm(r, pending: 3, now: t0).sig != a.sig)
    }

    @Test("② 開工卡轉送：同一個任務 10 分鐘內不重送")
    func startDedupe() {
        var st = CardRelay.State(); st.seeded = true
        func start(_ d: String, _ s: String, _ at: Date) -> SelfReport { SelfReport(status: .working, summary: s, doing: d, kind: "start", at: at) }
        let txt: (String, SelfReport) -> String = { _, r in r.summary ?? "" }
        #expect(CardRelay.plan(reports: ["a": start("改按鈕", "1", t0)], captain: "c", captainLive: true, state: &st, now: t0, text: txt).count == 1)
        #expect(CardRelay.plan(reports: ["a": start("改按鈕", "2", t0 + 60)], captain: "c", captainLive: true, state: &st, now: t0 + 60, text: txt).isEmpty)
        #expect(CardRelay.plan(reports: ["a": start("換新任務", "3", t0 + 70)], captain: "c", captainLive: true, state: &st, now: t0 + 70, text: txt).count == 1)
    }
}
