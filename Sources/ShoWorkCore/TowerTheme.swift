import Foundation

// 樓層主題（10-20，規範 §2、§5）：每層的風格由 AI 從主題庫挑（主題＋識別色＋2–3 件專屬擺設），結果快取在 board/themes/<專案>.json。
//   沒有結果前先用本地關鍵字評分（WorkSignature）挑一個，不阻塞畫面。
//   重新裝潢只在「一輪工作結束」那次刷新檢查：工作內容明顯變了（分數門檻＋Jaccard 門檻）、同專案 6 小時一次、全部合計 24 小時 8 次、
//   US$0.10／24h、失敗後 1 小時不再試、同時只跑一個。呼叫 claude -p（haiku）走你的訂閱；runner 可注入（測試不准真的呼叫）。

// MARK: - 主題庫

public enum TowerTheme: String, Codable, Sendable, CaseIterable {
    case monitor, app_studio, library, print_shop, call_room, trading_desk, media_studio, design_studio
    case legal_room, ledger_room, game_lab, hw_lab, marketing, dispatch_room, drafting_room, general

    public var title: String {
        switch self {
        case .monitor: "監控中心"
        case .app_studio: "App 開發室"
        case .library: "研究書房"
        case .print_shop: "3D 列印工坊"
        case .call_room: "秘書電話室"
        case .trading_desk: "交易室"
        case .media_studio: "攝影棚"
        case .design_studio: "設計工作室"
        case .legal_room: "法務室"
        case .ledger_room: "財務帳房"
        case .game_lab: "遊戲工作室"
        case .hw_lab: "硬體實驗室"
        case .marketing: "行銷室"
        case .dispatch_room: "調度中心"
        case .drafting_room: "建築製圖室"
        case .general: "通用辦公"
        }
    }

    /// 一句適用說明（放進提示詞）
    public var blurb: String {
        switch self {
        case .monitor: "看板、監控、常駐服務、log"
        case .app_studio: "iOS/macOS/Android App、上架"
        case .library: "研究、調查、寫報告、文件多於程式"
        case .print_shop: "3D 列印、CAD、模型、外殼"
        case .call_room: "LINE／信箱／電話代理、行事曆、提醒"
        case .trading_desk: "股票、回測、投資工具"
        case .media_studio: "影片、配音、分鏡、宣傳片"
        case .design_studio: "介面設計、品牌、名片、排版"
        case .legal_room: "合約、NDA、授權、條款"
        case .ledger_room: "記帳、報價、發票、還款、預算"
        case .game_lab: "遊戲、關卡、角色美術、撲克工具"
        case .hw_lab: "藍牙、音訊、風扇、電路、韌體"
        case .marketing: "社群貼文、廣告、官網、宣傳"
        case .dispatch_room: "派車、派單、航班、行程、地圖"
        case .drafting_room: "平面圖、室內設計、水電、建築"
        case .general: "通用辦公（判斷不出來時用）"
        }
    }

    /// 預設識別色（規範 §2.1）
    public var accent: String {
        switch self {
        case .monitor: "#5B8DB8"
        case .app_studio: "#4E9C8F"
        case .library: "#9C6B4E"
        case .print_shop: "#C98B3C"
        case .call_room: "#8C7BB5"
        case .trading_desk: "#3F8F5A"
        case .media_studio: "#B5525A"
        case .design_studio: "#D08A6E"
        case .legal_room: "#4A5A7A"
        case .ledger_room: "#A88C3E"
        case .game_lab: "#7A5FA8"
        case .hw_lab: "#C2703A"
        case .marketing: "#C56B86"
        case .dispatch_room: "#3E8FA8"
        case .drafting_room: "#6E8A6A"
        case .general: "#8F8B85"
        }
    }

    /// 可選擺設（AI 從這裡＋通用擺設挑 2–3 件；第一件、第二件是本地預設）
    public var optionalProps: [String] {
        switch self {
        case .monitor: ["console", "server_rack", "wall_clock"]
        case .app_studio: ["standing_desk", "device_cart", "whiteboard"]
        case .library: ["long_table", "floor_lamp", "card_catalog", "globe"]
        case .print_shop: ["workbench", "filament_rack", "finished_shelf"]
        case .call_room: ["sofa", "side_table", "mail_rack", "switchboard"]
        case .trading_desk: ["quad_monitor", "bull_statue", "safe"]
        case .media_studio: ["softbox", "camera_tripod", "edit_bay"]
        case .design_studio: ["drafting_table", "material_shelf", "easel"]
        case .legal_room: ["file_cabinet", "law_shelf", "seal_desk"]
        case .ledger_room: ["wall_clock", "receipt_tray", "cashier_counter", "ledger_shelf"]
        case .game_lab: ["sofa", "sprite_wall", "controller_shelf", "trophy_shelf"]
        case .hw_lab: ["parts_wall", "soldering_station", "test_rig"]
        case .marketing: ["ring_light", "product_table", "sofa"]
        case .dispatch_room: ["flight_board", "key_cabinet", "wall_clock"]
        case .drafting_room: ["plan_chest", "model_plinth", "section_wall"]
        case .general: ["plant_low", "coffee_cart"]
        }
    }

