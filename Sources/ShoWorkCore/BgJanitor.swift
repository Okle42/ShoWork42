import Foundation

// 11-22 Keng：「不該在的就先關掉」——背景 session 從頭到尾沒接過任何工作、又閒置超過 10 分鐘，就自動停掉。
// 起因：Bella 轉背景時 Claude 背景常駐程式多開了一個空的（Ivan），一直佔著位置、還被算進「在線」。
// ⚠ 只停「從沒接過工作」的。做過事、做完放很久的不停；/clear 過的也不停（/clear 後 session id 換新、對話紀錄是空的，看起來跟沒做過一樣）。
// 判斷「接過工作」用好幾個證據，任何一個成立就保護：
//   1. 現在這個 session id 的對話紀錄裡有人講過話
//   2. formerNames 裡有別的 session id（換過 id＝/clear、resume 過）
//   3. 戰情中心記帳本記得這個程序（pid＋啟動時間）以前做過事（/clear 前看到過對話）
//   4. 戰情中心有它的自報卡（showork card）
//   5. 這個程序開起來的時候戰情中心還沒在看（比記帳早出生）⇒ 不知道它以前做過什麼，一律不動
// 停的方式是 `claude stop <id>`（直接 kill 會被背景常駐程式重開；stop 只停、對話保留，要的話 claude attach 叫回來）。

public enum BgJanitor {
    public static let idleLimit: TimeInterval = 10 * 60
    /// 記帳本：程序身分 → 第一次看到的時間、有沒有做過事
    public struct Ledger: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable { public var firstSeen: Double; public var worked: Bool; public var lastSeen: Double }
        public var entries: [String: Entry] = [:]
        public init() {}
    }
    public enum Verdict: Equatable, Sendable { case stop(String), keep(String) }

    public static func key(_ r: SessionRecord) -> String { "\(r.pid)@\(Int64(r.startedAt ?? 0))" }

    /// 一輪檢查：回傳每個 session 的判決＋更新後的帳本（純函式，方便測）
    /// - hasWork：這個 session id 的對話紀錄裡有沒有人講過話；hasCard：有沒有自報卡
    public static func review(_ recs: [SessionRecord], ledger: Ledger, now: Date, owned: Set<String> = [],
                              idleLimit: TimeInterval = idleLimit,
                              hasWork: (SessionRecord) -> Bool, hasCard: (String) -> Bool) -> (verdicts: [(SessionRecord, Verdict)], ledger: Ledger) {
        var L = ledger, out: [(SessionRecord, Verdict)] = []
        let t = now.timeIntervalSince1970 * 1000
        var alive = Set<String>()
        for r in recs {
            let k = key(r); alive.insert(k)
            var e = L.entries[k] ?? .init(firstSeen: t, worked: false, lastSeen: t)
            let changedId = (r.formerNames ?? []).contains { ($0.sessionId ?? r.sessionId) != r.sessionId }
            if hasWork(r) || hasCard(r.sessionId) || changedId { e.worked = true }
            e.lastSeen = t; L.entries[k] = e
            out.append((r, verdict(r, e, now: t, owned: owned, idleLimit: idleLimit)))
        }
        L.entries = L.entries.filter { alive.contains($0.key) || t - $0.value.lastSeen < 86_400_000 }    // 死掉的程序留一天就忘
        return (out, L)
    }

    static func verdict(_ r: SessionRecord, _ e: Ledger.Entry, now t: Double, owned: Set<String>, idleLimit: TimeInterval) -> Verdict {
        guard r.kind == "bg" else { return .keep("不是背景 session") }
        guard r.entrypoint != "sdk-cli", !owned.contains(r.sessionId) else { return .keep("戰情中心／無頭呼叫自己的") }
        if e.worked { return .keep("接過工作（含 /clear 過）") }
        guard let born = r.startedAt else { return .keep("不知道什麼時候開的") }
        if e.firstSeen - born > 3 * 60_000 { return .keep("比戰情中心開始看還早出生，不知道以前做過什麼") }
        guard r.status == "idle" else { return .keep("正在忙") }
        let idleSince = max(born, r.statusUpdatedAt ?? born)
        let lim = idleLimit * 1000
        guard t - born >= lim, t - idleSince >= lim else { return .keep("還沒閒置滿 \(Int(idleLimit / 60)) 分鐘") }
        return .stop("背景 session 沒接過任何工作、閒置 \(Int((t - idleSince) / 60_000)) 分鐘")
    }

    /// 對話紀錄裡有沒有人講過話（user 或 assistant 的訊息；只看前 256KB 就夠）
    public static func transcriptHasWork(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(262_144), as: UTF8.self)
        return head.contains(#""type":"user""#) || head.contains(#""type":"assistant""#)
    }
}
