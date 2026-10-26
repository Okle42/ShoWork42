import Foundation

// 工作卡片自動轉送隊長（派工 T1021174030，10-21 Kang 拍板：隊長只審不做，每個 AI 工作時都要向隊長報告方法與工具）。
// 任何 session 跑 showork card，看板就把卡片內容以【工作回報】送給現任隊長（走派工回報同一條 Peer 路）。
//   • 隊長自己的卡不轉（迴圈）；隊長不在線就不送、也不堆積（那段期間的卡記成已看過）
//   • 不阻塞：發卡的 session 不等回覆
//   • 節流：同一 session 60 秒內只送一次（期間的新卡等時間到送最後一張）；內容沒變不重送
//   • 看板剛啟動時現有的卡當成已看過，不一次灌給隊長
//   • 設定 captain.relayCards（預設開）

public enum CardRelay {
    public static let settingKey = "captain.relayCards"
    public static let minInterval: TimeInterval = 60
    /// 太舊的卡不轉（看板重開、隊長剛回來時不翻舊帳）
    public static let maxAge: TimeInterval = 10 * 60

    public struct State: Sendable, Equatable {
        public var sentKey: [String: String] = [:]     // sessionId → 上次送出（或看過）的內容
        public var sentAt: [String: Date] = [:]
        public var seeded = false
        public var lastStart: [String: (doing: String, at: Date)] = [:]   // 開工卡：同一個任務 10 分鐘內不重送
        public init() {}
        public static func == (a: State, b: State) -> Bool {
            a.sentKey == b.sentKey && a.sentAt == b.sentAt && a.seeded == b.seeded
                && a.lastStart.mapValues(\.doing) == b.lastStart.mapValues(\.doing) && a.lastStart.mapValues(\.at) == b.lastStart.mapValues(\.at)
        }
    }

    public struct Outgoing: Sendable, Equatable {
        public var sessionId: String
        public var text: String
    }

    /// 內容指紋：這些都沒變就不重送（時間不算）
    public static func key(_ r: SelfReport) -> String {
        let nums: [String] = [r.status.rawValue, r.progress.map(String.init) ?? "", r.confidence.map(String.init) ?? ""]
        let texts: [String] = [r.summary ?? "", r.ask ?? "", (r.options ?? []).joined(separator: "|"), r.report ?? "", r.doing ?? "", r.how ?? "",
                               r.kind ?? "", r.touch ?? "", r.outward ?? ""]
        return (nums + texts).joined(separator: "\u{1F}")
    }

    /// 這次刷新要送哪些。captain＝現任隊長 sessionId（nil 或不在線 ⇒ 不送，全部記成看過）
    public static func plan(reports: [String: SelfReport], captain: String?, captainLive: Bool,
                            state: inout State, now: Date = Date(), text: (String, SelfReport) -> String) -> [Outgoing] {
        if !state.seeded {
            for (sid, r) in reports { state.sentKey[sid] = key(r) }
            state.seeded = true
            return []
        }
        var out: [Outgoing] = []
        for sid in reports.keys.sorted() {
            guard let r = reports[sid] else { continue }
            let k = key(r)
            if state.sentKey[sid] == k { continue }
            // 派工單的做完／要你決定／卡住已經有【派工回報】（TaskRouter），不重複送（10-21 隊長審查建議）
            let routed = r.task != nil && r.status != .working
            guard let cap = captain, captainLive, sid != cap, !routed, now.timeIntervalSince(r.at) < maxAge else {
                state.sentKey[sid] = k                     // 不送也不堆積
                continue
            }
            // 等時間到再送最後一張；開工卡不等（T1024033803 ①：隊長 1 分鐘內要收到）
            if !r.isStart, let t = state.sentAt[sid], now.timeIntervalSince(t) < minInterval { continue }
            if r.isStart {
                let d = r.doing ?? ""
                if let l = state.lastStart[sid], l.doing == d, now.timeIntervalSince(l.at) < CaptainLink.newTaskGap { state.sentKey[sid] = k; continue }
                state.lastStart[sid] = (d, now)
            }
            state.sentKey[sid] = k
            state.sentAt[sid] = now
            out.append(Outgoing(sessionId: sid, text: text(sid, r)))
        }
        return out
    }

    /// 【工作回報】全文（開工卡＝【開工】：打算怎麼做、會動到什麼、有沒有對外動作）
    public static func text(name: String, project: String?, report r: SelfReport) -> String {
        func cut(_ s: String, _ n: Int = 300) -> String { s.count > n ? String(s.prefix(n)) + "⋯" : s }
        if r.isStart {
            var head = "【開工】\(name)"
            if let p = project, !p.isEmpty { head += "（\(p)）" }
            if let d = r.doing { head += "：\(d)" }
            var lines = [head]
            if let s = r.summary, !s.isEmpty { lines.append("要做什麼：\(cut(s))") }
            lines.append("打算怎麼做：" + (r.how.map { cut($0) } ?? "（沒寫 --how）"))
            lines.append("會動到：" + (r.touch.map { cut($0) } ?? "（沒寫 --touch）"))
            lines.append("對外動作：" + (r.outward.map { cut($0) } ?? "（沒寫 --outward）"))
            if let t = r.task { lines.append("派工單：\(t)") }
            lines.append("（對方不等你回覆、已經開始做；要修正就 SendMessage 給它，下一輪會收到）")
            return lines.joined(separator: "\n")
        }
        var head = "【工作回報】\(name)"
        if let p = project, !p.isEmpty { head += "（\(p)）" }
        if let d = r.doing { head += "：\(d)" }
        var lines = [head]
        var st = "狀態 \(r.status.rawValue)"
        if let p = r.progress { st += "・完成度 \(p)%" }
        if let c = r.confidence { st += "・信心 \(c)%" }
        lines.append(st)
        if let s = r.summary, !s.isEmpty { lines.append("摘要：\(cut(s))") }
        lines.append("方法與工具：" + (r.how.map { cut($0) } ?? "（沒寫 --how）"))
        if let a = r.ask {
            lines.append("問使用者：\(cut(a))" + ((r.options ?? []).isEmpty ? "" : "（選項：\(r.options!.joined(separator: "／"))）"))
        }
        if let rp = r.report { lines.append("報告：\(rp)") }
        if let t = r.task { lines.append("派工單：\(t)") }
        lines.append("（看板自動轉送，對方不等你回覆；有疑慮再 SendMessage 給它）")
        return lines.joined(separator: "\n")
    }
}
