import Foundation
import ShoWorkCore

// 11-22 Keng：空轉的背景 session 自動停掉（規則與保護見 ShoWorkCore/BgJanitor.swift）。
// 每分鐘看一次 ~/.claude/sessions/*.json；記帳本 board/guard/bg-janitor.json；做了什麼記在 board/guard/bg-janitor.log。
// 測試模式（--board-window）不動手，除非 SHOWORK_TEST_BGJANITOR=1（SHOWORK_BGJANITOR_IDLE＝秒數，測試用縮短）。
final class BgJanitorRunner: @unchecked Sendable {
    static let shared = BgJanitorRunner()
    private let q = DispatchQueue(label: "showork.bgjanitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var stopping = Set<String>()
    private var guardDir: URL { BoardPaths.dir.appendingPathComponent("guard", isDirectory: true) }
    private var ledgerURL: URL { guardDir.appendingPathComponent("bg-janitor.json") }
    private var logURL: URL { guardDir.appendingPathComponent("bg-janitor.log") }

    @MainActor func start() {
        let env = ProcessInfo.processInfo.environment
        if BoardWindow.testMode && env["SHOWORK_TEST_BGJANITOR"] == nil { return }
        let idle = env["SHOWORK_BGJANITOR_IDLE"].flatMap(Double.init) ?? BgJanitor.idleLimit
        let period = env["SHOWORK_BGJANITOR_PERIOD"].flatMap(Double.init) ?? 60
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 5, repeating: period)
        t.setEventHandler { [weak self] in self?.tick(idle: idle) }
        t.resume(); timer = t
    }

    private func tick(idle: TimeInterval) {
        let fm = FileManager.default, dir = BoardPaths.claude + "/sessions"
        let recs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { f -> SessionRecord? in
            guard let d = fm.contents(atPath: dir + "/" + f), let r = SessionRecord.decode(d), kill(r.pid, 0) == 0 else { return nil }
            return r
        }
        var ledger = (try? JSONDecoder().decode(BgJanitor.Ledger.self, from: Data(contentsOf: ledgerURL))) ?? .init()
        let owned = DispatchQueue.main.sync { MainActor.assumeIsolated { SessionHost.shared.boardLiveIds() } }
        let cards = BoardPaths.dir.appendingPathComponent("cards").path
        let (verdicts, L) = BgJanitor.review(recs, ledger: ledger, now: Date(), owned: owned, idleLimit: idle,
                                             hasWork: { Self.hasWork($0) }, hasCard: { fm.fileExists(atPath: "\(cards)/\($0).json") })
        ledger = L
        try? fm.createDirectory(at: guardDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(ledger) { try? d.write(to: ledgerURL, options: .atomic) }
        for (r, v) in verdicts {
            guard case .stop(let why) = v, !stopping.contains(r.sessionId) else { continue }
            stopping.insert(r.sessionId)
            let id = r.jobId ?? String(r.sessionId.prefix(8))
            let (ok, out) = Self.claudeStop(id)
            log("\(ok ? "已停" : "停失敗") \(r.name ?? id)（\(id)，pid \(r.pid)）：\(why)\(ok ? "" : "｜\(out)")")
            if !ok { stopping.remove(r.sessionId) }
        }
    }

    /// 這個 session id 的對話紀錄有沒有人講過話（照 cwd 算路徑；找不到就到 projects 底下每個資料夾找）
    static func hasWork(_ r: SessionRecord) -> Bool {
        let fm = FileManager.default, base = BoardPaths.claude + "/projects"
        var paths = ["\(base)/\(r.projectSlug)/\(r.sessionId).jsonl"]
        if !fm.fileExists(atPath: paths[0]) {
            paths = ((try? fm.contentsOfDirectory(atPath: base)) ?? []).map { "\(base)/\($0)/\(r.sessionId).jsonl" }.filter { fm.fileExists(atPath: $0) }
        }
        return paths.contains { p in (try? FileHandle(forReadingFrom: URL(fileURLWithPath: p))).map { h in defer { try? h.close() }; return BgJanitor.transcriptHasWork(h.readData(ofLength: 262_144)) } ?? false }
    }

    /// `claude stop <id>`（kill 會被背景常駐程式重開；stop 只停、對話留著）
    static func claudeStop(_ id: String) -> (Bool, String) {
        let home = BoardPaths.home
        let bin = [ProcessInfo.processInfo.environment["SHOWORK_CLAUDE_BIN"], home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bin else { return (false, "找不到 claude 指令") }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: bin); p.arguments = ["stop", id]
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); return (false, "逾時") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0, out)
    }

    private func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        print("bgjanitor:", s); fflush(stdout)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: logURL) }
    }
}
