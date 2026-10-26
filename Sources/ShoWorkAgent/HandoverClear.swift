import AppKit
import ShoWorkCore

// MARK: - ctx 自動交接 ②：收尾完自動 /clear、再叫新 context 接手（T1024155358，流程見 ShoWorkCore/Handover.swift）

/// 每次刷新看一遍 board/handover：
///   pending      ＋它閒下來 ⇒ 對它的終端機送 /clear（tmux send-keys；Ghostty 走 AppleScript `input text … to terminal id`，不搶焦點）
///   clearing     ＋sessions/<pid>.json 換了 sid ⇒ 再打一句「開始接手」；20 秒沒換 ⇒ failed
///   interrupted  ⇒ 轉隊長一則提醒（收尾後使用者又派新工作）
///   failed       ⇒ 卡片 blocked＋系統通知請 Kang 手動 /clear
/// 目標一定要閉環驗證（09-26 搬 Kang 7 個視窗的教訓）：tmux＝claude 行程的 tty 擁有的 pane；Ghostty＝同一個 tty 探出來的 terminal，
/// 而且 terminal 標題開頭是它的英文名。驗不過就不送。每筆紀錄只自動送一次。
@MainActor
final class HandoverClear {
    static let shared = HandoverClear()
    private var busy = false

    func check(_ cards: [BoardCard], records: [String: HandoverRecord], captain: String?) {
        guard Engine.current != nil, !busy, !records.isEmpty else { return }   // 只有正式 agent 會動手；測試視窗不動
        let now = Date()
        for snap in records.values {
            // 快照可能是舊的（背景讀的）；動手前一律以磁碟上的為準，免得同一筆送兩次
            guard var r = snap.state == .failed || (snap.state == .taken && snap.clearAt == nil) ? nil : Handover.load(snap.sid) else { continue }
            switch r.state {
            case .pending:
                guard let c = cards.first(where: { $0.sessionId == r.sid }) else { continue }
                let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                guard Handover.readyToClear(state: r.state, lastKind: c.report?.kind, working: c.column == .active,
                                            dialog: c.permit != nil || c.reason == "等你回答",
                                            lastActivity: c.lastActivity, keyIdle: key, now: now) else { continue }
                busy = true; defer { busy = false }
                // 先記「送出中」再按鍵：/clear 後的 SessionStart 會讀這筆、改成 taken 寫回，晚寫會把它蓋掉（10-24 實測撞到）
                r.state = .clearing; r.clearAt = now
                Handover.save(r)
                switch send("/clear", to: r) {
                case .success(let via):
                    if var cur = Handover.load(r.sid) { cur.via = via; Handover.save(cur) }
                    log("/clear → \(r.name) \(r.sid.prefix(8)) via \(via)")
                case .failure(let e):
                    fail(&r, e.message)
                    Handover.save(r)
                }
            case .clearing, .taken:
                guard !r.kicked, let at = r.clearAt else { continue }
                let cur = currentSid(pid: r.pid)
                if r.state == .taken || (cur != nil && cur != r.sid) {
                    let ctx = cur.flatMap(ctxPercent).map { "\(Int($0))%" } ?? "未更新"
                    busy = true; defer { busy = false }
                    let k = send(Handover.kickoff(r), to: r)
                    r.kicked = true
                    log("cleared \(r.name) \(r.sid.prefix(8)) → \((r.newSid ?? cur ?? "?").prefix(8)) ctx=\(ctx) kickoff=\(k)")
                    Handover.save(r)
                } else if now.timeIntervalSince(at) > Handover.clearTimeout {
                    fail(&r, "送了 /clear 但 \(Int(Handover.clearTimeout)) 秒內 session 沒換")
                    Handover.save(r)
                }
            case .interrupted:
                guard !r.notified else { continue }
                r.notified = true
                Handover.save(r)
                let text = "【交接提醒】\(r.name) 已在 \(Self.clock(r.at)) 收尾（交接 \(r.handoff)），但之後使用者又派了新工作，所以先不自動 /clear；"
                    + "ctx 再多 15% 時 Stop hook 會再請它收尾一次。要現在就換手，請它做完這件後再發一次 showork card --kind wrapup。"
                log("interrupted \(r.name) \(r.sid.prefix(8))")
                if let cap = captain, cap != r.sid {
                    DispatchQueue.global().async {
                        guard let to = Peer.find(cap) else { return }
                        _ = Peer.send(to: to, text: text, fromName: "AI工作戰情中心（交接）")
                    }
                } else { notify("\(r.name) 收尾後又接了新工作", "先不自動 /clear") }
            case .failed:
                continue
            }
        }
    }

