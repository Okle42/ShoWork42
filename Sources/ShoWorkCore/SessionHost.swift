import Foundation

// 戰情中心自己持有的 session（11-08，docs/OWN-SESSIONS.md「A＋交棒」）。
// 一個 session 一個長駐的 `claude -p --input-format stream-json --output-format stream-json --verbose`，stdin 一直開著：
//   送話＝寫一行 user 訊息；中斷＝寫 control_request interrupt；關掉＝關 stdin（程序自己收尾結束）。
// 交棒：同一個 session 在戰情中心和終端機之間換手，兩邊共用同一份對話紀錄（`--resume <id>`）。同一時間只能有一邊在跑：
//   誰在跑看 ~/.claude/sessions/<pid>.json（Claude Code 自己寫的，pid 活著＋sessionId 相同＝有人在用）。
// 擁有者紀錄在 board/sessions/owners.json（看板靠它把這些 `sdk-cli` 的 session 照樣放上看板）；
// 串流事件原樣追加到 board/sessions/<sid>.jsonl（工作視窗重開、agent 重啟都從這裡重建畫面）。

/// 一行串流事件：type／subtype 先解出來，其他留原文（UI 層自己解析）
public struct StreamEvent: Sendable, Equatable {
    public var type: String
    public var subtype: String?
    public var raw: Data
    public init(type: String, subtype: String? = nil, raw: Data) { self.type = type; self.subtype = subtype; self.raw = raw }

    public static func parse(_ line: Data) -> StreamEvent? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let t = o["type"] as? String else { return nil }
        return StreamEvent(type: t, subtype: o["subtype"] as? String, raw: line)
    }
    public var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]) ?? [:] }
}

/// 擁有者紀錄：這個 session 現在歸誰
public struct OwnedRecord: Codable, Sendable, Equatable {
    public enum Owner: String, Codable, Sendable { case board, terminal }
    public var sessionId: String
    public var cwd: String
    public var owner: Owner
    public var model: String?
    public var name: String?
    public var permissionMode: String?
    public var updatedAt: Date
    public init(sessionId: String, cwd: String, owner: Owner, model: String? = nil, name: String? = nil,
                permissionMode: String? = nil, updatedAt: Date = Date()) {
        self.sessionId = sessionId; self.cwd = cwd; self.owner = owner; self.model = model; self.name = name
        self.permissionMode = permissionMode; self.updatedAt = updatedAt
    }
}

public enum SessionHostError: Error, Equatable, CustomStringConvertible {
    case inUse(pid: Int32)          // 別的程序（終端機）正在跑這個 session
    case alreadyOwned               // 戰情中心已經開著
    case launch(String)
    public var description: String {
        switch self {
        case .inUse(let p): "這個 session 正在別的地方跑（pid \(p)）；先在那邊結束，再搬進戰情中心"
        case .alreadyOwned: "戰情中心已經開著這個 session"
        case .launch(let m): "開不起來：\(m)"
        }
    }
}

/// 戰情中心開著的一個 session（一個長駐程序）
public final class OwnedSession: @unchecked Sendable {
    public enum State: String, Sendable { case starting, idle, busy, exited }

    public let sessionId: String
    public let cwd: String
    public private(set) var state: State = .starting
    public private(set) var pid: Int32 = 0
    /// 事件回呼（背景執行緒）；UI 自己切回主執行緒
    public var onEvent: (@Sendable (StreamEvent) -> Void)?
    public var onExit: (@Sendable (Int32) -> Void)?

    private let proc = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let lock = NSLock()
    private var buf = Data()
    private var reqSeq = 0
    private let log: URL
    private var stderrTail = Data()

    init(sessionId: String, cwd: String, executable: String, args: [String], env: [String: String], log: URL) {
        self.sessionId = sessionId; self.cwd = cwd; self.log = log
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        proc.environment = e
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = stderr
    }

