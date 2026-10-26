import Foundation

// 部門島（10-12 決策板：像素豆 Kubo、全部陶土橘、光圈＋泡泡＋動作、皇冠／耳機／眼鏡）。
// 看板的另一種看法：一個專案一座島，島上一個 session 一個角色。這裡只有分組與狀態對應，畫面在 ShoWorkAgent/IslandView。

/// 角色的樣子，跟看板欄位一對一，只是換成角色看得懂的話
public enum Mood: String, Sendable, CaseIterable {
    case working    // 進行中：紫光圈、打字
    case waiting    // 等你回答／AI 要你決定：紅「!」、跳
    case finished   // 做完了你還沒看：綠勾、搖擺
    case stuck      // 卡住：橘「?」
    case idle       // 做完你也看過了：沒有光圈、喝咖啡休息（10-15 Kang：跟「從來沒用過」分開）
    case asleep     // 開了 claude 但從來沒交代過事：閉眼、頭上 Zzz

    public static func of(_ c: BoardCard) -> Mood {
        switch c.column {
        case .active: .working
        case .review: c.reason == "等你回答" || c.reason.hasPrefix("要你決定") ? .waiting : .finished
        case .stuck: .stuck
        case .done, .todo: c.unused ? .asleep : .idle
        }
    }
}

public enum Accessory: String, Sendable {
    case crown, headset, glasses
}

public struct Islander: Sendable, Equatable, Identifiable {
    public var card: BoardCard
    public var mood: Mood
    public var accessory: Accessory?
    public var id: String { card.id }
}

public struct Island: Sendable, Equatable, Identifiable {
    public var project: String
    public var people: [Islander]
    public var queued: Int                  // 排隊中的訊息（看板上的待辦卡）
    public var ghosts: [Islander] = []      // 別座島的人 cd 過來逛一下（影分身，本尊留在自己島上）
    public var id: String { project }

    public func count(_ m: Mood) -> Int { people.filter { $0.mood == m }.count }
    /// 要你處理的：等你回答＋做完沒看＋卡住
    public var needsYou: Int { people.filter { [.waiting, .finished, .stuck].contains($0.mood) }.count }
}

public enum Islands {
    /// 回訊息類（戴耳機）：預設是秘書、電話窗口
    public static let defaultHeadsetProjects = ["ProjectC", "ProjectE"]
    /// 研究／審核類（戴眼鏡）：看標題
    static let glassesWords = ["研究", "審核", "審查", "盤點", "review", "research", "audit"]

    public static func accessory(_ c: BoardCard, headsetProjects: [String]) -> Accessory? {
        if c.captain { return .crown }
        if headsetProjects.contains(where: { $0.caseInsensitiveCompare(c.project) == .orderedSame }) { return .headset }
        let t = c.title.lowercased()
        if glassesWords.contains(where: { t.contains($0) }) { return .glasses }
        return nil
    }

    /// 排序：要你處理的島在前，其次是在忙的，最後才是全閒置的；島內同理
    public static func build(_ cards: [BoardCard], headsetProjects: [String] = defaultHeadsetProjects) -> [Island] {
        var order: [String] = []
        var people: [String: [Islander]] = [:]
        var queued: [String: Int] = [:]
        for c in cards {
            if !order.contains(c.project) { order.append(c.project) }
            if c.id.contains("#") { queued[c.project, default: 0] += 1; continue }
            people[c.project, default: []].append(Islander(card: c, mood: Mood.of(c), accessory: accessory(c, headsetProjects: headsetProjects)))
        }
        func rank(_ m: Mood) -> Int { [.waiting: 0, .stuck: 1, .finished: 2, .working: 3, .idle: 4, .asleep: 5][m] ?? 6 }
        let islands = order.compactMap { p -> Island? in
            let ps = (people[p] ?? []).enumerated().sorted { (rank($0.element.mood), $0.offset) < (rank($1.element.mood), $1.offset) }.map(\.element)
            if ps.isEmpty && (queued[p] ?? 0) == 0 { return nil }
            return Island(project: p, people: ps, queued: queued[p] ?? 0)
        }
        // 影分身：只去已經有的島（不為了逛一下多開一座，整個版面會重排）
        var withGhosts = islands
        for i in withGhosts.indices {
            withGhosts[i].ghosts = islands.flatMap(\.people).filter { $0.card.visiting == withGhosts[i].project }
        }
        let islands2 = withGhosts
        func islandRank(_ i: Island) -> Int { i.needsYou > 0 ? 0 : i.count(.working) > 0 ? 1 : 2 }
        return islands2.enumerated().sorted { (islandRank($0.element), $0.offset) < (islandRank($1.element), $1.offset) }.map(\.element)
    }
}

/// 卡片排法（10-12 Kang：每張一樣大、全部剛好塞滿視窗）。試每一種欄數，挑讓卡片最大的。
public struct IslandGrid: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public var width: Double
    public var height: Double

    /// `aspect`＝卡片理想的寬高比（島在左、對話框在右，偏寬）；高度低於 `minHeight` 就不硬塞，改成可以往下捲
    public static func fit(count: Int, width W: Double, height H: Double, gap: Double = 12,
                           aspect: Double = 1.7, minHeight: Double = 170, minWidth: Double = 300) -> IslandGrid {
        let n = max(count, 1)
        var best = IslandGrid(cols: 1, rows: n, width: W, height: H)
        var bestScore = -Double.infinity
        for c in 1...n {
            let r = (n + c - 1) / c
            if (r - 1) * c >= n { continue }                    // 最後一列整列空著 ⇒ 跟少一欄一樣，跳過
            let w = (W - Double(c - 1) * gap) / Double(c)
            let h = (H - Double(r - 1) * gap) / Double(r)
            guard w > 0, h > 0, c == 1 || w >= minWidth else { continue }   // 太窄放不下對話框 ⇒ 寧可少欄、往下捲
            // 卡片「有效大小」：太扁就被寬度卡、太高就被高度卡
            let score = min(w / aspect, h)
            if score > bestScore { bestScore = score; best = IslandGrid(cols: c, rows: r, width: w, height: max(h, minHeight)) }
        }
        return best
    }
}