    /// 判斷關鍵字（規範 §2.1；10-20 UI/UX 優化 §4.3 修正：拿掉太泛的 status／watch／log／step／docs/／license／ui，
    /// 小寫 line 是程式用語 ⇒ 改成只認大寫 LINE（見 caseSensitive）；補上 28 個常駐專案判錯的關鍵字）。
    /// 純英數字的照「詞」比對，其他（中文、含 . / 空白 - 的）照子字串比對
    public var keywords: [String] {
        switch self {
        case .monitor: ["monitor", "dashboard", "daemon", "launchd", "statusline", "fan", "fans", "wifi", "temperature", "監控", "看板", "守門", "溫度", "巡檢",
                        "戰情", "command center", "menu bar", "menu-bar", "menubar", "terminal", "終端機", "mouse", "滑鼠", "螢幕控制", "screen control", "選單列"]
        case .app_studio: ["swiftui", "xcode", "ios", "iphone", "ipad", "android", "kotlin", "testflight", "app store", "info.plist", ".xcodeproj", "上架", "送審", "nfc"]
        case .library: ["research", "survey", "paper", "研究", "報告", "調查", "文獻"]
        case .print_shop: ["stl", "3mf", ".step", ".stp", "fusion", "blender", "picogk", "build123d", "cad", "bambu", "列印", "切片", "公仔", "外殼", "浮雕", "模型", "cnc", "雕刻", "sdf"]
        case .call_room: ["adb", "tablet", "hotline", "gmail", "calendar", "responder", "秘書", "平板", "電話", "訊息", "好友", "提醒", "行事曆", "LINE 群", "LINE 帳號", "接聽"]
        case .trading_desk: ["stock", "ticker", "backtest", "trade", "k線", "股票", "回測", "交易", "期貨", "盤後", "投資"]
        case .media_studio: ["video", "ffmpeg", "mp4", "mov", "higgsfield", "kling", "veo", "tts", "剪輯", "影片", "分鏡", "配音", "字幕", "reels", "宣傳片"]
        case .design_studio: ["design", "figma", "hig", "ui/ux", "css", "font", "logo", "設計", "配色", "品牌", "名片", "版型", "排版", "字型", "介面", "guidelines"]
        case .legal_room: ["nda", "agreement", "contract", "license agreement", "terms", "privacy", "合約", "條款", "授權書", "簽署", "分潤", "法規", "隱私權", "協議書"]
        case .ledger_room: ["invoice", "ledger", "budget", "xlsx", "csv", "accountant", "finance", "spreadsheet", "帳", "財務", "記帳", "報價", "發票", "預算", "還款", "薪資", "成本", "試算表"]
        case .game_lab: ["game", "spritekit", "unity", "godot", "sprite", "level", "poker", "holdem", "遊戲", "關卡", "角色", "手感", "玩家", "撲克", "德州", "牌桌"]
        case .hw_lab: ["bluetooth", "ble", "coreaudio", "smc", "usb", "esp32", "arduino", "firmware", "speaker", "speakers", "audio", "latency", "microphone", "volume",
                       "display", "h.264", "藍牙", "音訊", "喇叭", "電路", "感測", "馬達", "韌體", "螢光棒", "延伸螢幕"]
        case .marketing: ["instagram", "ig", "threads", "seo", "landing", "campaign", "promo", "行銷", "貼文", "廣告", "文案", "曝光", "粉絲", "官網", "月費", "方案", "中小企業", "落地", "宣傳"]
        case .dispatch_room: ["dispatch", "ride", "flight", "fr24", "tdx", "route", "map", "派車", "派單", "接機", "航班", "行程", "司機", "車隊", "路線", "接送", "包車", "抓單"]
        case .drafting_room: ["dxf", "dwg", "floorplan", "ifc", "room", "平面圖", "建築", "室內", "水電", "給排水", "剖面", "格局", "裝潢", "建案", "拆圖", "圖檔", "工程圖", "bom"]
        case .general: []
        }
    }

    /// 只算半分的關鍵字（太常見：研究書房的「比較／分析／評估／索引」）
    public var halfKeywords: [String] {
        switch self {
        case .library: ["比較", "分析", "評估", "索引"]
        default: []
        }
    }

    /// 區分大小寫、照詞比對的（小寫 line 是程式用語，只有大寫 LINE 是通訊軟體）
    public var caseSensitive: [String] {
        switch self {
        case .call_room: ["LINE"]
        default: []
        }
    }

    /// 通用擺設庫（任何主題都可以挑）
    public static let generalProps = ["plant_tall", "plant_low", "sofa", "lounge_chair", "coffee_cart", "whiteboard", "meeting_table", "bench", "wall_clock"]
    /// 識別色只准這 16 個（規範 §1.2）
    public static let palette = ["#5B8DB8", "#4E9C8F", "#9C6B4E", "#C98B3C", "#8C7BB5", "#3F8F5A", "#B5525A", "#D08A6E",
                                 "#4A5A7A", "#A88C3E", "#7A5FA8", "#C2703A", "#C56B86", "#3E8FA8", "#6E8A6A", "#8F8B85"]

    public var allowedProps: Set<String> { Set(optionalProps + Self.generalProps) }
}

// MARK: - 工作內容的特徵（本地評分，不花錢）

