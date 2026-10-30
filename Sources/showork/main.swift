// showork — the tiny command every adapter calls.
//   showork emit <working|done|input|clear> [--agent claude] [--tty /dev/ttysNNN] [--pid N]
//   showork brief          SessionStart hook：印出給 AI 的戰情中心說明
//   showork card --status … AI 每輪自報（完成度／信心度／要你決定的事），存給戰情中心
//   showork names          活著的 session：英文名、SendMessage 地址、正在做的任務
//   showork title [--done]  hook：回傳 terminalSequence，把視窗標題改成「英文名-任務」
//   showork permit         PermissionRequest hook：等你在戰情中心收件匣按允許／拒絕（會讀 stdin、最久等 1 小時）
//   showork guard-push     PreToolUse(Bash) hook：1 樓保全在 git push 之前檢查（擋 ghosts／old-history／金鑰⋯，規則在 PushGuard.swift）
//   showork captain        把目前這個 session 設成隊長，印出隊長守則
//   showork roster [--json]  名冊：每個 session 的名字、專案、在做什麼、重工警告
//   showork task add --to <英文名，例如 Chris> --text "…"   建派工單，印出要用 SendMessage 送的全文
//   showork task cancel <單號>    showork tasks [--all]
//
// Contract with the AI tools that call us (hooks): this must NEVER slow them down or fail them.
//   • always exits 0, prints nothing on success
//   • gives up after 200 ms if the agent isn't there
//   • never reads stdin (hook JSON may be large; we don't need it)
import Foundation
import Darwin
import ShoWorkCore

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: showork emit <working|done|input|clear> [--agent NAME] [--tty PATH]\n".utf8))
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
nonisolated(unsafe) var permitReqPath: UnsafePointer<CChar>?   // SIGTERM 時刪請求檔

