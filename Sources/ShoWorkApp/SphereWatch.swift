import AppKit
import Combine
import ShoWorkCore

// 球體 v4（11-21）：App 啟動就跑、不靠球體分頁開著的兩件事
//   E 今日時間軸：每個 session 的狀態一變就記一筆（board/sphere-timeline.jsonl，只留 7 天）
//   D 需要你提醒：桌面小球開著時，新冒出「需要你」⇒ 發系統通知＋小球彈跳（戰情中心沒開也不會漏）

@MainActor
final class SphereWatch {
    static let shared = SphereWatch()
    static var file: URL {      // 測試：SHOWORK_SPHERE_TIMELINE 換成假紀錄
        ProcessInfo.processInfo.environment["SHOWORK_SPHERE_TIMELINE"].map { URL(fileURLWithPath: $0) } ?? BoardPaths.dir.appendingPathComponent("sphere-timeline.jsonl")
    }
    private var subs: [AnyCancellable] = []
    private var last: [String: String] = [:]          // sessionId → 上次記的狀態
    private var asked: Set<String> = []                 // 已提醒過的「需要你」（sessionId|題目）
    private var primed = false
    private var pending = false

    func start() {
        guard subs.isEmpty else { return }
        BoardModel.shared.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subs)
        prune()
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in MainActor.assumeIsolated { self?.pending = false; self?.check() } }
    }

    private func check() {
        let m = BoardModel.shared
        guard m.loaded else { return }
        let now = Date()
        let people = m.cards.filter { !$0.id.contains("#") }
        var lines: [[String: Any]] = []
        var seen = Set<String>()
        for c in people {
            seen.insert(c.sessionId)
            let st = SphereWebHost.needsYou(c) ? "需要你" : c.column.title
            if last[c.sessionId] != st {
                last[c.sessionId] = st
                lines.append(["at": ISO8601DateFormatter().string(from: now), "sid": c.sessionId, "name": c.display, "status": st])
            }
        }
        for sid in last.keys where !seen.contains(sid) {
            last[sid] = nil
            lines.append(["at": ISO8601DateFormatter().string(from: now), "sid": sid, "status": "離線"])
        }
        if !lines.isEmpty, !BoardWindow.testMode { append(lines) }
        notifyAsks(people)
        primed = true
    }

    // MARK: D 需要你提醒

    private func notifyAsks(_ people: [BoardCard]) {
        var now = Set<String>()
        var fresh: [BoardCard] = []
        for c in people where SphereWebHost.needsYou(c) {
            let key = c.sessionId + "|" + (c.asks.first?.id ?? c.permit?.id ?? "")
            now.insert(key)
            if !asked.contains(key) { fresh.append(c) }
        }
        asked = now
        // 剛啟動時本來就在等的不提醒；小球關著不提醒（這是小球的功能，不另外吵人）
        guard primed, !fresh.isEmpty, SphereMini.shared.enabled else { return }
        SphereMini.shared.bounce()
        if BoardWindow.testMode { return }
        for c in fresh.prefix(3) {
            let who = c.display
            let q = c.asks.first?.ask ?? c.permit.map { "要不要讓它執行 \($0.tool)：\($0.summary)" } ?? "在等你"
            Self.notify(title: "\(who) 在等你", body: String(q.prefix(120)))
        }
    }

    static func notify(title: String, body: String) {
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") }
        DispatchQueue.global().async {
            Tools.run("/usr/bin/osascript", ["-e", "display notification \"\(q(body))\" with title \"AI工作戰情中心\" subtitle \"\(q(title))\""], timeout: 10)
        }
    }

    // MARK: E 時間軸

    private func append(_ lines: [[String: Any]]) {
        var d = Data()
        for l in lines { if let x = try? JSONSerialization.data(withJSONObject: l, options: .sortedKeys) { d.append(x); d.append(0x0A) } }
        try? FileManager.default.createDirectory(at: BoardPaths.dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: Self.file) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: Self.file) }
    }

    /// 只留 7 天
    private func prune() {
        guard let s = try? String(contentsOf: Self.file, encoding: .utf8) else { return }
        let cut = Date().addingTimeInterval(-7 * 86400), f = ISO8601DateFormatter()
        let keep = s.split(separator: "\n").filter { l in
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let a = (o["at"] as? String).flatMap(f.date(from:)) else { return false }
            return a >= cut
        }
        try? (keep.joined(separator: "\n") + (keep.isEmpty ? "" : "\n")).write(to: Self.file, atomically: true, encoding: .utf8)
    }

    /// 今天的時間軸給網頁：每個 session 一條，切成狀態段（純函式，測試可以直接餵行）
    static func timeline(lines: [String], cards: [BoardCard], now: Date = Date()) -> [String: Any] {
        let f = ISO8601DateFormatter()
        let start = Calendar.current.startOfDay(for: now)
        struct Ev { let at: Date; let sid: String; let name: String?; let status: String }
        var evs: [Ev] = lines.compactMap { l in
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                  let a = (o["at"] as? String).flatMap(f.date(from:)), let sid = o["sid"] as? String, let st = o["status"] as? String else { return nil }
            return Ev(at: a, sid: sid, name: o["name"] as? String, status: st)
        }
        evs.sort { $0.at < $1.at }
        var names: [String: String] = [:]
        for c in cards where !c.id.contains("#") { names[c.sessionId] = c.display }
        var lanes: [String: [[String: Any]]] = [:]
        var cur: [String: (Date, String)] = [:]
        var order: [String] = []
        func close(_ sid: String, at end: Date) {
            guard let (s, st) = cur[sid] else { return }
            let s2 = max(s, start)
            if end > s2, st != "離線" {
                lanes[sid, default: []].append(["s": s2.timeIntervalSince(start) / 60, "e": end.timeIntervalSince(start) / 60, "status": st])
            }
            cur[sid] = nil
        }
        for e in evs where e.at <= now {
            if let n = e.name { names[e.sid] = n }
            close(e.sid, at: e.at)
            cur[e.sid] = (e.at, e.status)
            if !order.contains(e.sid) { order.append(e.sid) }
        }
        for sid in cur.keys { close(sid, at: now) }
        let out = order.filter { lanes[$0] != nil }.map { sid -> [String: Any] in ["sid": sid, "name": names[sid] ?? String(sid.prefix(6)), "segs": lanes[sid]!] }
        return ["now": now.timeIntervalSince(start) / 60, "lanes": out]
    }

    static func todayTimeline() -> [String: Any] {
        let s = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return timeline(lines: s.split(separator: "\n").map(String.init), cards: BoardModel.shared.cards)
    }
}
