import Foundation
import Testing
@testable import ShoWorkCore

/// 假的 claude（串流模式）：讀 stdin 每一行；user ⇒ 回 assistant＋result；control_request ⇒ 回 control_response。不連網、不碰真的 claude
private let fakeClaude = """
#!/usr/bin/python3 -I
import sys, json, os
args = sys.argv[1:]
sid = args[args.index("--resume") + 1] if "--resume" in args else args[args.index("--session-id") + 1]
def out(o):
    sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\\n"); sys.stdout.flush()
out({"type": "system", "subtype": "init", "session_id": sid, "args": args, "owned": os.environ.get("SHOWORK_OWNED"), "reviewer": os.environ.get("SHOWORK_REVIEWER")})
for line in sys.stdin:
    o = json.loads(line)
    if o["type"] == "user" and o["message"]["content"] == "/clear":
        sid = "cleared-" + sid[:8]
        out({"type": "conversation_reset"})
        out({"type": "system", "subtype": "init", "session_id": sid, "args": args})
        out({"type": "result", "subtype": "success", "session_id": sid, "result": ""})
    elif o["type"] == "user":
        c = o["message"]["content"]
        out({"type": "assistant", "session_id": sid, "message": {"content": [{"type": "text", "text": "收到：" + (c if isinstance(c, str) else "區塊")}]}})
        out({"type": "result", "subtype": "success", "session_id": sid, "result": "收到"})
    elif o["type"] == "control_request":
        out({"type": "control_response", "response": {"subtype": "success", "request_id": o["request_id"], "echo": o["request"]["subtype"]}})
"""