    func launch() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.feed(d)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            guard let self else { return }
            self.lock.lock(); self.stderrTail.append(d); if self.stderrTail.count > 4096 { self.stderrTail = self.stderrTail.suffix(4096) }; self.lock.unlock()
        }
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); self.state = .exited; self.lock.unlock()
            self.onExit?(p.terminationStatus)
        }
        do { try proc.run() } catch { throw SessionHostError.launch(error.localizedDescription) }
        pid = proc.processIdentifier
    }

    /// 最近的錯誤輸出（開不起來時給使用者看）
    public var stderrText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stderrTail, as: UTF8.self) }

    private func feed(_ d: Data) {
        lock.lock(); buf.append(d)
        var lines: [Data] = []
        while let i = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex..<i]
            buf.removeSubrange(buf.startIndex...i)
            if !line.isEmpty { lines.append(Data(line)) }
        }
        lock.unlock()
        for l in lines {
            append(l)
            guard let e = StreamEvent.parse(l) else { continue }
            lock.lock()
            switch e.type {
            case "system" where e.subtype == "init": if state == .starting { state = .idle }
            case "result": state = .idle
            default: break
            }
            lock.unlock()
            onEvent?(e)
        }
    }

    private func append(_ line: Data) {
        guard let h = try? FileHandle(forWritingTo: log) else {
            try? (line + Data([0x0A])).write(to: log); return
        }
        defer { try? h.close() }
        h.seekToEndOfFile(); h.write(line + Data([0x0A]))
    }

    private func write(_ o: [String: Any]) -> Bool {
        guard state != .exited, let d = try? JSONSerialization.data(withJSONObject: o) else { return false }
        do { try stdin.fileHandleForWriting.write(contentsOf: d + Data([0x0A])); return true } catch { return false }
    }

    /// 送一句話（content 可以是字串，或 [text／image 區塊]）
    @discardableResult
    public func send(_ text: String) -> Bool { send(content: text) }

    @discardableResult
    public func send(content: Any) -> Bool {
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard write(msg) else { return false }
        lock.lock(); state = .busy; lock.unlock()
        // 自己送出的話也記進 log（串流不會回放 user 訊息），工作視窗重建時才看得到
        var mark = msg; mark["_sent"] = Date().timeIntervalSince1970
        if let d = try? JSONSerialization.data(withJSONObject: mark) { append(d) }
        return true
    }

    /// 送控制請求（interrupt、set_model、set_permission_mode…）
    @discardableResult
    public func control(_ subtype: String, _ extra: [String: Any] = [:]) -> Bool {
        lock.lock(); reqSeq += 1; let id = "sw42-\(reqSeq)"; lock.unlock()
        var req: [String: Any] = ["subtype": subtype]
        for (k, v) in extra { req[k] = v }
        return write(["type": "control_request", "request_id": id, "request": req])
    }

    @discardableResult public func interrupt() -> Bool { control("interrupt") }

    /// 關掉：關 stdin，讓程序自己收尾；timeout 秒後還在就 SIGTERM
    public func close(timeout: TimeInterval = 10) {
        try? stdin.fileHandleForWriting.close()
        let p = proc
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    }

    /// 等程序結束（測試、交棒用）
    @discardableResult
    public func waitExit(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        return !proc.isRunning
    }
}

/// 戰情中心持有的所有 session
public final class SessionHost: @unchecked Sendable {
    public static let shared = SessionHost()

    /// 測試換掉：claude 執行檔、~/.claude、存檔資料夾
    public var executable: String
    public var claudeDir: String
    public var dir: URL
    public var extraEnv: [String: String] = [:]
    /// 每次都加的參數（e2e 用 --setting-sources '' 隔離使用者的 hooks）
    public var extraArgs: [String] = []

    private let lock = NSLock()
    private var open: [String: OwnedSession] = [:]

    public init(executable: String? = nil, claudeDir: String? = nil, dir: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.executable = executable ?? env["SHOWORK_CLAUDE_BIN"] ?? SessionHost.findClaude()
        self.claudeDir = claudeDir ?? env["SHOWORK_CLAUDE_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
        self.dir = dir ?? Paths.supportDir.appendingPathComponent("board/sessions", isDirectory: true)
    }

    static func findClaude() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/env"   // 最後手段：PATH 上的 claude（args 前面補 "claude"）
    }

    public var ownersFile: URL { dir.appendingPathComponent("owners.json") }
    public func logFile(_ sid: String) -> URL { dir.appendingPathComponent("\(sid).jsonl") }

    // MARK: 擁有者紀錄

