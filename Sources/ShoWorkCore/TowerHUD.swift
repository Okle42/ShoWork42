import Foundation

// 科技大樓的「戰情」資訊層（10-20 第 2 棒 UI/UX 優化，規劃 docs/design/office-tower/UIUX優化規劃.md §2）。
//   原則：3D 大樓負責氣氛與空間記憶；文字一律畫在螢幕空間（固定點數，不跟著樓層縮小）。
//   這裡只有純邏輯（可測）：頂部「需要你」列的計數、左側樓層索引列的每一行、螢幕空間標籤的碰撞避讓。
//   畫面在 ShoWorkAgent/OfficeView.swift（索引列、需要你列）與 OfficeLabels.swift（CALayer 螢幕空間標籤）。

// MARK: - 頂部「需要你」列

public struct AttentionSummary: Sendable, Equatable {
    public var waiting: [String] = []      // 等你回答／要你決定（卡片 id，最早的在前）
    public var stuck: [String] = []        // 卡住
    public var finished: [String] = []     // 做完了你還沒看
    public var working = 0                 // 在做
    public var people = 0                  // 總人數（不含排隊中的訊息）
    public var floors = 0                  // 有人的樓層數
    public init() {}

    public var isEmpty: Bool { waiting.isEmpty && stuck.isEmpty && finished.isEmpty }

    /// 依時間先後（最後活動早的先輪到；一樣就照 id）
    public static func make(_ cards: [BoardCard]) -> AttentionSummary {
        var s = AttentionSummary()
        let real = cards.filter { !$0.id.contains("#") }
        let ordered = real.sorted { a, b in
            let ta = a.lastActivity ?? .distantPast, tb = b.lastActivity ?? .distantPast
            return ta != tb ? ta < tb : a.id < b.id
        }
        for c in ordered {
            switch Mood.of(c) {
            case .waiting: s.waiting.append(c.id)
            case .stuck: s.stuck.append(c.id)
            case .finished: s.finished.append(c.id)
            case .working: s.working += 1
            case .idle, .asleep: break
            }
        }
        s.people = real.count
        s.floors = Set(real.map { $0.project.lowercased() }).count
        return s
    }

    /// 點「N 等你」輪流：上一次是誰 → 下一個（沒有上一次或上一次不在了 ⇒ 第一個）
    public static func next(after last: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let last, let i = ids.firstIndex(of: last) else { return ids[0] }
        return ids[(i + 1) % ids.count]
    }
}

// MARK: - 左側樓層索引列

public struct FloorRailRow: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case roof, project, idle, lobby }
    public var kind: Kind
    public var id: String               // TowerFloor.id
    public var floorNo: String          // 06、RF、01；閒置＝空字串
    public var title: String            // 專案名／空中花園／閒置 N／大廳・保全
    public var subtitle: String         // 主題中文名（專案）、「緩衝中」等
    public var accent: String?          // 識別色
    public var waiting = 0, stuck = 0, finished = 0, working = 0, people = 0
    public var active = true            // 專案樓層：現在有 AI（false＝2 小時緩衝中）
    public var idleNames: [IdlePlate] = []   // 閒置那一行展開的清單
    public init(kind: Kind, id: String, floorNo: String, title: String, subtitle: String, accent: String? = nil) {
        self.kind = kind; self.id = id; self.floorNo = floorNo; self.title = title; self.subtitle = subtitle; self.accent = accent
    }
}

