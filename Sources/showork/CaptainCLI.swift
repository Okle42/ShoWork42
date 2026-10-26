import Foundation
import ShoWorkCore

// 隊長派工的指令（給隊長 AI 用；人也可以直接跑）。名冊來自 agent 每 1.5 秒寫的 roster.json。
enum CaptainCLI {
    static func out(_ s: String) { print(s) }
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static var mySession: String? { ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 } }

    /// ~/.claude/sessions/*.json 裡找自己的 session 名
    static func sessionName(_ sid: String) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/sessions"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".json") {
            if let d = FileManager.default.contents(atPath: dir + "/" + f), let r = SessionRecord.decode(d), r.sessionId == sid { return r.name }
        }
        return nil
    }

    static func run(_ args: [String], showork: String) -> Int32 {
        var a = Array(args.dropFirst())
        switch args.first {
        case "captain":
            guard let sid = mySession else { err("showork captain：要在 Claude Code 裡跑（找不到 CLAUDE_CODE_SESSION_ID）"); return 1 }
            if a.first == "ack" {      // 隊長處理過的收件匣單標已讀（鬧鐘的「未處理」只算沒 ack 的）
                guard CaptainStore.captain()?.sessionId == sid else { err("只有現任隊長能 ack 收件匣"); return 1 }
                guard a.count >= 2 else { err("用法：showork captain ack <單號｜all>"); return 1 }
                let n = a.dropFirst().reduce(0) { $0 + CaptainInbox.ack($1, now: Date()) }
                out(n == 0 ? "沒有符合的未處理單" : "已標 \(n) 筆為已處理"); return 0
            }
            CaptainStore.setCaptain(CaptainRecord(sessionId: sid, name: sessionName(sid)))
            out(Captain.manual(showork: showork))
            // 收件匣裡還沒送到隊長的、還在等放行的（T1024033803 ④）：先印，印完標成已送
            let pend = CaptainInbox.pending(now: Date())
            if !pend.isEmpty {
                out("\n【收件匣未處理 \(pend.count) 則】（開工卡、動作預告、擋下等放行）")
                for var i in pend {
                    out("  " + i.line)
                    if !i.delivered { i.delivered = true; CaptainInbox.save(i) }
                }
            }
            return 0
        case "release":
            // 隊長放行被擋下的動作：只能用在 Kang 已經明說同意的事；每次都記在 board/permits/releases.jsonl
            guard let id = a.first else { err("用法：showork release <單號>（單號在【動作預告・擋下】那則訊息裡）"); return 1 }
            guard let sid = mySession, CaptainStore.captain()?.sessionId == sid else {
                err("只有現任隊長能放行。使用者要放行，請在被擋的那個 session 直接打「放行」。"); return 1
            }
            guard let i = CaptainInbox.release(id: id, target: nil, by: sid, byName: sessionName(sid) ?? "隊長", source: "release 指令", now: Date()) else {
                err("找不到等放行的單號 \(id)（打錯、已放行過、或超過 24 小時）"); return 1
            }
            out("已放行 \(i.id)：\(CaptainLink.label(i.name, i.project))・\(i.text)（30 分鐘內、限一次）")
            if let r = Peer.find(i.sid) {
                _ = Peer.send(to: r, text: "【已放行 \(i.id)】隊長轉述使用者的決定放行了：\(i.text)。現在可以再跑一次剛才被擋下的同一個指令（30 分鐘內、只能用一次）。", fromName: "AI工作戰情中心（動作預告）")
            }
            return 0
        case "roster":
            return roster(json: a.contains("--json"))
        case "tasks":
            return tasks(all: a.contains("--all"))
        case "task":
            let sub = a.isEmpty ? "" : a.removeFirst()
            switch sub {
            case "add": return add(a, showork: showork)
            case "cancel":
                guard let id = a.first, var t = CaptainStore.task(id) else { err("showork task cancel <單號>：找不到這張單"); return 1 }
                t.state = .cancelled; t.updatedAt = Date(); CaptainStore.save(t)
                let note = "【隊長取消 \(id)】這張派工不用做了：\(t.text.replacingOccurrences(of: "\n", with: " ").prefix(60))。已經做到一半的就停在安全的地方，回報目前狀態即可。"
                switch Peer.find(t.toSession ?? t.to).map({ Peer.send(to: $0, text: note, fromName: "AI工作戰情中心") }) {
                case .success?: out("已取消 \(id)，也通知 \(t.to) 不用做了")
                default: out("已取消 \(id)；通知 \(t.to) 失敗，請用 SendMessage 告訴它不用做了")
                }
                return 0
            default: err("用法：showork task add --to <英文名，例如 Chris> --text \"…\"｜showork task cancel <單號>"); return 1
            }
        default: return 1
        }
    }

    static func freshRoster() -> Roster? {
        guard let r = CaptainStore.roster() else { return nil }
        return r.at.timeIntervalSinceNow > -30 ? r : nil
    }

    static func roster(json: Bool) -> Int32 {
        guard let r = freshRoster() else { err("名冊沒有更新（AI工作戰情中心的常駐程式沒在跑？）：python3 scripts/showork_install.py status"); return 1 }
        if json {
            if let d = try? BoardJSON.encoder.encode(r) { out(String(decoding: d, as: UTF8.self)) }
            return 0
        }
        let rel = RelativeDateTimeFormatter(); rel.locale = Locale(identifier: "zh_TW"); rel.unitsStyle = .short
        let open = CaptainStore.tasks().filter { $0.state.open }
        for e in r.entries.sorted(by: { ($0.captain ? 0 : 1, $0.project) < ($1.captain ? 0 : 1, $1.project) }) {
            var head = "■ \(e.name)\(e.captain ? "（隊長）" : "")｜\(e.project)｜\(e.column.title)：\(e.reason)"
            if let c = e.ctx { head += "｜ctx \(c)%" }
            if e.kind == "bg" { head += "｜背景" }
            if let t = e.lastActivity { head += "｜\(rel.localizedString(for: t, relativeTo: Date()))" }
            out(head)
            out("  在做：\(e.title)")
            if let s = e.summary, !s.isEmpty { out("  最後：\(s.prefix(120))") }
            if let h = e.handover { out("  🔁 \(h)（自動交接；/clear 前不要派新工作給它）") }
            if !e.sameProject.isEmpty { out("  ⚠ 同專案還有：\(e.sameProject.joined(separator: "、"))（不要再派同專案的事給別人）") }
            for t in open where t.toSession == e.sessionId || t.to == e.name { out("  派工 \(t.id)［\(t.state.title)］\(t.text.prefix(60))") }
        }
        return 0
    }

    static func tasks(all: Bool) -> Int32 {
        let ts = CaptainStore.tasks().filter { all || $0.state.open || $0.updatedAt.timeIntervalSinceNow > -12 * 3600 }
        if ts.isEmpty { out("沒有派工單"); return 0 }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        for t in ts {
            out("\(t.id)［\(t.state.title)］→ \(t.to)\(t.project.map { $0.hasPrefix("（") ? $0 : "（\($0)）" } ?? "")｜派出 \(f.string(from: t.createdAt))｜更新 \(f.string(from: t.updatedAt))")
            out("  任務：\(t.text.replacingOccurrences(of: "\n", with: " ").prefix(100))")
            if let s = t.summary { out("  回報：\(s)") }
            if let q = t.ask { out("  要使用者決定：\(q)") }
        }
        return 0
    }

    static func add(_ args: [String], showork: String) -> Int32 {
        var a = args[...], to: String?, text: String?, thenTo: String?, thenText: String?
        while let k = a.popFirst() {
            guard let v = a.popFirst() else { err("\(k) 後面少了值"); return 1 }
            switch k {
            case "--to": to = v
            case "--text": text = v
            case "--then-to": thenTo = v
            case "--then": thenText = v
            default: err("不認得的參數 \(k)"); return 1
            }
        }
        guard let to, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            err("用法：showork task add --to <英文名，例如 Chris> --text \"…\" [--then-to <下一棒> --then \"…\"]"); return 1
        }
        if (thenTo == nil) != (thenText == nil) { err("--then-to 和 --then 要一起給"); return 1 }
        guard let from = mySession else { err("要在隊長的 Claude Code session 裡跑"); return 1 }
        let roster = freshRoster()
        // 短名（Chris）或全名都可以；名冊只有活著的 session，回收重用的名字自然指向現在那一個
        let nick = NicknameStore.all().mapValues(\.name)
        func entries(_ n: String) -> [RosterEntry] {
            guard let es = roster?.entries else { return [] }
            return ShortName.match(n, among: es.map { ($0.sessionId, $0.name) }, nick: nick).compactMap { sid in es.first { $0.sessionId == sid } }
        }
        func entry(_ n: String) -> RosterEntry? { let es = entries(n); return es.count == 1 ? es[0] : nil }
        for n in [to] + (thenTo.map { [$0] } ?? []) where entries(n).count > 1 {
            err("「\(n)」有 \(entries(n).count) 個開著的 session，請改用全名或 sessionId：" + entries(n).map { "\($0.name)（\($0.sessionId.prefix(8))）" }.joined(separator: "、"))
            return 1
        }
        let target = entry(to)
        if roster != nil && target == nil { err("名冊裡沒有「\(to)」；先跑 showork roster 看名字"); return 1 }
        if let n = thenTo, roster != nil && entry(n) == nil { err("名冊裡沒有下一棒「\(n)」"); return 1 }
        if target?.sessionId == from { err("不能派給自己"); return 1 }
        if CaptainStore.captain()?.sessionId != from {
            CaptainStore.setCaptain(CaptainRecord(sessionId: from, name: sessionName(from)))
        }
        let id = Captain.newId(now: Date(), existing: Set(CaptainStore.tasks().map(\.id)))
        let t = CaptainTask(id: id, from: from, to: target?.name ?? to, toSession: target?.sessionId, project: target?.project, text: text,
                            thenTo: thenTo.map { n in entry(n).map { nick[$0.sessionId] ?? $0.name } ?? n }, thenText: thenText)
        if let w = target, !w.sameProject.isEmpty { err("⚠ \(w.project) 還有別的 session：\(w.sameProject.joined(separator: "、"))") }
        if let c = target?.ctx, c >= Int(ContextGuard.threshold) { err("⚠ \(to) 的 context 已用 \(c)%，可能做不完") }
        let (saved, r) = Captain.dispatch(t, showork: showork, fromName: sessionName(from) ?? "隊長")
        switch r {
        case .success:
            out("單號 \(id)：已送進 \(saved.to) 的收件匣" + (saved.thenTo.map { "；它做完會自動接力給 \($0)" } ?? "") + "。回報會由看板自動傳給你。")
        case .failure(let e):
            out("單號 \(id) 已建，但直送失敗（\(e.message)）。請改用 SendMessage（to: \"\(saved.to)\"）送出以下全文：")
            out("-----")
            out(Captain.message(saved, showork: showork))
        }
        return 0
    }
}