// 戰情中心：`showork brief`（SessionStart hook 印給 AI 的說明）、`showork card …`（AI 每輪的自報）
// 審核員自己（SHOWORK_REVIEWER=1）不參與，免得審核也上看板、也被要求自報。
// `claude -p` 這類無頭呼叫（審核員、熬夜秘書的自動回覆⋯）CLAUDE_CODE_ENTRYPOINT 是 sdk-*，不上看板也不用自報
let isReviewer = ProcessInfo.processInfo.environment["SHOWORK_REVIEWER"] != nil
    || (ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"] ?? "").hasPrefix("sdk")
if args.first == "brief" {
    if !isReviewer {
        var sid = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        // 自動接手（Handover.swift ③）：hook JSON 的 session_id／source／cwd；/clear 後 sid 會換，以 JSON 為準
        var source: String?, cwdPath: String?
        if isatty(0) == 0, let o = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readData(ofLength: 1 << 20)) as? [String: Any] {
            sid = (o["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sid
            source = o["source"] as? String
            cwdPath = o["cwd"] as? String
        }
        if let sid, let ctx = Handover.claim(sid: sid, pid: Handover.claudePID(), cwd: cwdPath, source: source) {
            print(ctx)
        }
        print(CardRules.brief(showork: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
                              name: sid.map { NicknameStore.ensure($0).name }))
    }
    exit(0)
}
if args.first == "card" {
    if isReviewer { exit(0) }
    let env = ProcessInfo.processInfo.environment
    guard let sid = env["CLAUDE_CODE_SESSION_ID"], !sid.isEmpty else {
        FileHandle.standardError.write(Data("showork card：找不到 CLAUDE_CODE_SESSION_ID（要在 Claude Code 裡跑）\n".utf8)); exit(1)
    }
    switch SelfReport.parse(args: Array(args.dropFirst())) {
    case .failure(let e):
        FileHandle.standardError.write(Data("showork card：\(e.message)\n".utf8)); exit(1)
    case .success(let r):
        let dir = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = BoardJSON.encoder
        guard let d = try? e.encode(r), (try? d.write(to: dir.appendingPathComponent(sid + ".json"), options: .atomic)) != nil else {
            FileHandle.standardError.write(Data("showork card：寫不進 \(dir.path)\n".utf8)); exit(1)
        }
        if let id = r.task {
            if var t = CaptainStore.task(id) { t.apply(r); CaptainStore.save(t) }
            else { FileHandle.standardError.write(Data("showork card：找不到派工單 \(id)（自報已存）\n".utf8)) }
        }
        if r.isStart {     // 開工卡也進隊長收件匣（看板轉送成功才標已送；新隊長 showork captain 會看到沒送到的）
            CaptainInbox.save(CaptainInboxItem(id: CaptainInbox.newID(.start), kind: .start, at: r.at, sid: sid, name: NicknameStore.ensure(sid).name,
                                               project: CaptainStore.roster()?.entries.first { $0.sessionId == sid }?.project,
                                               text: [r.doing, r.summary].compactMap { $0 }.joined(separator: "：")))
        }
        if r.isWrapup, let h = r.handoff {   // 收尾完（Handover.swift ②）：看板等它閒下來送 /clear
            let pid = Handover.claudePID() ?? 0
            let cwd = NicknameStore.liveSessions().first { $0.sessionId == sid }?.cwd ?? FileManager.default.currentDirectoryPath
            Handover.save(HandoverRecord(sid: sid, pid: pid, cwd: cwd, name: NicknameStore.ensure(sid).name, handoff: h, summary: r.summary, at: r.at))
        }
        let n = NicknameStore.update(sid, doing: r.doing)
        if r.isWrapup { print("ok（\(n.name)：已登記交接，停下來後看板會自動 /clear，新 context 自動接手）"); exit(0) }
        print(r.doing == nil ? "ok（\(n.name)：沒帶 --doing，卡片標題的任務沒更新）" : "ok（\(n.name)-\(n.doing ?? "")）")
        exit(0)
    }
}

// hook：把 Ghostty 視窗標題改成「英文名-正在做的任務」（UserPromptSubmit／PostToolUse＝工作中，Stop＝做完）。
// 這個子指令要讀 stdin 的 hook JSON 拿 session_id（環境變數有就不讀）；還沒取名的 session 不輸出，標題照 Claude 原本的。
if args.first == "title" {
    if isReviewer { exit(0) }
    let done = args.contains("--done")
    var sid = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
    var event: String?, prompt: String?, cwdPath: String?
    if isatty(0) == 0, let o = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readData(ofLength: 1 << 20)) as? [String: Any] {
        sid = sid ?? o["session_id"] as? String
        event = o["hook_event_name"] as? String
        prompt = o["prompt"] as? String
        cwdPath = o["cwd"] as? String
    }
    // 開工卡（T1024033803 ①）：使用者直接下的指令 ⇒ 提醒動手前先發；隊長自己不用（隊長只審不做）；local.json 的 noKickoffRepos（例如秘書）不發
    //   距上一道使用者指令超過 10 分鐘＝完整提醒；10 分鐘內＝只在換了任務時才發
    //   使用者打「放行」／「放行 <單號>」＝放行這個 session 被擋下的指令（寫 board/permits/releases.jsonl）
    // 收尾後只有使用者本人又下指令才不自動 /clear；其他 session／看板的訊息回一段「交接中」提醒（T1026230337）
    let handoverNote = event == "UserPromptSubmit" ? sid.flatMap { Handover.noteNewPrompt(sid: $0, prompt: prompt) } : nil
    let startNag: String? = {
        guard event == "UserPromptSubmit", let sid, CaptainLink.needsStart(prompt: prompt) else { return nil }
        let p = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("放行") {
            let id = p.dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
            let who = NicknameStore.get(sid)?.name ?? "使用者"
            if let i = CaptainInbox.release(id: id, target: sid, by: sid, byName: "使用者（在 \(who) 的終端機）", source: "使用者輸入", now: Date()) {
                if let cap = CaptainStore.captain(), cap.sessionId != sid, let to = Peer.find(cap.sessionId) {
                    _ = Peer.send(to: to, text: "【已放行 \(i.id)】使用者在 \(who) 的終端機放行：\(i.text)", fromName: "AI工作戰情中心（動作預告）")
                }
                return "使用者剛放行了單號 \(i.id)（\(i.text)）。現在可以再跑一次剛才被擋下的同一個指令（30 分鐘內有效、只能用一次）。"
            }
            return nil
        }
        guard CaptainStore.captain()?.sessionId != sid, !LocalConfig.current.skipsKickoff(cwd: cwdPath ?? "") else { return nil }
        let last = CaptainLink.lastPrompt(sid)
        CaptainLink.touchPrompt(sid)
        let showork = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        if let last, Date().timeIntervalSince(last) < CaptainLink.newTaskGap {
            return CaptainLink.sameTaskContext(showork: showork, doing: NicknameStore.get(sid)?.doing)
        }
        return CaptainLink.startContext(showork: showork)
    }()
    let context = [startNag, handoverNote].compactMap { $0 }.joined(separator: "\n")
    let ctx: String? = context.isEmpty ? nil : context
    if let sid, NicknameStore.get(sid) == nil, let ctx {
        print(Nicknames.hookOutput(nil, done: done, event: event, context: ctx))
    }
    if let sid, let n = NicknameStore.get(sid) {
        NicknameStore.touch(sid)
        print(Nicknames.hookOutput(n, done: done, event: event, context: ctx))
        // 做完時 Claude Code 會在 Stop hook 之後把標題改回它自己的 session 標題（10-19 實測：Dora 一閒下來就變回「✳ Handoff 88」），
        // 所以 1.5 秒後直接寫一次 OSC 0 到這個 session 的 tty；閒置時 Claude 不會再動標題
        if done, let tty = TTYFinder.find()?.tty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", #"sleep 1.5; printf '\033]0;%s\007' "$SW_TITLE" > "$SW_TTY""#]
            p.environment = ["SW_TITLE": Nicknames.terminalTitle(n, done: true), "SW_TTY": tty]
            p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }
    exit(0)
}

/// guard-push 用：跑外部指令拿輸出（git、gh）
func hookRun(_ exe: String, _ a: [String], dir: String?, timeout: Double? = nil) -> (code: Int32, out: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = a
    if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (127, "") }
    if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } } }   // gh 卡網路 ⇒ 判不出來＝擋
    let d = pipe.fileHandleForReading.readDataToEndOfFile()     // 先讀完再等，免得輸出塞滿管子卡住
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
func hookGit(_ dir: String, _ a: [String]) -> (code: Int32, out: String) { hookRun("/usr/bin/git", ["-C", dir] + a, dir: nil) }