public enum TowerIndex {
    /// 由上往下＝大樓由上往下：RF、每個專案樓層、閒置 N、01 大廳。`moods`＝專案（小寫）→ 每個人的狀態
    public static func rows(_ plan: TowerPlan, decor: [String: FloorDecor], moods: [String: [Mood]]) -> [FloorRailRow] {
        var out: [FloorRailRow] = []
        for f in plan.floors.reversed() {
            switch f.kind {
            case .roof:
                out.append(FloorRailRow(kind: .roof, id: f.id, floorNo: "RF", title: "空中花園", subtitle: "休息區", accent: "#5C7F55"))
            case .project:
                let k = (f.project ?? "").lowercased()
                let d = decor[k]
                var r = FloorRailRow(kind: .project, id: f.id, floorNo: f.floorNo, title: f.project ?? f.id,
                                     subtitle: d?.theme.title ?? "還沒決定主題", accent: d?.theme.accent)
                let m = moods[k] ?? []
                r.waiting = m.filter { $0 == .waiting }.count
                r.stuck = m.filter { $0 == .stuck }.count
                r.finished = m.filter { $0 == .finished }.count
                r.working = m.filter { $0 == .working }.count
                r.people = m.count
                r.active = f.active
                if !f.active { r.subtitle += "・燈暗（2 小時內有人）" }
                out.append(r)
            case .idle:
                var r = FloorRailRow(kind: .idle, id: f.id, floorNo: "", title: "閒置 \(f.plates.count)", subtitle: "沒有 AI 的專案")
                r.idleNames = f.plates
                out.append(r)
            case .lobby:
                out.append(FloorRailRow(kind: .lobby, id: f.id, floorNo: "01", title: "大廳・保全", subtitle: "前台"))
            }
        }
        return out
    }
}

// MARK: - 螢幕空間標籤的碰撞避讓

/// 標籤種類＝優先序（等你 > 卡住 > 做完 > 工作中 > 休息；樓層名、保全、閒置名字另外排）
public enum LabelKind: Int, Sendable, Comparable {
    // 10-21 外部空間城市：cityAlert＝設備警示（跟等你同級、一定要畫）、city＝城市名牌（小字、擠不下就不畫）
    case waiting = 0, stuck, finished, cityAlert, guardian, floor, working, rest, city, idleName, more
    public static func < (a: LabelKind, b: LabelKind) -> Bool { a.rawValue < b.rawValue }
    /// 6 個位置都撞到時：true＝在自己那層裡找空位（一定要看得到）；false＝不畫、算進樓層的「+N」
    public var mustShow: Bool { self <= .guardian }
}

/// 一個標籤：錨點（頭頂在畫面上的點，y 往上）＋大小（點）
public struct LabelBox: Sendable, Equatable {
    public var id: String
    public var kind: LabelKind
    public var ax: Double, ay: Double
    public var w: Double, h: Double
    public var group: String           // 樓層 id（被藏起來的算進這層的 +N）
    /// 這個人所在樓層在畫面上的上下界（y 往上）：標籤不得超過自己那層的天花（10-20 第 4 棒：評審抓到 02 樓的人的標籤畫在 03 樓地坪上）
    public var ceil: Double, floorY: Double
    public init(id: String, kind: LabelKind, ax: Double, ay: Double, w: Double, h: Double, group: String = "",
                ceil: Double = .infinity, floorY: Double = -.infinity) {
        self.id = id; self.kind = kind; self.ax = ax; self.ay = ay; self.w = w; self.h = h; self.group = group
        self.ceil = ceil; self.floorY = floorY
    }
}

public struct PlacedLabel: Sendable, Equatable {
    public var id: String
    public var kind: LabelKind
    public var x: Double, y: Double, w: Double, h: Double   // 左下角＋大小（y 往上）
    public var leader: Bool            // 被往上推了：從標籤底畫一條線到錨點
    public var ax: Double, ay: Double
    public init(id: String, kind: LabelKind, x: Double, y: Double, w: Double, h: Double, leader: Bool, ax: Double, ay: Double) {
        self.id = id; self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h; self.leader = leader; self.ax = ax; self.ay = ay
    }
    public func overlaps(_ o: PlacedLabel, gap: Double = 0) -> Bool {
        x < o.x + o.w + gap && o.x < x + w + gap && y < o.y + o.h + gap && o.y < y + h + gap
    }
}

public enum LabelLayout {
    public static let gap = 4.0