/// 要拿來判斷主題的原料。Agent 端從卡片（標題、自報摘要、最後一句話）與 transcript 尾端（你的指示、Edit/Write/Read 的路徑、Bash 指令第一個字）收集
public struct DecorInput: Sendable, Equatable {
    public var project: String
    public var prompts: [String] = []      // 你最近的指示（最多 3 則進提示詞）
    public var notes: [String] = []        // 卡片標題、自報 summary／doing、AI 最後一句（只拿來評分，不進提示詞）
    public var paths: [String] = []        // 改過／讀過的檔案路徑
    public var commands: [String] = []     // Bash 指令第一個字（swift、ffmpeg…）
    public var readme: String?             // README 前 600 字（只有第一次）
    public init(project: String, prompts: [String] = [], notes: [String] = [], paths: [String] = [], commands: [String] = [], readme: String? = nil) {
        self.project = project; self.prompts = prompts; self.notes = notes; self.paths = paths; self.commands = commands; self.readme = readme
    }
}

public struct WorkSignature: Sendable, Equatable {
    public var terms: [String: Int] = [:]          // 前 12 個詞＋次數
    public var scores: [TowerTheme: Int] = [:]     // 每個主題的分數（身分＋工作；提示詞、重新裝潢判斷用）
    public var identity: [TowerTheme: Int] = [:]   // 身分分數：專案名 ×2、README 標題與第一段 ×4、README 其餘 ×1（10-20 §4.3）
    public var work: [TowerTheme: Int] = [:]       // 工作分數：卡片標題／自報／transcript 路徑與指令 ×1
    public var extensions: [String: Int] = [:]     // 副檔名統計（提示詞用）
    public var folders: [String: Int] = [:]        // 資料夾名統計（提示詞用）
    public var commands: [String: Int] = [:]       // 指令統計（提示詞用）
    public init() {}

    static let stop: Set<String> = ["the", "and", "for", "users", "github", "repos", "sources", "src", "md", "json",
                                    "txt", "py", "sh", "swift", "tmp", "private", "claude", "a", "to", "of", "in", "is", "it", "on", NSUserName().lowercased()]

    /// 一段文字對每個主題的命中分數（純英數字照詞、其他照子字串；半分詞 ×0.5；大寫 LINE 區分大小寫照詞）
    static func hits(_ raw: String) -> [TowerTheme: Double] {
        let text = raw.lowercased()
        let words = text.split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.map(String.init)
        var count: [String: Int] = [:]
        for w in words { count[w, default: 0] += 1 }
        var exact: [String: Int] = [:]
        for w in raw.split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII }) { exact[String(w), default: 0] += 1 }
        func n(_ k: String) -> Int {
            let k = k.lowercased()
            if k.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return count[k] ?? 0 }
            return text.components(separatedBy: k).count - 1
        }
        var out: [TowerTheme: Double] = [:]
        for t in TowerTheme.allCases where t != .general {
            var x = 0.0
            for k in t.keywords { x += Double(n(k)) }
            for k in t.halfKeywords { x += Double(n(k)) * 0.5 }
            for k in t.caseSensitive { x += Double(exact[k] ?? 0) }
            if x > 0 { out[t] = x }
        }
        return out
    }

    /// 專案名拆詞：ProjectC → Master Line 42、In_Unison42 → In Unison 42（只用在身分分數）
    public static func splitName(_ s: String) -> String {
        var out = ""
        var prev: Character?
        for c in s {
            if c == "_" || c == "-" || c == "." { out.append(" "); prev = nil; continue }
            if let p = prev, (c.isUppercase && p.isLowercase) || (c.isNumber && p.isLetter) || (c.isLetter && p.isNumber) { out.append(" ") }
            out.append(c); prev = c
        }
        return out
    }

    public static func make(_ inp: DecorInput) -> WorkSignature {
        var s = WorkSignature()
        for p in inp.paths {
            let ext = (p as NSString).pathExtension.lowercased()
            if !ext.isEmpty { s.extensions[ext, default: 0] += 1 }
            for comp in (p as NSString).deletingLastPathComponent.split(separator: "/").suffix(2) where comp.count > 1 && !comp.hasPrefix(".") {
                s.folders[String(comp), default: 0] += 1
            }
        }
        for c in inp.commands where !c.isEmpty { s.commands[c.lowercased(), default: 0] += 1 }
        // 身分：專案名（拆詞、大小寫照原樣）×2＋README 標題與第一段 ×4＋README 其餘 ×1
        let (head, rest) = DecorInput.readmeParts(inp.readme ?? "")
        var id: [TowerTheme: Double] = [:]
        for (t, v) in hits(splitName(inp.project)) { id[t, default: 0] += v * 2 }
        for (t, v) in hits(head) { id[t, default: 0] += v * 4 }
        for (t, v) in hits(rest) { id[t, default: 0] += v }
        // 工作：卡片、你的指示、路徑、指令
        var wk = hits((inp.prompts + inp.notes + inp.paths + inp.commands).joined(separator: "\n"))
        // 研究書房：最近碰的檔案 .md 佔一半以上（規範 §2.1 #3）
        let md = inp.paths.filter { $0.lowercased().hasSuffix(".md") }.count
        if md >= 3, md * 2 >= inp.paths.count { wk[.library, default: 0] += Double(md / 2) }
        func round(_ m: [TowerTheme: Double]) -> [TowerTheme: Int] { m.compactMapValues { v in let r = Int(v.rounded()); return r > 0 ? r : nil } }
        s.identity = round(id); s.work = round(wk)
        s.scores = s.identity.merging(s.work, uniquingKeysWith: +)
        let text = ([inp.project] + inp.prompts + inp.notes + inp.paths + inp.commands + [DecorInput.cleanReadme(inp.readme ?? "")]).joined(separator: "\n").lowercased()
        var count: [String: Int] = [:]
        for w in text.split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII }) { count[String(w), default: 0] += 1 }
        let ranked = count.filter { $0.key.count >= 2 && !stop.contains($0.key) && !$0.key.allSatisfy(\.isNumber) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12)
        s.terms = Dictionary(uniqueKeysWithValues: ranked.map { ($0.key, $0.value) })
        return s
    }

    static func top(_ m: [TowerTheme: Int]) -> (theme: TowerTheme, score: Int)? {
        TowerTheme.allCases.compactMap { t in m[t].map { (t, $0) } }.max { a, b in
            a.1 != b.1 ? a.1 < b.1 : (TowerTheme.allCases.firstIndex(of: a.0)! > TowerTheme.allCases.firstIndex(of: b.0)!)
        }
    }

    /// 身分分數前 n 名（分數 > 0）
    public func identityTop(_ n: Int) -> [TowerTheme] {
        identity.sorted { a, b in a.value != b.value ? a.value > b.value : TowerTheme.allCases.firstIndex(of: a.key)! < TowerTheme.allCases.firstIndex(of: b.key)! }
            .prefix(n).map(\.key)
    }

    /// 主題（10-20 §4.3）：身分最高者；工作分數要換掉它，必須 ≥ 身分最高分 × 2 且命中 ≥ 5。沒有任何身分線索 ⇒ 看工作；全部 0 ＝ general
    public var best: (theme: TowerTheme, score: Int) {
        // 只有合計分數（舊格式、手組的 signature）：照合計最高
        if identity.isEmpty && work.isEmpty { return Self.top(scores) ?? (.general, 0) }
        let w = Self.top(work)
        guard let id = Self.top(identity) else { return w ?? (.general, 0) }
        if let w, w.theme != id.theme, w.score >= 5, w.score >= id.score * 2 { return w }
        return id
    }

    public var scoreStrings: [String: Int] { Dictionary(uniqueKeysWithValues: scores.map { ($0.key.rawValue, $0.value) }) }

    /// 加權 Jaccard：Σmin / Σmax（兩邊都空＝1，完全一樣）
    public static func jaccard(_ a: [String: Int], _ b: [String: Int]) -> Double {
        let keys = Set(a.keys).union(b.keys)
        guard !keys.isEmpty else { return 1 }
        var lo = 0, hi = 0
        for k in keys { let x = a[k] ?? 0, y = b[k] ?? 0; lo += min(x, y); hi += max(x, y) }
        return hi == 0 ? 1 : Double(lo) / Double(hi)
    }
}