/// 動作預告命中「GitHub 公開發言」時細判：目標全是 Okle42 私有 repo ⇒ 從 hs 拿掉、回 nil；否則留著、回擋的原因（GHGuard）
func ghExempt(_ hs: inout [(rule: CaptainLink.Rule, segment: String)], _ cmd: String, cwd: String) -> String? {
    guard let i = hs.firstIndex(where: { $0.rule.name == GHGuard.ruleName }) else { return nil }
    let why = GHGuard.blockReason(cmd, cwd: cwd, rule: hs[i].rule, git: hookGit, view: { repo in
        let r = hookRun("/opt/homebrew/bin/gh", ["repo", "view", repo, "--json", "isPrivate,owner"], dir: nil, timeout: 8)
        guard r.code == 0, let j = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
              let priv = j["isPrivate"] as? Bool, let owner = (j["owner"] as? [String: Any])?["login"] as? String else { return nil }
        return (owner, priv)
    })
    if why == nil { hs.remove(at: i) }
    return why
}

// PreToolUse(Bash) hook：1 樓保全的 push 守門（規則在 ShoWorkCore/PushGuard.swift）。不是 git push 就馬上安靜離開。
// 同一個 hook 也做隊長連動②「動作預告」：高風險指令執行前通知隊長（不阻擋，規則在 ShoWorkCore/CaptainLink.swift）
if args.first == "guard-push" {
    guard isatty(0) == 0, let o = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
          let cmd = (o["tool_input"] as? [String: Any])?["command"] as? String else { exit(0) }
    if !isReviewer, let sid = o["session_id"] as? String, CaptainStore.captain()?.sessionId != sid {   // 隊長自己不擋不預告（隊長只審不做）
        var hs = CaptainLink.hits(cmd, rules: CaptainLink.loadRules())
        let ghWhy = ghExempt(&hs, cmd, cwd: o["cwd"] as? String ?? FileManager.default.currentDirectoryPath)
        let hits = hs.map(\.rule)
        if !hits.isEmpty {
            let now = Date(), fp = CaptainLink.blockFingerprint(cmd, rules: hs.map(\.rule))
            let project = CaptainStore.roster()?.entries.first { $0.sessionId == sid }?.project
            let name = NicknameStore.get(sid)?.name ?? String(sid.prefix(8))
            let blocks = hits.filter(\.block), notices = hits.filter { !$0.block }
            // 放行單只查一次：consume 會把單記成已用，兩個分支各查一次的話，第一次用掉、第二次查不到又開新單（B3PZF→BQYPM）
            let released = !blocks.isEmpty && CaptainInbox.consume(sid: sid, fingerprint: fp, now: now)
            if !blocks.isEmpty, !released,
               let pre = CaptainInbox.usePreapproval(sid: sid, rules: blocks.map(\.name), now: now) {
                // 戰情中心回答已點名這個動作＝事先放行：記成已放行＋已用、通知隊長，照常往下跑
                let base = CaptainInbox.waiting(sid: sid, fingerprint: fp) ?? CaptainInboxItem(id: CaptainInbox.newID(.block), kind: .block, at: now, sid: sid, name: name,
                                                                                               project: project, kinds: hits.map(\.name), text: CaptainLink.hitSummary(cmd, hs), fingerprint: fp)
                var item = CaptainInbox.releaseByAnswer(base, answer: pre, now: now)
                if let cap = CaptainStore.captain(), let to = Peer.find(cap.sessionId),
                   case .success = Peer.send(to: to, text: "【已放行 \(item.id)】\(CaptainLink.label(name, project))：使用者在戰情中心回答「\(pre.answer)」已點名這個動作・\(item.text)", fromName: "AI工作戰情中心（動作預告）") {
                    item.delivered = true; CaptainInbox.save(item)
                }
            } else if !blocks.isEmpty, !released {
                // 擋下等放行：同一個指令重試不再開新單；第一次立即送隊長（不在線就留在收件匣）
                var item = CaptainInbox.waiting(sid: sid, fingerprint: fp) ?? CaptainInboxItem(id: CaptainInbox.newID(.block), kind: .block, at: now, sid: sid, name: name,
                                                                                               project: project, kinds: hits.map(\.name), text: CaptainLink.hitSummary(cmd, hs) + (ghWhy.map { "（\($0)）" } ?? ""), fingerprint: fp)
                if !item.delivered, let cap = CaptainStore.captain(), let to = Peer.find(cap.sessionId),
                   case .success = Peer.send(to: to, text: CaptainLink.blockText(item), fromName: "AI工作戰情中心（動作預告）") { item.delivered = true }
                CaptainInbox.save(item)
                let o: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": CaptainLink.denyReason(item)]]
                print(String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self))
                exit(0)
            }
            // 不擋的：先進收件匣，看板把同一 session 一小段時間內的合成一則送（CaptainLink.dueNotices）
            if !notices.isEmpty {
                CaptainInbox.save(CaptainInboxItem(id: CaptainInbox.newID(.notice), kind: .notice, at: now, sid: sid, name: name, project: project,
                                                   kinds: notices.map(\.name), text: CaptainLink.hitSummary(cmd, hs.filter { !$0.rule.block })))
            }
        }
    }
    guard cmd.contains("push") else { exit(0) }
    let calls = PushGuard.calls(command: cmd, cwd: o["cwd"] as? String ?? FileManager.default.currentDirectoryPath)
    if calls.isEmpty { exit(0) }
    let git: PushGuard.Git = hookGit
    let sid = o["session_id"] as? String
    let kw = PushGuard.list(PushGuard.dir.appendingPathComponent("keywords.txt"))
    let strict = PushGuard.list(PushGuard.dir.appendingPathComponent("strict-repos.txt"))
    var evs: [PushEvent] = []
    for c in calls {
        var e = PushGuard.check(c, git: git, keywords: kw, strict: strict)
        e.session = sid; e.name = sid.flatMap { NicknameStore.get($0)?.name }
        if e.verdict == .block {
            let xs = PushGuard.allows()
            let rest = PushGuard.apply(&e, allows: xs, now: Date())
            if rest != xs { PushGuard.saveAllows(rest) }
        }
        PushGuard.append(e)
        evs.append(e)
    }
    if let out = PushGuard.hookOutput(evs) { print(out) }
    exit(0)
}