@Suite("戰情中心自己持有 session（SessionHost）", .serialized)
struct SessionHostTests {
    let root: URL
    let host: SessionHost

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sw42-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude/sessions"), withIntermediateDirectories: true)
        let bin = root.appendingPathComponent("fake-claude")
        try fakeClaude.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        host = SessionHost(executable: bin.path, claudeDir: root.appendingPathComponent("claude").path, dir: root.appendingPathComponent("sessions"))
    }

    /// 收事件直到 pred 成立
    final class Box: @unchecked Sendable { let l = NSLock(); var xs: [StreamEvent] = [] }
    func collect(_ s: OwnedSession) -> Box {
        let b = Box(); s.onEvent = { e in b.l.lock(); b.xs.append(e); b.l.unlock() }; return b
    }
    func wait(_ b: Box, _ t: TimeInterval = 10, _ pred: ([StreamEvent]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t)
        while Date() < end { b.l.lock(); let ok = pred(b.xs); b.l.unlock(); if ok { return true }; Thread.sleep(forTimeInterval: 0.02) }
        return false
    }

    @Test("開新的：送一句收到 result；log 有自己送的話；擁有者＝board")
    func startSend() throws {
        let s = try host.start(cwd: root.path, model: "haiku", name: "測試員")
        let b = collect(s)
        #expect(wait(b) { $0.contains { $0.type == "system" && $0.subtype == "init" } })
        #expect(s.send("你好"))
        #expect(wait(b) { $0.contains { $0.type == "result" } })
        #expect(s.state == .idle)
        let init0 = b.xs.first { $0.subtype == "init" }!.json["args"] as! [String]
        #expect(init0.contains("--session-id") && !init0.contains("--resume"))
        #expect(init0.contains("haiku") && init0.contains("測試員"))
        // showork 的 hooks 靠這個才不把它當審核員略過（權限進收件匣、自報、狀態）
        #expect(b.xs.first { $0.subtype == "init" }!.json["owned"] as? String == "1")
        #expect(b.xs.first { $0.subtype == "init" }!.json["reviewer"] is NSNull)
        let log = try String(contentsOf: host.logFile(s.sessionId), encoding: .utf8)
        #expect(log.contains("\"_sent\"") && log.contains("你好") && log.contains("收到：你好"))
        #expect(host.owners()[s.sessionId]?.owner == .board)
        #expect(host.owners()[s.sessionId]?.name == "測試員")
        #expect(throws: SessionHostError.alreadyOwned) { _ = try host.start(cwd: root.path, sessionId: s.sessionId) }
        host.release(s.sessionId)
    }

    @Test("中斷：送 control_request interrupt，收到 control_response")
    func interrupt() throws {
        let s = try host.start(cwd: root.path)
        let b = collect(s)
        #expect(wait(b) { $0.contains { $0.subtype == "init" } })
        #expect(s.interrupt())
        #expect(wait(b) { xs in xs.contains { $0.type == "control_response" && (($0.json["response"] as? [String: Any])?["echo"] as? String) == "interrupt" } })
        host.release(s.sessionId)
    }

    @Test("放手：程序結束、擁有者改 terminal；再接回用 --resume、擁有者回到 board")
    func releaseResume() throws {
        let s = try host.start(cwd: root.path, model: "haiku")
        let sid = s.sessionId
        #expect(host.release(sid))
        #expect(s.state == .exited)
        #expect(host.session(sid) == nil)
        #expect(host.owners()[sid]?.owner == .terminal)
        #expect(host.terminalCommand(sid).hasSuffix("claude --resume \(sid) --model haiku"))
        let s2 = try host.resume(sid, cwd: root.path)
        let b = collect(s2)
        #expect(wait(b) { $0.contains { $0.subtype == "init" } })
        let a = b.xs.first { $0.subtype == "init" }!.json["args"] as! [String]
        #expect(a.contains("--resume") && !a.contains("--session-id"))
        #expect(host.owners()[sid]?.owner == .board)
        host.release(sid, to: .board)
    }

    @Test("別的程序正在跑同一個 session（終端機開著）⇒ 不准接回")
    func inUse() throws {
        let sid = UUID().uuidString.lowercased()
        let me = ProcessInfo.processInfo.processIdentifier       // 活著的 pid 當作「終端機那個 claude」
        let rec = #"{"pid":\#(me),"sessionId":"\#(sid)","cwd":"/tmp","kind":"interactive"}"#
        try rec.write(to: root.appendingPathComponent("claude/sessions/\(me).json"), atomically: true, encoding: .utf8)
        #expect(host.runningElsewhere(sid) == me)
        #expect(host.runningElsewhere(sid, exclude: [me]) == nil)
        #expect(throws: SessionHostError.inUse(pid: me)) { _ = try host.resume(sid, cwd: root.path) }
        // 死掉的 pid 不算
        try #"{"pid":999999,"sessionId":"x-dead","cwd":"/tmp"}"#.write(to: root.appendingPathComponent("claude/sessions/999999.json"), atomically: true, encoding: .utf8)
        #expect(host.runningElsewhere("x-dead") == nil)
    }

    @Test("孤兒：紀錄是 board 但程序不在（agent 重啟後要接回的）")
    func orphans() throws {
        let s = try host.start(cwd: root.path)
        #expect(host.orphans().isEmpty)
        #expect(host.release(s.sessionId, to: .board))
        #expect(host.orphans().map(\.sessionId) == [s.sessionId])
        host.forget(s.sessionId)
        #expect(host.orphans().isEmpty)
    }

    @Test("終端機指令：路徑有空格要加引號")
    func quote() {
        #expect(shellQuote("/Users/a/專案A") == "/Users/a/專案A")
        #expect(shellQuote("/Users/a/my dir") == "'/Users/a/my dir'")
        #expect(shellQuote("it's") == "'it'\\''s'")
    }
}