    // MARK: 送字（閉環驗證過才送）

    private func send(_ text: String, to r: HandoverRecord) -> Result<String, CardError> {
        if let (sock, pane) = BoardActions.tmuxPane(of: r.pid) {
            let t = Tmux.binary()
            Tools.run(t, ["-S", sock, "send-keys", "-t", pane, "-l", text], timeout: 5)
            Thread.sleep(forTimeInterval: 0.15)
            Tools.run(t, ["-S", sock, "send-keys", "-t", pane, "Enter"], timeout: 5)
            return .success("tmux")
        }
        guard let tty = Self.tty(of: r.pid) else { return .failure(CardError("找不到 \(r.name) 的終端機（行程 \(r.pid) 沒有 tty）")) }
        guard let g = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first,
              ProcTree.ttys(under: g.processIdentifier).contains(tty) else {
            return .failure(CardError("\(r.name) 不在 tmux 也不在 Ghostty，看板送不了"))
        }
        guard let tid = GhosttyProbe.resolve(tty: tty, ghosttyPID: g.processIdentifier)?.terminalID else {
            return .failure(CardError("Ghostty 找不到 \(tty) 對應的分頁"))
        }
        let id = Self.q(tid)
        let title = Script.string("tell application id \"com.mitchellh.ghostty\" to get name of (first terminal whose id is \"\(id)\")") ?? ""
        guard Handover.titleMatches(title, name: r.name) else {
            return .failure(CardError("Ghostty 分頁標題「\(title)」對不上 \(r.name)，不送"))
        }
        let ok = Script.run("""
            tell application id "com.mitchellh.ghostty"
              set t to first terminal whose id is "\(id)"
              input text "\(Self.q(text))" to t
              delay 0.15
              send key "enter" to t
              return "ok"
            end tell
            """)?.stringValue == "ok"
        return ok ? .success("ghostty") : .failure(CardError("Ghostty AppleScript 送字失敗"))
    }

    private func fail(_ r: inout HandoverRecord, _ why: String) {
        r.state = .failed; r.note = why; r.notified = true
        log("failed \(r.name) \(r.sid.prefix(8)): \(why)")
        // 卡片標卡住（之後這張卡不再是 wrapup ⇒ 不會再自動送）
        let card = SelfReport(status: .blocked, summary: "自動 /clear 失敗：\(why)。請手動 /clear，新 context 會自動讀交接 \(r.handoff)",
                              doing: NicknameStore.get(r.sid)?.doing)
        let dir = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)
        if let d = try? BoardJSON.encoder.encode(card) { try? d.write(to: dir.appendingPathComponent(r.sid + ".json"), options: .atomic) }
        notify("\(r.name) 自動 /clear 失敗", "請到它的終端機手動 /clear（\(why)）")
    }

    // MARK: 小工具

    /// 一律寫 board/handover.log（Log.note 只在 SHOWORK_DEBUG 才寫）
    private func log(_ s: String) {
        Log.note("HANDOVER " + s)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let url = Paths.supportDir.appendingPathComponent("board/handover.log")
        let line = Data("\(f.string(from: Date())) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    private func currentSid(pid: Int32) -> String? {
        FileManager.default.contents(atPath: "\(BoardPaths.claude)/sessions/\(pid).json").flatMap(SessionRecord.decode)?.sessionId
    }
    private func ctxPercent(_ sid: String) -> Double? {
        guard let d = FileManager.default.contents(atPath: "\(BoardPaths.claude)/cache/ctx/\(sid).json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (o["used_percentage"] as? NSNumber)?.doubleValue
    }
    static func tty(of pid: Int32) -> String? {
        guard let info = ProcTree.kinfo(pid) else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != UInt32(bitPattern: -1), dev != 0, let n = devname(dev_t(dev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: n)
    }
    static func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    static func clock(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
    private func notify(_ title: String, _ body: String) {
        DispatchQueue.global().async {
            Tools.run("/usr/bin/osascript", ["-e", "display notification \"\(Self.q(body))\" with title \"AI工作戰情中心\" subtitle \"\(Self.q(title))\""], timeout: 10)
        }
    }
}