// 動作預告的分類試算（不擋、不送、不寫檔；改 preview.tsv 後驗規則用）：showork preview-check "<指令>"
if args.first == "preview-check" {
    for c in args.dropFirst() {
        var hs = CaptainLink.hits(c, rules: CaptainLink.loadRules())
        let gh = ghExempt(&hs, c, cwd: FileManager.default.currentDirectoryPath)
        print((hs.isEmpty ? "不擋" : hs.map { ($0.rule.block ? "擋：" : "告：") + $0.rule.name }.joined(separator: "、")) + "\t" + (hs.isEmpty ? CaptainLink.summary(c) : CaptainLink.hitSummary(c, hs)) + (gh.map { "（\($0)）" } ?? ""))
    }
    exit(0)
}

// PermissionRequest hook：把要求寫給戰情中心，等你在收件匣按「允許／一律允許／拒絕」（規則與實測在 ShoWorkCore/Permit.swift）。
// 終端機的對話框照常出現；先在終端機答了、AI 結束、等超過一小時，就安靜離開（不回 decision，交還給終端機）。
if args.first == "permit" {
    if isReviewer || isatty(0) != 0 { exit(0) }
    guard let o = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
          // AskUserQuestion／ExitPlanMode 也走這條：收件匣顯示題目選項／計畫內容，回答時改 updatedInput（10-25，Permit.swift）。
          // 10-22 曾因為收件匣只會顯示「要用 AskUserQuestion，可以嗎？」＋一坨 JSON 而排除
          let req = Permit.request(hook: o, pid: TTYFinder.find()?.pid), Permit.write(req) else { exit(0) }
    let reqPath = strdup(Permit.requestURL(req.id).path)!
    signal(SIGTERM) { _ in if let p = permitReqPath { unlink(p) }; _exit(0) }
    permitReqPath = UnsafePointer(reqPath)
    let input = o["tool_input"] as? [String: Any] ?? [:]
    // 終端機先答了沒：看 transcript 出現這個 tool_use 的 tool_result。新 session 第一次跳權限時檔案可能還沒寫出來（10-21 實測），每輪重試開檔；
    // 開得到時就在的內容只用來找 tool_use id，「任何 tool_result 都算」的退路只看 hook 開始之後新增的
    let tpath = o["transcript_path"] as? String
    var transcript: FileHandle?
    var seen = Data(), fresh = Data()
    var offset: UInt64 = 0
    var useId: String?
    let start = Date()
    while Date().timeIntervalSince(start) < Permit.maxWait {
        if let a = Permit.readAnswer(req.id) {
            print(Permit.hookOutput(a, request: req))
            Permit.remove(req.id); exit(0)
        }
        if !FileManager.default.fileExists(atPath: Permit.requestURL(req.id).path) { exit(0) }
        if let p = req.pid, kill(p, 0) != 0, errno == ESRCH { break }
        if transcript == nil, let tpath, let t = FileHandle(forReadingAtPath: tpath) {
            transcript = t
            let end = t.seekToEndOfFile(), from = end > 2 << 20 ? end - (2 << 20) : 0
            t.seek(toFileOffset: from)
            seen = t.readData(ofLength: Int(end - from)); offset = end
        }
        if let t = transcript {
            let end = t.seekToEndOfFile()
            if end > offset {
                t.seek(toFileOffset: offset)
                let d = t.readData(ofLength: Int(end - offset))
                offset = end; seen.append(d); fresh.append(d)
                if seen.count > 4 << 20 { seen = seen.suffix(2 << 20) }
            }
            if useId == nil { useId = Permit.toolUseId(transcript: seen, tool: req.tool, input: input) }
            if let id = useId, Permit.resolved(appended: seen, toolUseId: id) { break }      // 終端機那邊答了
            if useId == nil, Date().timeIntervalSince(start) > 5, Permit.resolved(appended: fresh, toolUseId: nil) { break }
        }
        usleep(400_000)
    }
    Permit.remove(req.id)
    exit(0)
}