/// 真的 claude（haiku）端對端：SHOWORK_E2E_CLAUDE=1 才跑（會用到訂閱額度，一般 swift test 不跑）
@Suite("SessionHost 端對端（真 claude）", .enabled(if: ProcessInfo.processInfo.environment["SHOWORK_E2E_CLAUDE"] == "1"))
struct SessionHostE2E {
    @Test("開 → 記暗號 → 放手 → 接回 → 問暗號答對")
    func roundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sw42-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = SessionHost(dir: root.appendingPathComponent("sessions"))
        host.extraArgs = ["--setting-sources", ""]
        func run(_ s: OwnedSession, _ text: String) -> String? {
            final class R: @unchecked Sendable { var v: String?; let l = NSLock() }
            let r = R()
            s.onEvent = { e in if e.type == "result" { r.l.lock(); r.v = e.json["result"] as? String ?? ""; r.l.unlock() } }
            s.send(text)
            let end = Date().addingTimeInterval(120)
            while Date() < end { r.l.lock(); let v = r.v; r.l.unlock(); if let v { return v }; Thread.sleep(forTimeInterval: 0.1) }
            return nil
        }
        let s = try host.start(cwd: root.path, model: "haiku")
        #expect(run(s, "記住暗號：藍鯨42。只回「好」") != nil)
        #expect(host.release(s.sessionId))
        let s2 = try host.resume(s.sessionId, cwd: root.path, model: "haiku")
        let ans = run(s2, "暗號是什麼？只回暗號") ?? ""
        #expect(ans.contains("藍鯨42"))
        host.release(s2.sessionId)
    }
}

@Suite("看板：戰情中心持有的 sdk-cli session 照樣上看板")
struct OwnedOnBoardTests {
    @Test func owned() {
        var a = SessionRecord(pid: 1, sessionId: "A", cwd: "/h/p", status: "idle"); a.entrypoint = "sdk-cli"
        var b = SessionRecord(pid: 2, sessionId: "B", cwd: "/h/p", status: "idle"); b.entrypoint = "sdk-cli"
        let cards = Board.build(sessions: [a, b], transcripts: [:], glows: [:], teams: [], inbox: [], owned: ["A"],
                                now: Date(), home: "/h", isRepo: { _ in false })
        #expect(cards.map(\.sessionId) == ["A"])
        #expect(cards.first?.kind == "board")
    }
}

extension SessionHostTests {
    @Test("ensure：開著就同一個；放手後自動照紀錄接回（模型沿用）；終端機在跑就擋")
    func ensure() throws {
        let s = try host.start(cwd: root.path, model: "haiku", permissionMode: "acceptEdits")
        #expect(try host.ensure(s.sessionId) === s)
        #expect(host.release(s.sessionId))
        let s2 = try host.ensure(s.sessionId)
        #expect(s2 !== s)
        let b = collect(s2)
        #expect(wait(b) { $0.contains { $0.subtype == "init" } })
        let a = b.xs.first { $0.subtype == "init" }!.json["args"] as! [String]
        #expect(a.contains("--resume") && a.contains("haiku") && a.contains("acceptEdits"))
        host.release(s2.sessionId)
        #expect(throws: SessionHostError.self) { _ = try host.ensure("no-such") }
    }
}

extension SessionHostTests {
    @Test("/clear 換 id：把手不變；看板、接回、終端機指令改用新 id")
    func clearRekey() throws {
        let s = try host.start(cwd: root.path, model: "haiku")
        let sid = s.sessionId
        let b = collect(s)
        #expect(wait(b) { $0.contains { $0.subtype == "init" } })
        s.send("/clear")
        let new = "cleared-" + sid.prefix(8)
        #expect(wait(b) { $0.filter { $0.subtype == "init" }.count == 2 })
        #expect(s.liveId == new)
        #expect(host.owners()[sid]?.currentId == new)
        #expect(host.handle(for: new) == sid && host.handle(for: sid) == sid && host.handle(for: "x") == nil)
        #expect(host.boardLiveIds() == [new])
        #expect(host.release(sid))
        #expect(host.terminalCommand(sid).contains("--resume \(new)"))
        let s2 = try host.ensure(sid)
        let b2 = collect(s2)
        #expect(wait(b2) { $0.contains { $0.subtype == "init" } })
        let a = b2.xs.first { $0.subtype == "init" }!.json["args"] as! [String]
        #expect(a.contains(new))
        #expect(host.logFile(sid).path.hasSuffix(sid + ".jsonl"))
        host.release(sid)
    }
}