// MARK: - 快取（board/themes/<專案>.json，格式照規範 §5.3）

public struct FloorDecor: Codable, Sendable, Equatable {
    public var theme: TowerTheme
    public var accentColor: String
    public var props: [String]
    public var reason: String
    public var source: String            // ai｜local
    public var model: String?
    public var costUSD: Double?
    public var decidedAt: Date
    public var signature: [String: Int]
    public var scores: [String: Int]
    public var floorNo: String?
    public var seconds: Double?          // AI 花了幾秒（除錯用）

    public init(theme: TowerTheme, accentColor: String, props: [String], reason: String, source: String, model: String? = nil,
                costUSD: Double? = nil, decidedAt: Date, signature: [String: Int] = [:], scores: [String: Int] = [:],
                floorNo: String? = nil, seconds: Double? = nil) {
        self.theme = theme; self.accentColor = accentColor; self.props = props; self.reason = reason; self.source = source
        self.model = model; self.costUSD = costUSD; self.decidedAt = decidedAt; self.signature = signature; self.scores = scores
        self.floorNo = floorNo; self.seconds = seconds
    }

    /// 本地評分的結果：分數最高的主題＋預設識別色＋可選件前 2 件
    public static func local(_ sig: WorkSignature, now: Date, reason: String = "依最近工作的關鍵字判斷") -> FloorDecor {
        let t = sig.best.theme
        return FloorDecor(theme: t, accentColor: t.accent, props: Array(t.optionalProps.prefix(2)), reason: reason, source: "local",
                          decidedAt: now, signature: sig.terms, scores: sig.scoreStrings)
    }

    public static func decode(_ d: Data) -> FloorDecor? { try? BoardJSON.decoder.decode(FloorDecor.self, from: d) }
    public func encoded() -> Data? { try? BoardJSON.encoder.encode(self) }
}

// MARK: - 提示詞與解析

public enum DecorPrompt {
    /// 主題庫那段固定（可快取的常數）
    public static let library: String = TowerTheme.allCases.map { t in
        "\(t.rawValue)｜\(t.title)｜\(t.blurb)｜\(t.optionalProps.joined(separator: ", "))"
    }.joined(separator: "\n")

    public static let system = "你是一棟 AI 科技大樓的室內設計師。只輸出一個 JSON 物件，不要任何其他文字。"