if args.first == "names" {
    let names = NicknameStore.all()
    let rows = NicknameStore.liveSessions().sorted { (names[$0.sessionId]?.name ?? "~") < (names[$1.sessionId]?.name ?? "~") }
    for r in rows where r.entrypoint != "sdk-cli" {
        let n = names[r.sessionId]
        print("\(n?.name ?? "（還沒取名）")\t\(r.name ?? "-")\t\(n?.doing ?? "（還沒報任務）")")
    }
    exit(0)
}

if args.first == "b1" {
    exit(B1CLI.run(args))
}

if ["captain", "roster", "task", "tasks", "release"].contains(args.first ?? "") {
    exit(CaptainCLI.run(args, showork: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path))
}

guard args.first == "emit", args.count >= 2, let event = WorkEvent(rawValue: args[1]) else { usage() }
args.removeFirst(2)

var agent = "generic"
var ttyOverride: String?
var pidOverride: Int32?
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--agent": agent = args.first ?? agent; if !args.isEmpty { args.removeFirst() }
    case "--tty": ttyOverride = args.first; if !args.isEmpty { args.removeFirst() }
    case "--pid": pidOverride = args.first.flatMap { Int32($0) }; if !args.isEmpty { args.removeFirst() }   // the AI process (liveness)
    default: break
    }
}

let found = ttyOverride.map { TTYFinder.Found(tty: $0, pid: getppid()) } ?? TTYFinder.find()
guard var found else { exit(0) }                       // not in a terminal: nothing to light up
if let p = pidOverride { found = TTYFinder.Found(tty: found.tty, pid: p) }
guard let line = try? WireMessage(event: event, tty: found.tty, agent: agent, pid: found.pid).encodedLine() else { exit(0) }

// Unix socket, non-blocking connect with a hard deadline.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let path = Paths.socket.path
guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    path.utf8.enumerated().forEach { buf[$0.offset] = $0.element }
}
let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
if rc != 0 {
    guard errno == EINPROGRESS else { close(fd); exit(0) }    // no agent running: fine
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, 200) == 1 else { close(fd); exit(0) }
}
line.withUnsafeBytes { _ = write(fd, $0.baseAddress, line.count) }
close(fd)
exit(0)