    /// 依優先序放（10-20 第 4 棒改：標籤一律留在自己那層裡）：
    ///   1. 試 6 個位置：頭頂正上、往上一格（畫引線）、左上、右上、頭的左邊、頭的右邊；超過那層天花（ceil）或低於地坪（floorY）的不算
    ///   2. 都撞到：在那層的範圍裡一列一列找（由頭頂往上、再往下；每列左右輪流挪），第一個空位
    ///   3. 還是沒有：等你／卡住／做完／保全照樣找不到就算進那層的 +N（呼叫端把 +N 標成紅色）；工作中／休息直接收進 +N
    ///   `fixed`＝先放好的（樓層名）：當障礙物，不回傳。`bounds`＝畫面寬高（標籤夾在畫面內）
    public static func place(_ boxes: [LabelBox], width: Double, height: Double, fixed: [PlacedLabel] = []) -> (placed: [PlacedLabel], hidden: [String: Int]) {
        var placed: [PlacedLabel] = []
        var taken = fixed
        var hidden: [String: Int] = [:]
        let order = boxes.enumerated().sorted { a, b in
            a.element.kind != b.element.kind ? a.element.kind < b.element.kind : (a.element.ay != b.element.ay ? a.element.ay > b.element.ay : a.offset < b.offset)
        }.map(\.element)
        func clampX(_ x: Double, _ w: Double) -> Double { min(max(2, x), max(2, width - w - 2)) }
        func clampY(_ y: Double, _ h: Double) -> Double { min(max(2, y), max(2, height - h - 2)) }     // 頭頂在畫面最上緣（頂樓的人）也不要被切掉
        func free(_ p: PlacedLabel) -> Bool { !taken.contains { $0.overlaps(p, gap: 1) } }
        for b in order {
            let top = min(b.ceil, height - 2), bottom = max(b.floorY, 2)
            func inFloor(_ p: PlacedLabel) -> Bool { p.y + p.h <= top + 0.5 && p.y >= bottom - 0.5 }
            func make(_ x: Double, _ y: Double) -> PlacedLabel {
                let px = clampX(x, b.w), py = clampY(y, b.h)
                // 引線：標籤在頭頂正上方（水平蓋過錨點）而且離頭頂超過一格才畫
                let lead = px <= b.ax && b.ax <= px + b.w && py > b.ay + gap + b.h * 0.5
                return PlacedLabel(id: b.id, kind: b.kind, x: px, y: py, w: b.w, h: b.h, leader: lead, ax: b.ax, ay: b.ay)
            }
            let y0 = b.ay + gap
            let side = b.ay - b.h * 0.85
            let cands: [(Double, Double)] = [
                (b.ax - b.w / 2, y0),
                (b.ax - b.w / 2, y0 + b.h + gap),
                (b.ax - b.w - gap, y0),
                (b.ax + gap, y0),
                (b.ax - b.w - 14, side),
                (b.ax + 14, side),
            ]
            var got: PlacedLabel?
            for c in cands {
                let p = make(c.0, c.1)
                if inFloor(p) && free(p) { got = p; break }
            }
            if got == nil {
                // 在自己那層裡找：等你／卡住／做完／保全找遍整層；工作中、休息只在頭附近（左右各 8 個半格）找，再擠不下就收進 +N
                var rows: [Double] = []
                var y = max(bottom, 2)
                while y + b.h <= top + 0.5 { rows.append(y); y += (b.h + gap) / 2 }
                // 每個候選位置按「離頭頂多近」排序，挑最近的空位（10-20 第 4 棒：原本一列一列找，名牌會跑到 80 pt 外）
                let step = b.w / 4 + gap
                let reach = b.kind.mustShow ? 24 : 8
                var spots: [(Double, PlacedLabel)] = []
                for ry in rows {
                    for k in -reach...reach {
                        let p = make(b.ax - b.w / 2 + Double(k) * step, ry)
                        guard inFloor(p) else { continue }
                        let dx = max(p.x - b.ax, 0, b.ax - (p.x + p.w)), dy = max(p.y - b.ay, 0, b.ay - (p.y + p.h))
                        spots.append((hypot(dx, dy), p))
                    }
                }
                got = spots.sorted { $0.0 < $1.0 }.first { free($0.1) }?.1
            }
            if let p = got { placed.append(p); taken.append(p) }
            else { hidden[b.group, default: 0] += 1 }
        }
        return (placed, hidden)
    }

    /// 放好的標籤之間有沒有重疊（驗收印 overlaps=0）
    public static func overlaps(_ p: [PlacedLabel]) -> Int {
        var n = 0
        for i in p.indices { for j in p.indices where j > i && p[i].overlaps(p[j]) { n += 1 } }
        return n
    }
}