    public static func make(_ inp: DecorInput, signature: WorkSignature, current: TowerTheme?) -> String {
        func top(_ m: [String: Int], _ n: Int, prefix: String = "") -> String {
            let s = m.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n)
                .map { "\(prefix)\($0.key) ×\($0.value)" }.joined(separator: "、")
            return s.isEmpty ? "（無）" : s
        }
        let prompts = inp.prompts.suffix(3).map { "  - " + String(Board.plain($0).prefix(160)) }.joined(separator: "\n")
        var lines = [
            "你是一棟 AI 科技大樓的室內設計師。每層樓是一個軟體專案的部門。",
            "請依照這個專案「最近在做的事」，從主題庫挑一個最貼切的樓層主題、一個識別色、2–3 件專屬擺設。",
            "風格是克制的現代辦公室：全樓地板一致、家具中性色，識別色只會用在門牌色條和一件主題家具上。",
            "",
            "【專案】\(inp.project)",
            "【目前主題】\(current?.rawValue ?? "無")",
            "【最近工作的線索】",
            "- 你（使用者）最近的指示：" + (prompts.isEmpty ? "（無）" : "\n" + prompts),
            "- 改過／讀過的檔案類型：" + top(signature.extensions, 6, prefix: "."),
            "- 常用指令：" + top(signature.commands, 6),
            "- 資料夾關鍵詞：" + top(signature.folders, 6),
            "- 其他線索（卡片標題、進度摘要）：" + (inp.notes.isEmpty ? "（無）" : inp.notes.prefix(4).map { String(Board.plain($0).prefix(120)) }.joined(separator: "／")),
        ]
        if let r = inp.readme, !r.isEmpty { lines.append("- README 摘要：" + String(r.prefix(600)).replacingOccurrences(of: "\n", with: " ")) }
        lines += [
            "",
            "【主題庫】（只能從這裡選 theme；格式：id｜中文名｜適用｜可選擺設）",
            library,
            "",
            "【通用擺設】" + TowerTheme.generalProps.joined(separator: ", "),
            "【識別色】只能從這 16 個挑：" + TowerTheme.palette.joined(separator: ", "),
            "",
            "只輸出一個 JSON 物件，不要任何其他文字：",
            ##"{"theme": "...", "accentColor": "#RRGGBB", "props": ["...", "..."], "reason": "..."}"##,
            "規則：props 2–3 個、不重複、只能從該主題的可選擺設或通用擺設裡挑；reason 用繁體中文、30 字以內，說明為什麼。",
        ]
        return lines.joined(separator: "\n")
    }

    /// 解析 AI 的回答＋驗證（規範 §5.3）。theme 不認得 ⇒ nil（呼叫端改用本地結果）；識別色不在 16 色裡 ⇒ 主題預設色；
    /// props 只留合法的、去重、最多 3 件，不到 2 件用該主題可選件補；容忍 ```json 圍欄
    public static func parse(_ text: String, signature: WorkSignature, model: String, cost: Double?, now: Date) -> FloorDecor? {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e,
              let o = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any],
              let t = (o["theme"] as? String).flatMap({ TowerTheme(rawValue: $0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        // 10-20 §4.3：識別色一律用主題預設色（AI 自己挑的色跟主題色不一致，同一主題兩種色，識別色就沒意義了）
        let accent = t.accent
        var props: [String] = []
        for p in (o["props"] as? [String]) ?? [] where t.allowedProps.contains(p) && !props.contains(p) && props.count < 3 { props.append(p) }
        for p in t.optionalProps + TowerTheme.generalProps where props.count < 2 && !props.contains(p) { props.append(p) }
        let reason = String(((o["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return FloorDecor(theme: t, accentColor: accent, props: props, reason: reason, source: "ai", model: model, costUSD: cost,
                          decidedAt: now, signature: signature.terms, scores: signature.scoreStrings)
    }
}

// MARK: - 什麼時候問 AI（規範 §5.4）

/// 呼叫紀錄（board/decor_ledger.json）：滾動 24 小時的次數、成本、失敗退避
public struct DecorLedger: Codable, Sendable, Equatable {
    public struct Call: Codable, Sendable, Equatable {
        public var at: Date
        public var project: String       // 小寫
        public var cost: Double?
        public var ok: Bool
        public var seconds: Double?
        public init(at: Date, project: String, cost: Double?, ok: Bool, seconds: Double? = nil) {
            self.at = at; self.project = project.lowercased(); self.cost = cost; self.ok = ok; self.seconds = seconds
        }
    }
    public var calls: [Call] = []
    public init() {}

    public func recent(_ now: Date, within: TimeInterval = 86400) -> [Call] { calls.filter { now.timeIntervalSince($0.at) < within } }
    /// 只留 2 天內的（檔案不會一直長）
    public mutating func prune(_ now: Date) { calls = calls.filter { now.timeIntervalSince($0.at) < 2 * 86400 } }

    public static func decode(_ d: Data) -> DecorLedger? { try? BoardJSON.decoder.decode(DecorLedger.self, from: d) }
    public func encoded() -> Data? { try? BoardJSON.encoder.encode(self) }
}

public struct DecorLimits: Sendable, Equatable {
    public var perProject: TimeInterval = 6 * 3600     // 同專案兩次問 AI／換裝至少間隔
    public var perDay = 8                              // 全部專案合計滾動 24 小時
    public var costPerDay = 0.10                       // US$／滾動 24 小時
    public var assumedCost = 0.01                      // 沒回傳成本的那次以這個計
    public var failBackoff: TimeInterval = 3600        // 失敗後多久不再試（同專案）
    public var minHits = 3                             // 新主題至少命中幾次
    public var ratio = 2.0                             // 新主題分數 ≥ 舊主題 × 這個
    public var jaccard = 0.5                           // 新舊 signature 相似度 < 這個才算「真的變了」
    public init() {}
}

public enum DecorDecision: Sendable, Equatable {
    case keep(String)                // 不動（原因，除錯用）
    case local                       // 第一次、AI 不能問 ⇒ 先用本地評分
    case ask(String)                 // 問 AI（原因）
}

public enum DecorPolicy {
    /// 現在能不能再問 AI（頻率／成本／失敗退避／同時一個）；不行回傳原因
    public static func blocked(project: String, ledger: DecorLedger, running: Bool, enabled: Bool, force: Bool,
                               limits: DecorLimits = DecorLimits(), now: Date) -> String? {
        guard enabled else { return "AI 裝潢關著" }
        if running { return "已經有一個在跑" }
        let k = project.lowercased()
        let day = ledger.recent(now)
        if day.count >= limits.perDay { return "24 小時內已經問了 \(day.count) 次" }
        let cost = day.reduce(0) { $0 + ($1.cost ?? limits.assumedCost) }
        if cost >= limits.costPerDay { return String(format: "24 小時成本已到 US$%.3f", cost) }
        let mine = ledger.calls.filter { $0.project == k }
        if let f = mine.last(where: { !$0.ok }), now.timeIntervalSince(f.at) < limits.failBackoff, mine.last?.ok != true {
            return "上次失敗，1 小時內不再試"
        }
        if !force, let l = mine.last(where: \.ok), now.timeIntervalSince(l.at) < limits.perProject { return "同專案 6 小時內問過" }
        return nil
    }

    /// 要不要換裝、要不要問 AI。`turnEnded`＝這次刷新有 session 一輪工作結束；`force`＝你按了「重新裝潢」
    public static func decide(cached: FloorDecor?, signature: WorkSignature, turnEnded: Bool, blocked: String?, force: Bool,
                              limits: DecorLimits = DecorLimits(), now: Date) -> DecorDecision {
        if force { return blocked.map { .keep($0) } ?? .ask("重新裝潢") }
        guard let c = cached else { return blocked == nil ? .ask("第一次") : .local }
        if c.source != "ai" { return blocked.map { .keep($0) } ?? .ask("本地結果請 AI 覆核") }
        guard turnEnded else { return .keep("不是一輪結束") }
        if now.timeIntervalSince(c.decidedAt) < limits.perProject { return .keep("換裝後 6 小時內不再換") }
        let (best, score) = signature.best
        guard best != c.theme else { return .keep("主題沒變") }
        let old = signature.scores[c.theme] ?? 0
        guard score >= limits.minHits, Double(score) >= Double(old) * limits.ratio else { return .keep("差距不夠大") }
        let j = WorkSignature.jaccard(signature.terms, c.signature)
        guard j < limits.jaccard else { return .keep(String(format: "工作內容沒有明顯變化（%.2f）", j)) }
        return blocked.map { .keep($0) } ?? .ask("工作內容變了：\(c.theme.rawValue) → \(best.rawValue)")
    }
}

extension DecorPolicy {
    /// AI 只做微調（10-20 §4.3）：AI 的主題只有在「本地身分分數前 2 名之內」或「本地身分最高分 < 3（看不出身分）」時才採用；
    /// 否則保留本地身分判斷的主題，只收 AI 挑的擺設（不屬於這個主題的換成主題預設件）。識別色一律鎖主題預設色。
    /// 本地結果（source ≠ ai）也走同一條：舊版評分判錯、而身分很明確的，換成身分主題。
    public static func reconcile(_ d: FloorDecor, identity: WorkSignature) -> FloorDecor {
        var out = d
        let top = identity.identityTop(2)
        let topScore = top.first.flatMap { identity.identity[$0] } ?? 0
        if topScore >= 3, !top.contains(d.theme) {
            let t = identity.best.theme
            out.theme = t
            var props = d.props.filter { t.allowedProps.contains($0) }
            for p in t.optionalProps where props.count < 2 && !props.contains(p) { props.append(p) }
            out.props = Array(props.prefix(3))
            out.reason = d.source == "ai" ? "AI 建議\(d.theme.title)，依專案身分改成\(t.title)" : "依專案身分判斷"
        }
        out.accentColor = out.theme.accent
        return out
    }
}

// MARK: - 主題選擇器（快取＋節流＋背景呼叫）

/// 每個專案的樓層主題。讀快取、決定要不要問 AI、在背景問、寫回快取。runner 可注入（測試一律假的）。
/// `dir` 底下：themes/<專案>.json、decor_ledger.json（都要排除在看板 FSEvents 外，不然寫檔會叫醒自己）
public final class ThemePicker: @unchecked Sendable {
    /// prompt → (結束碼, stdout, stderr)。正式版跑 claude -p --output-format json，stdout 是 {"result":…, "total_cost_usd":…}
    public typealias Runner = @Sendable (_ prompt: String) -> (code: Int32, out: String, err: String)

    public let dir: URL
    public let model: String
    public let limits: DecorLimits
    private let runner: Runner
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var cache: [String: FloorDecor] = [:]      // 小寫 → 主題
    private var loaded = false
    private var ledger = DecorLedger()
    private var running: String?                       // 正在問的專案（小寫）
    private let clock: @Sendable () -> Date

    public init(dir: URL, model: String = "haiku", limits: DecorLimits = DecorLimits(),
                queue: DispatchQueue = DispatchQueue(label: "showork.decor"), clock: @escaping @Sendable () -> Date = { Date() },
                runner: @escaping Runner) {
        self.dir = dir; self.model = model; self.limits = limits; self.queue = queue; self.clock = clock; self.runner = runner
    }

    var themesDir: URL { dir.appendingPathComponent("themes", isDirectory: true) }
    var ledgerURL: URL { dir.appendingPathComponent("decor_ledger.json") }
    /// 專案名當檔名：/ 與 : 換掉
    static func fileName(_ project: String) -> String {
        project.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") + ".json"
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: themesDir.path)) ?? [] where f.hasSuffix(".json") {
            if let d = fm.contents(atPath: themesDir.appendingPathComponent(f).path), let v = FloorDecor.decode(d) {
                cache[String(f.dropLast(5)).lowercased()] = v
            }
        }
        if let d = fm.contents(atPath: ledgerURL.path), let l = DecorLedger.decode(d) { ledger = l }
    }

    /// 全部快取（小寫專案名 → 主題）
    public func all() -> [String: FloorDecor] { lock.lock(); defer { lock.unlock() }; loadIfNeeded(); return cache }
    public func cached(_ project: String) -> FloorDecor? { all()[project.lowercased()] }
    public var runningProject: String? { lock.lock(); defer { lock.unlock() }; return running }
    public var ledgerSnapshot: DecorLedger { lock.lock(); defer { lock.unlock() }; loadIfNeeded(); return ledger }

    private func save(_ project: String, _ v: FloorDecor) {
        try? FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        if let d = v.encoded() { try? d.write(to: themesDir.appendingPathComponent(Self.fileName(project)), options: .atomic) }
    }
    private func saveLedger() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = ledger.encoded() { try? d.write(to: ledgerURL, options: .atomic) }
    }

    /// 直接寫一筆（正式 agent 用專案身分校正過的結果；不呼叫 AI）
    public func store(_ project: String, _ v: FloorDecor) {
        lock.lock(); loadIfNeeded(); cache[project.lowercased()] = v; lock.unlock()
        save(project, v)
    }

    /// 便宜的前置檢查（主執行緒每次刷新都可以叫）：這個專案這次有沒有可能要動？沒有就不用去收集 transcript。
    public func mayChange(_ project: String, turnEnded: Bool, enabled: Bool, force: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let now = clock()
        guard let c = cache[project.lowercased()] else { return true }                 // 第一次：至少要先放本地結果
        let blocked = DecorPolicy.blocked(project: project, ledger: ledger, running: running != nil, enabled: enabled, force: force, limits: limits, now: now)
        if force { return blocked == nil }
        if c.source != "ai" { return blocked == nil }
        return turnEnded && blocked == nil && now.timeIntervalSince(c.decidedAt) >= limits.perProject
    }

    /// 決定並（必要時）在背景問 AI。`input` 在背景佇列上才叫（讀 transcript 不卡主執行緒）。
    /// `changed` 在背景佇列上被叫：本地結果先寫好時叫一次、AI 回來（成功）再叫一次。回傳是否排了工作
    @discardableResult
    public func consider(_ project: String, turnEnded: Bool, enabled: Bool, force: Bool = false,
                         input: @escaping @Sendable () -> DecorInput,
                         changed: (@Sendable (FloorDecor) -> Void)? = nil,
                         finished: (@Sendable (DecorDecision) -> Void)? = nil) -> Bool {
        guard mayChange(project, turnEnded: turnEnded, enabled: enabled, force: force) else { return false }
        let key = project.lowercased()
        lock.lock()
        // 真正要問之前才佔位（同時只跑一個）；先佔住，決定不問再放掉
        if running != nil {
            lock.unlock()
            // 已有別的在跑：第一次的專案還是要先有本地結果
            if cached(project) == nil {
                queue.async { [self] in
                    let sig = WorkSignature.make(input())
                    let v = FloorDecor.local(sig, now: clock())
                    lock.lock(); let fresh = cache[key] == nil; if fresh { cache[key] = v }; lock.unlock()
                    if fresh { save(project, v); changed?(v) }
                    finished?(.local)
                }
                return true
            }
            return false
        }
        running = key
        lock.unlock()
        queue.async { [self] in
            let inp = input()
            let sig = WorkSignature.make(inp)
            let now = clock()
            lock.lock()
            let cur = cache[key]
            let blocked = DecorPolicy.blocked(project: project, ledger: ledger, running: false, enabled: enabled, force: force, limits: limits, now: now)
            lock.unlock()
            let d = DecorPolicy.decide(cached: cur, signature: sig, turnEnded: turnEnded, blocked: blocked, force: force, limits: limits, now: now)
            // 第一次：不管等一下問不問 AI，先放本地結果（畫面不用等）
            if cur == nil {
                let v = FloorDecor.local(sig, now: now)
                lock.lock(); cache[key] = v; lock.unlock()
                save(project, v); changed?(v)
            }
            guard case .ask = d else {
                lock.lock(); running = nil; lock.unlock()
                finished?(d); return
            }
            let prompt = DecorPrompt.make(inp, signature: sig, current: cur?.source == "ai" ? cur?.theme : nil)
            let t0 = Date()
            let r = runner(prompt)
            let secs = Date().timeIntervalSince(t0)
            let o = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
            let text = o?["result"] as? String ?? r.out
            let cost = (o?["total_cost_usd"] as? NSNumber)?.doubleValue
            let isErr = (o?["is_error"] as? Bool) == true
            // AI 只做微調：主題不在本地身分前 2 名就不採用（只收擺設）、識別色鎖主題預設色
            var v = r.code == 0 && !isErr ? DecorPrompt.parse(text, signature: sig, model: model, cost: cost, now: clock()).map { DecorPolicy.reconcile($0, identity: sig) } : nil
            v?.seconds = (secs * 10).rounded() / 10
            lock.lock()
            ledger.calls.append(.init(at: now, project: key, cost: cost, ok: v != nil, seconds: (secs * 10).rounded() / 10))
            ledger.prune(now)
            if let v { cache[key] = v }
            running = nil
            lock.unlock()
            saveLedger()
            if let v { save(project, v); changed?(v) }
            finished?(v == nil ? .keep("AI 失敗（\(r.code)）：\(String((r.err.isEmpty ? text : r.err).prefix(120)))") : d)
        }
        return true
    }
}

// MARK: - 從對話紀錄尾端收集線索

extension DecorInput {
    static let fileTools: Set<String> = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let skipWords: Set<String> = ["cd", "echo", "export", "sudo", "time", "env", "nohup", "then", "do", "if", "for", "true", "false", "set", "source", "."]

    /// transcript 尾端（同審核員，最後約 200KB）→ 你最近的指示、Edit/Write/Read 的路徑、Bash 指令第一個字。
    /// 只看主對話（isSidechain 不算），系統通知不算你的指示
    public static func extract(tail: Data) -> (prompts: [String], paths: [String], commands: [String]) {
        var prompts: [String] = [], paths: [String] = [], cmds: [String] = []
        for raw in tail.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any], o["isSidechain"] as? Bool != true,
                  let m = o["message"] as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "user":
                if o["isMeta"] as? Bool == true || o["isCompactSummary"] as? Bool == true { break }
                if let c = m["content"] as? String, !c.isEmpty, !TranscriptInfo.isSystemMessage(c) { prompts.append(c) }
                for p in (m["content"] as? [[String: Any]]) ?? [] where p["type"] as? String == "text" {
                    if let t = p["text"] as? String, !t.isEmpty, !TranscriptInfo.isSystemMessage(t) { prompts.append(t) }
                }
            case "assistant":
                for p in (m["content"] as? [[String: Any]]) ?? [] where p["type"] as? String == "tool_use" {
                    let name = p["name"] as? String ?? "", inp = p["input"] as? [String: Any]
                    if fileTools.contains(name), let f = (inp?["file_path"] ?? inp?["notebook_path"]) as? String { paths.append(f) }
                    if name == "Bash", let c = inp?["command"] as? String { cmds += commandWords(c) }
                }
            default: break
            }
        }
        return (prompts, paths, cmds)
    }

    /// README 去噪（10-20 §4.3）：拿掉徽章／圖片行（![、[![、> [!、<img、<p、<a）、程式碼區塊、HTML 註解、網址
    public static func cleanReadme(_ s: String) -> String {
        var out: [String] = []
        var inCode = false
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            if line.hasPrefix("![") || line.hasPrefix("[![") || line.hasPrefix("> [!") || line.hasPrefix("<") { continue }
            var l = raw
            while let r = l.range(of: #"https?://\S+"#, options: .regularExpression) { l.removeSubrange(r) }
            while let r = l.range(of: #"github\.com/\S+"#, options: .regularExpression) { l.removeSubrange(r) }
            while let r = l.range(of: #"\]\([^)]*\)"#, options: .regularExpression) { l.replaceSubrange(r, with: "]") }
            out.append(l)
        }
        return out.joined(separator: "\n")
    }

    /// README → (標題行＋第一段, 其餘)。第一段＝標題之後第一個非空段落（到空行或 ## 為止）
    public static func readmeParts(_ s: String) -> (head: String, rest: String) {
        let lines = cleanReadme(s).components(separatedBy: "\n")
        var head: [String] = [], i = 0
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        while i < lines.count, lines[i].hasPrefix("# ") { head.append(String(lines[i].dropFirst(2))); i += 1 }
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { break }
            head.append(l); i += 1
        }
        return (head.joined(separator: "\n"), lines[min(i, lines.count)...].joined(separator: "\n"))
    }

    /// 一行 shell 指令 → 每一段（&& ; | 分開）的第一個字（cd、echo、VAR=x 這類略過；路徑取最後一節）
    public static func commandWords(_ c: String) -> [String] {
        var out: [String] = []
        for seg in c.components(separatedBy: CharacterSet(charactersIn: "&;|\n")) {
            for w in seg.split(whereSeparator: \.isWhitespace) {
                let s = String(w)
                if s.contains("=") || s.hasPrefix("-") || s.hasPrefix("(") || s.hasPrefix("$") || s.hasPrefix("\"") || s.hasPrefix("'") { continue }
                if skipWords.contains(s) { break }
                let base = (s as NSString).lastPathComponent
                if !base.isEmpty, base.first!.isLetter { out.append(base) }
                break
            }
        }
        return out
    }
}