    public func owners() -> [String: OwnedRecord] {
        guard let d = try? Data(contentsOf: ownersFile) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([String: OwnedRecord].self, from: d)) ?? [:]
    }

    private func saveOwners(_ m: [String: OwnedRecord]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let d = try? enc.encode(m) { try? d.write(to: ownersFile, options: .atomic) }
    }

    public func setOwner(_ sid: String, _ owner: OwnedRecord.Owner) {
        lock.lock(); defer { lock.unlock() }
        var m = owners()
        guard var r = m[sid] else { return }
        r.owner = owner; r.updatedAt = Date(); m[sid] = r
        saveOwners(m)
    }

    public func forget(_ sid: String) {
        lock.lock(); defer { lock.unlock() }
        var m = owners(); m[sid] = nil; saveOwners(m)
    }

    // MARK: 誰在跑

    /// 別的活著的程序正在跑這個 session ⇒ 它的 pid（排除 exclude）
    public func runningElsewhere(_ sid: String, exclude: Set<Int32> = []) -> Int32? {
        let sdir = URL(fileURLWithPath: claudeDir).appendingPathComponent("sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sdir.path) else { return nil }
        for n in names where n.hasSuffix(".json") {
            guard let d = try? Data(contentsOf: sdir.appendingPathComponent(n)), let r = SessionRecord.decode(d),
                  r.sessionId == sid, !exclude.contains(r.pid), r.pid > 0, kill(r.pid, 0) == 0 else { continue }
            return r.pid
        }
        return nil
    }

    public func session(_ sid: String) -> OwnedSession? { lock.lock(); defer { lock.unlock() }; return open[sid] }
    public var openSessions: [OwnedSession] { lock.lock(); defer { lock.unlock() }; return Array(open.values) }

    // MARK: 開／接回／放手

    /// 開一個新的 session（第一句話可以先不給，開好再 send）
    public func start(cwd: String, model: String? = nil, name: String? = nil, permissionMode: String? = nil,
                      sessionId: String = UUID().uuidString.lowercased()) throws -> OwnedSession {
        try launch(sid: sessionId, cwd: cwd, model: model, name: name, permissionMode: permissionMode, resume: false)
    }

    /// 接回既有的 session（終端機那邊結束後搬進來、agent 重啟後接回）
    public func resume(_ sid: String, cwd: String, model: String? = nil, name: String? = nil, permissionMode: String? = nil) throws -> OwnedSession {
        if let p = runningElsewhere(sid) { throw SessionHostError.inUse(pid: p) }
        return try launch(sid: sid, cwd: cwd, model: model, name: name, permissionMode: permissionMode, resume: true)
    }

    func args(sid: String, model: String?, name: String?, permissionMode: String?, resume: Bool) -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        a += resume ? ["--resume", sid] : ["--session-id", sid]
        if let model { a += ["--model", model] }
        if let name, !resume { a += ["-n", name] }
        if let permissionMode { a += ["--permission-mode", permissionMode] }
        a += extraArgs
        return executable.hasSuffix("/env") ? ["claude"] + a : a
    }

    private func launch(sid: String, cwd: String, model: String?, name: String?, permissionMode: String?, resume: Bool) throws -> OwnedSession {
        lock.lock()
        if open[sid] != nil { lock.unlock(); throw SessionHostError.alreadyOwned }
        lock.unlock()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = OwnedSession(sessionId: sid, cwd: cwd, executable: executable,
                             args: args(sid: sid, model: model, name: name, permissionMode: permissionMode, resume: resume),
                             env: extraEnv, log: logFile(sid))
        s.onExit = { [weak self] _ in self?.exited(sid) }
        try s.launch()
        lock.lock()
        open[sid] = s
        var m = owners()
        var r = m[sid] ?? OwnedRecord(sessionId: sid, cwd: cwd, owner: .board)
        r.owner = .board; r.cwd = cwd; r.updatedAt = Date()
        if let model { r.model = model }
        if let name { r.name = name }
        if let permissionMode { r.permissionMode = permissionMode }
        m[sid] = r; saveOwners(m)
        lock.unlock()
        return s
    }

    private func exited(_ sid: String) {
        lock.lock(); open[sid] = nil; lock.unlock()
    }

    /// 要送話時用：開著就回傳；終端機那邊在跑就丟 inUse；不然照紀錄（cwd、模型、權限模式）接回來。
    /// 交棒回來不用另外按：終端機結束後，在戰情中心送話就自動接回（11-08 lazy：agent 重啟也不先全部開起來）
    public func ensure(_ sid: String, cwd fallback: String? = nil) throws -> OwnedSession {
        if let s = session(sid) { return s }
        let r = owners()[sid]
        guard let cwd = r?.cwd ?? fallback else { throw SessionHostError.launch("不知道這個 session 在哪個資料夾") }
        return try resume(sid, cwd: cwd, model: r?.model, permissionMode: r?.permissionMode)
    }

    /// 放手（交棒給終端機前）：關掉程序並等它結束；紀錄改成 terminal
    @discardableResult
    public func release(_ sid: String, to owner: OwnedRecord.Owner = .terminal, timeout: TimeInterval = 15) -> Bool {
        guard let s = session(sid) else { setOwner(sid, owner); return true }
        s.close(timeout: timeout)
        let ok = s.waitExit(timeout: timeout + 2)
        if ok { setOwner(sid, owner) }
        return ok
    }

    /// 在終端機接手要打的指令（交棒用；終端機那邊照這行跑）
    public func terminalCommand(_ sid: String) -> String {
        let r = owners()[sid]
        var c = "cd \(shellQuote(r?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)) && claude --resume \(sid)"
        if let m = r?.model { c += " --model \(shellQuote(m))" }
        return c
    }

    /// 戰情中心「應該」開著、但程序不在的 session（agent 重啟後要接回的）
    public func orphans() -> [OwnedRecord] {
        let m = owners()
        return m.values.filter { $0.owner == .board && session($0.sessionId) == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

func shellQuote(_ s: String) -> String {
    s.allSatisfy { $0.isLetter || $0.isNumber || "/-_.@:+".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
