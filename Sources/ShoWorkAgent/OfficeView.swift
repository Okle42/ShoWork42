import AppKit
import Combine
import SceneKit
import SwiftUI
import ShoWorkCore

// 3D 辦公室：戰情中心的另一種看法（10-20 Kang 看了 IG davidyet「AI hedge fund office」影片：走得進去的 3D 辦公室）。
// 第四版（10-20 Kang 拍板，參考 IG「ACCAI」大樓剖面影片）：科技大樓剖面，樓層疊起來一起看。
//   一樓大廳＋前台保全（wifiwatch）、閒置薄層（沒人的專案只剩門牌）、有 AI 的專案一層一樓（固定樓層號）、頂樓空中花園。
//   每層的主題由 AI 從主題庫挑（BoardModel.decor），桌子＝實際 AI 數；面向鏡頭的牆自動淡掉；樓層換位置時整層飄出→升降→插回；
//   角色會閒晃（休息的上頂樓、做完的偶爾拜訪別層）。
// 右上角：燈光（白天／夜晚／自動）、重新裝潢（請 AI 重挑某層的主題）、重設視角。原本的棋盤／環狀格局 10-20 拿掉（設定鍵留著相容）。
// 拖曳轉視角、捲動縮放、按住滾輪拖曳平移、WASD／方向鍵走動、Q／E 升降；點角色在右邊看它的對話、直接跟它講話（10-25；跳到終端機改在窗格的按鈕和右鍵）、右鍵更多、停在角色上看細節；點保全開保全面板。
// 場景在 OfficeBuilder.swift，大樓零件在 OfficeTower.swift，方塊零件在 OfficeVoxel.swift。

/// 關窗時整個畫面會拆掉（10-24 Kang 選 C：關著時 SwiftUI＋3D 不再跟著資料更新），重開要回到原樣的東西記在這裡
@MainActor enum OfficeMemory {
    static var camera: (transform: SCNMatrix4, target: SCNVector3)?   // 只有你動過視角才記（沒動過就照預設取景）
    static var selectedFloor: String?
    static var boardOpen = false
    static var boardTop: Int?                                       // 交流互動板捲到哪一則（最上面那則的編號）
    static var talkingTo: String?                                   // 右側對話窗格在看誰（10-25）
}

struct OfficeView: View {
    let cards: [BoardCard]
    let departments: [OfficeDepartment]
    let tower: TowerPlan
    let decor: [String: FloorDecor]
    let wander: WanderPlan
    let guardStatus: GuardStatus
    let guardScanning: Bool
    var captainThread: [CaptainLine] = []
    var captainTasks: [CaptainTask] = []
    var sessionThread: [CaptainLine] = []     // 右側對話窗格看的那個 AI 的對話（BoardModel.watch）
    var city = CityState()
    let loaded: Bool
    let reviewing: Set<String>
    let onSendBack: (BoardCard) -> Void
    let onPark: (BoardCard) -> Void
    let onDispatch: (BoardCard) -> Void
    let onToast: (String) -> Void

    @State private var hovered: String?           // 卡片 id 或 "guard"、城市建築 "city:⋯"
    @State private var hoverPoint = CGPoint.zero  // 滑鼠剛停上去的位置（3D 區域左上角為原點）：城市懸停卡浮在旁邊
    @State private var hoverCardSize = CGSize(width: 320, height: 200)
    @State private var answeringId: String?
    @State private var guardOpen = false
    @State private var resetTick = 0
    @State private var demoTick = 0         // 只有 SHOWORK_OFFICE_DEMO=camera 用：到點重算一次
    @State private var clockTick = 0        // 燈光「自動」：到 06:00／18:00 重算一次（一次性 sleep，不輪詢）
    @State private var demoTower = OfficeDemo.TowerCache()
    // 10-20 UI/UX 優化：鏡頭請求（需要你列、樓層索引列）、索引列狀態、做完的人細節卡釘 6 秒、操作說明
    @State private var camRequest = CamRequest()
    @State private var lastAttention: String?
    @State private var selectedFloor: String? = OfficeMemory.selectedFloor
    @State private var railHover: String?
    @State private var idleOpen = false
    @State private var pinned: String?
    @State private var helpOpen = false
    @State private var cityOpen: String?          // 點了城市的哪棟建築（細節卡）
    @State private var boardOpen = OfficeMemory.boardOpen          // 點了 Agent交流互動板（10-24 Kang：要能點開看）
    @State private var lastCityAlert: String?
    // 收件匣（10-21）：寬視窗（電視）固定在右邊；窄的點「等你」才浮出來
    @State private var answered: [String: Date] = [:]
    @State private var inboxOpen = OfficeView.testEnv("SHOWORK_OFFICE_INBOX") != nil
    @State private var wide = true
    @State private var captainBusy = false
    @State private var talkingTo: String? = OfficeView.testEnv("SHOWORK_OFFICE_TALK") ?? OfficeMemory.talkingTo   // 右側對話窗格在看誰（卡片 id）；nil＝隊長
    static let inboxWidth: CGFloat = 1300
    static let railOn = ProcessInfo.processInfo.environment["SHOWORK_OFFICE_RAIL"] != "off"
    static let helpShownKey = "office.helpShown"

    static let prefsStore = UserDefaults(suiteName: OfficePrefs.suite)
    @AppStorage(OfficePrefs.lightingKey, store: OfficeView.prefsStore) private var lightingRaw = OfficeLighting.auto.rawValue
    @AppStorage(OfficePrefs.styleKey, store: OfficeView.prefsStore) private var styleRaw = OfficeStyle.voxel.rawValue
    @State private var testStyle = OfficeView.testEnv("SHOWORK_OFFICE_STYLE").flatMap(OfficeStyle.init(rawValue:))
    private var style: OfficeStyle { testStyle ?? OfficeStyle(rawValue: styleRaw) ?? .voxel }
    private var styleBinding: Binding<OfficeStyle> {
        Binding(get: { style }, set: { v in if BoardWindow.testMode { testStyle = v } else { styleRaw = v.rawValue } })
    }
    @AppStorage(OfficePrefs.guardPatrolKey, store: OfficeView.prefsStore) private var patrol = false
    // 測試視窗：SHOWORK_OFFICE_LIGHTING 覆寫，選單改的也只放在這裡，不寫回你的設定
    @State private var testLighting = OfficeView.testEnv("SHOWORK_OFFICE_LIGHTING").flatMap(OfficeLighting.init(rawValue:))
    @State private var testPatrol = false
    @ObservedObject private var weather = OfficeWeather.shared     // 10-21 真實天氣（§3.8.2）；10-25 地點可選、預設只看台北

    static func testEnv(_ k: String) -> String? { BoardWindow.testMode ? ProcessInfo.processInfo.environment[k] : nil }

    private var lighting: OfficeLighting { testLighting ?? OfficeLighting(rawValue: lightingRaw) ?? .auto }
    private var lightingBinding: Binding<OfficeLighting> {
        Binding(get: { lighting }, set: { v in if BoardWindow.testMode { testLighting = v } else { lightingRaw = v.rawValue } })
    }
    private var patrolBinding: Binding<Bool> {
        Binding(get: { BoardWindow.testMode ? testPatrol : patrol }, set: { v in if BoardWindow.testMode { testPatrol = v } else { patrol = v } })
    }

    /// 測試用：SHOWORK_OFFICE_DEMO 換成假資料（截圖看造型、量閒置 CPU）；正式使用時就是看板的卡片
    private var shown: [BoardCard] { OfficeDemo.apply(cards) }

    var body: some View {
        let cards = shown
        let _ = demoTick, _ = clockTick
        let islands = Islands.build(cards)
        let deps = OfficeDemo.departments(departments, cards: cards)
        // 示範資料：大樓、主題、閒晃在這裡用假卡片算（不碰你的樓層號名冊）；正式就是 BoardModel 算好的
        let (towerShown, decorShown, wanderShown) = OfficeDemo.mode == nil ? (tower, decor, wander) : demoTower.make(deps, cards: cards, real: decor)
        let guardShown = OfficeDemo.guardStatus(guardStatus)
        let now = OfficeClock.now(), look = lighting.look(at: now).weathered(weather.look), night = look.isNight    // 10-21 日出日落：天色依太陽仰角連續混合
        // 點了等你回答的角色：開可互動卡（還在等你才顯示，回答完／換狀態就自己收掉）
        let answering = answeringId.flatMap { i in cards.first { $0.id == i && Mood.of($0) == .waiting } }
        let attention = AttentionSummary.make(cards)
        let moods = Dictionary(grouping: islands.flatMap { i in i.people.map { (i.project.lowercased(), $0.mood) } }, by: \.0).mapValues { $0.map(\.1) }
        let rows = TowerIndex.rows(towerShown, decor: decorShown, moods: moods)
        let alerts = city.alerts
        HStack(alignment: .top, spacing: 8) {
            // 窄視窗：收件匣打開時佔掉樓層清單的位置（不疊在 3D 上：SceneKit 圖層會透上來破圖）
            if !wide && inboxOpen {
                inbox(cards, close: { inboxOpen = false }).frame(width: 300)
            } else if Self.railOn {
                FloorRail(rows: rows, selected: selectedFloor, guardLevel: guardShown.level, cityAlerts: alerts.count, idleOpen: $idleOpen,
                          onFloor: focusFloor, onHover: { railHover = $0 }, onGuard: { focusFloor("lobby"); answeringId = nil; guardOpen = true })
                    .frame(width: 196)
            }
            VStack(spacing: 6) {
                AttentionBar(summary: attention, alerts: alerts.count, onAlerts: { focusCityAlert(alerts.map(\.id)) },
                             onWaiting: { if !wide { inboxOpen = true }; focusAttention(attention.waiting, answer: true) },
                             onStuck: { focusAttention(attention.stuck, answer: false) },
                             onFinished: { focusAttention(attention.finished, answer: false) }) {
                    controls(towerShown: towerShown, decorShown: decorShown, night: night, lightLabel: lighting.label(at: now))
                }
                scene(islands: islands, towerShown: towerShown, decorShown: decorShown, wanderShown: wanderShown,
                      guardShown: guardShown, night: night, look: look, answering: answering, cards: cards)
            }
            if wide { inbox(cards, close: nil).frame(width: 320) }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.inboxWidth } action: { wide = $0 }
        .onAppear { if let t = talkingTo { talk(t) } }        // 重開視窗（內容拆掉重建）或測試視窗指定了人：接回去讀它的對話
    }

    /// 收件匣：按選項／打字回答、交給隊長
    @ViewBuilder private func inbox(_ cards: [BoardCard], close: (() -> Void)?) -> some View {
        InboxPanel(items: Inbox.items(cards, answered: answered), captain: cards.first { $0.captain && !$0.id.contains("#") },
                   onAnswer: { it, text in
                       // 示範資料借用真 session 的 pid、測試視窗看的是你真的 session：都絕不能真的送（10-20 審查）
                       if OfficeDemo.mode != nil || BoardWindow.testMode { onToast("測試：不送出「\(text)」"); return }
                       answered[it.card.sessionId] = Date()
                       if answeringId == it.id { answeringId = nil }
                       onToast(BoardActions.answer(it.card, text: text))
                   },
                   onPermit: { it, a in
                       if OfficeDemo.mode != nil || BoardWindow.testMode { onToast("測試：不回答權限（\(a.decision.rawValue)）"); return }
                       answered[it.card.sessionId] = Date()
                       onToast(BoardActions.permit(it.card, a))
                   },
                   onJump: jump, onFocus: { focusAttention([$0], answer: false) },
                   onCaptain: { text in
                       if OfficeDemo.mode != nil || BoardWindow.testMode { onToast("測試：不交給隊長「\(text)」"); return }
                       captainBusy = true
                       DispatchQueue.global().async {
                           let msg = BoardActions.askCaptain(text)
                           DispatchQueue.main.async { captainBusy = false; onToast(msg) }
                       }
                   },
                   onClose: close, captainBusy: captainBusy,
                   thread: OfficeDemo.mode != nil ? OfficeDemo.captainThread : captainThread,
                   tasks: OfficeDemo.mode != nil ? OfficeDemo.captainTasks : captainTasks,
                   person: talkingTo.flatMap { i in cards.first { $0.id == i } },
                   personThread: OfficeDemo.mode != nil ? OfficeDemo.personThread : sessionThread,
                   onPersonSend: { text in
                       guard let c = talkingTo.flatMap({ i in cards.first { $0.id == i } }) else { return }
                       if OfficeDemo.mode != nil || BoardWindow.testMode { onToast("測試：不送出「\(text)」"); return }
                       answered[c.sessionId] = Date()
                       onToast(BoardActions.answer(c, text: text))
                   },
                   onBack: { talk(nil) })
    }

    /// 右側對話窗格換人（nil＝回到隊長）：資料層改讀那個人的對話紀錄
    private func talk(_ id: String?) {
        talkingTo = id; OfficeMemory.talkingTo = id
        let sid = id.map { String($0.split(separator: "#").first ?? Substring($0)) }   // 卡片 id＝sessionId（排隊卡多 #q…）；重開視窗時卡片還沒讀到也找得到
        if OfficeDemo.mode == nil { BoardModel.shared.watch(sid) }
        if id != nil && !wide { inboxOpen = true }
    }

    /// 右上那組控制（10-20 UI/UX 優化：移到「需要你」列右邊；原本那行灰字操作說明改成 ? 按鈕）
    @ViewBuilder private func controls(towerShown: TowerPlan, decorShown: [String: FloorDecor], night: Bool, lightLabel: String) -> some View {
        SwiftUI.Menu {
            Picker("燈光", selection: lightingBinding) {
                ForEach(OfficeLighting.allCases, id: \.self) { l in
                    Text(l == .auto ? "自動（跟著台北日出日落）" : l.title).tag(l)
                }
            }
            .pickerStyle(.inline)
            Picker("風格", selection: styleBinding) {
                ForEach(OfficeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle("真實天氣（點天氣列換地點）", isOn: $weather.enabled)
            Text(weather.menuStatus)
        } label: {
            Label(lightLabel,
                  systemImage: lighting == .auto ? "circle.lefthalf.filled" : night ? "moon.stars" : "sun.max")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("燈光：白天／夜晚（吊燈與螢幕發光）／自動（依這台電腦的時間）")
        WeatherStrip(weather: weather)
        SwiftUI.Menu {
            let floors = towerShown.projectFloors.compactMap(\.project)
            if floors.isEmpty { Text("現在沒有專案樓層") }
            ForEach(floors, id: \.self) { p in
                Button("\(p)・\(decorShown[p.lowercased()]?.theme.title ?? "還沒決定")") { redecorate(p) }
            }
        } label: { Label("重新裝潢", systemImage: "paintbrush") }
        .menuStyle(.borderlessButton).fixedSize()
        .help("請 AI 依這層最近在做的事重新挑主題（有次數與成本上限：24 小時最多 8 次）")
        Button { selectedFloor = nil; OfficeMemory.selectedFloor = nil; OfficeMemory.camera = nil; resetTick += 1 } label: { Label("重設視角", systemImage: "scope") }
            .buttonStyle(.borderless).fixedSize()
        Button { helpOpen.toggle() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.borderless).help("操作說明")
            .popover(isPresented: $helpOpen, arrowEdge: .bottom) { OfficeHelp() }
    }

    @ViewBuilder private func scene(islands: [Island], towerShown: TowerPlan, decorShown: [String: FloorDecor], wanderShown: WanderPlan,
                                    guardShown: GuardStatus, night: Bool, look: SkyLook, answering: BoardCard?, cards: [BoardCard]) -> some View {
        OfficeScene(islands: islands, tower: towerShown, decor: decorShown, wander: wanderShown,
                    guardStatus: guardShown, guardScanning: guardScanning, city: city,
                    night: night, look: look, weather: weather.look, style: style, loaded: loaded, resetTick: resetTick, camRequest: camRequest, railHover: railHover,
                    cardSize: answering != nil ? CGSize(width: 464, height: 290) : guardOpen ? CGSize(width: 484, height: 640)
                        : cityOpen != nil ? CGSize(width: 464, height: 300)
                        : boardOpen ? CGSize(width: 484, height: 560)
                        : (personHover ?? pinned) != nil ? CGSize(width: 444, height: 240) : nil,
                    onHover: { hovered = $0 }, onHoverPoint: { hoverPoint = $0 }, onClick: click, menu: menu)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) { cityHover }
            .overlay(alignment: .bottomLeading) {
                if let c = answering {
                    AnswerCard(card: c, onJump: { jump(c.id) }, onClose: { answeringId = nil }, onSend: { text in
                        // 示範資料的卡片借用真 session 的 pid：絕不能真的打字進去（10-20 審查）
                        if OfficeDemo.mode != nil { onToast("示範資料：不送出（\(text.count) 字）"); answeringId = nil; return }
                        onToast(BoardActions.answer(c, text: text))
                        answeringId = nil
                    })
                    .padding(12).transition(.opacity)
                } else if let id = cityOpen {
                    CityCard(id: id, city: city, onClose: { cityOpen = nil }).padding(12).transition(.opacity)
                } else if boardOpen {
                    B1BoardCard(onClose: { boardOpen = false }).padding(12).transition(.opacity)
                } else if guardOpen {
                    GuardCard(status: guardShown, scanning: guardScanning, wall: city.firewall.summary, patrol: patrolBinding,
                              onScan: guardScan, onClose: { guardOpen = false })
                        .padding(12).transition(.opacity)
                } else if hovered == "guard" {
                    GuardHover(status: guardShown, scanning: guardScanning).padding(12).allowsHitTesting(false).transition(.opacity)
                } else if let c = (hovered ?? pinned).flatMap({ i in cards.first { $0.id == i } }) {
                    HoverCard(card: c, theme: decorShown[c.project.lowercased()]).padding(12).allowsHitTesting(false).transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.15), value: hovered)
            .animation(.smooth(duration: 0.15), value: answering?.id)
            .animation(.smooth(duration: 0.15), value: guardOpen)
            .animation(.smooth(duration: 0.15), value: cityOpen)
            .animation(.smooth(duration: 0.15), value: boardOpen)
            .onChange(of: boardOpen) { _, v in OfficeMemory.boardOpen = v }
            .task {
                // 截圖驗證用：SHOWORK_OFFICE_ANSWER=<卡片 id> ⇒ 一開就打開那個人的回答卡；SHOWORK_OFFICE_GUARDCARD=1 ⇒ 打開保全面板
                let env = ProcessInfo.processInfo.environment
                if let a = env["SHOWORK_OFFICE_ANSWER"] { answeringId = a }
                if env["SHOWORK_OFFICE_GUARDCARD"] != nil { guardOpen = true }
                if env["SHOWORK_OFFICE_B1BOARD"] != nil { boardOpen = true }        // 截圖驗證：一開就打開交流互動板
                if let c = env["SHOWORK_OFFICE_CITYCARD"] { cityOpen = c }
                // 第一次開 3D 檢視：自動彈一次操作說明（記在設定；測試視窗不寫、SHOWORK_OFFICE_HELP=1 才彈）
                if BoardWindow.testMode ? env["SHOWORK_OFFICE_HELP"] != nil : !(Self.prefsStore?.bool(forKey: Self.helpShownKey) ?? true) {
                    try? await Task.sleep(for: .seconds(1)); helpOpen = true
                    if !BoardWindow.testMode { Self.prefsStore?.set(true, forKey: Self.helpShownKey) }
                }
                if let f = env["SHOWORK_OFFICE_RAILCLICK"] {
                    try? await Task.sleep(for: .seconds(3))
                    focusFloor(f)
                    if f.hasPrefix("idle") { idleOpen = true }
                    print("rail click", f); fflush(stdout)
                }
                // SHOWORK_OFFICE_GUARDSCAN=1：開窗 1.5 秒後按一次「立即掃描」（跟按鈕同一條路；測試要配假腳本 SHOWORK_WIFIWATCH_SCRIPT）
                if env["SHOWORK_OFFICE_GUARDSCAN"] != nil {
                    try? await Task.sleep(for: .seconds(1.5)); guardScan()
                }
                // SHOWORK_OFFICE_TOGGLE=1（只有測試視窗）：開窗 2 秒後走選單同一條 binding 換成夜晚（驗切換：只換燈光、不重建）
                if BoardWindow.testMode, env["SHOWORK_OFFICE_TOGGLE"] != nil {
                    try? await Task.sleep(for: .seconds(2))
                    lightingBinding.wrappedValue = .night
                    print("office toggled →", lighting.rawValue); fflush(stdout)
                }
                guard OfficeDemo.mode == "camera" else { return }
                // 10-20 審查：start 是 lazy 的，原本要等卡片讀到（約 1.5 秒）才開始算，6.5 秒到點時還不滿 6 秒 ⇒ 示範不會觸發；開窗就先起算
                _ = OfficeDemo.start
                try? await Task.sleep(for: .seconds(6.5)); demoTick += 1
            }
            .task(id: cards.isEmpty) {
                // 驗收用：SHOWORK_OFFICE_ATTN=waiting|stuck|finished ⇒ 讀到卡片 3 秒後按一下「需要你」列那一格（走按鈕同一條路）
                guard !cards.isEmpty, let k = ProcessInfo.processInfo.environment["SHOWORK_OFFICE_ATTN"] else { return }
                try? await Task.sleep(for: .seconds(3))
                let a = AttentionSummary.make(shown)
                switch k {
                case "stuck": focusAttention(a.stuck, answer: false)
                case "finished": focusAttention(a.finished, answer: false)
                default: focusAttention(a.waiting, answer: true)
                }
                print("attention click", k, "→", answeringId.map { "answer \($0)" } ?? "focus \(lastAttention ?? "nil")"); fflush(stdout)
            }
            .task(id: "\(lighting.rawValue)|\(clockTick)") {
                // 自動燈光：晨昏每 60 秒、白天每 5 分鐘、夜晚睡到天快亮再重算一次；白天／夜晚固定、測試假時間（凍結）就不排
                guard OfficeClock.fixed == nil else { return }
                let now = OfficeClock.now()
                guard let next = lighting.nextChange(after: now) else { return }
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(now) + 0.5)))
                if !Task.isCancelled { clockTick += 1 }
            }
    }

    /// 停在城市建築上的不算「人」（不開左下角的人物卡、不擋左下角的名牌）
    private var personHover: String? { hovered.flatMap { Self.isCity($0) ? nil : $0 } }
    static func isCity(_ id: String) -> Bool { id.hasPrefix("city:") || id.hasPrefix("ship:") }

    /// 城市懸停卡（10-21 第二輪）：浮在滑鼠右下（放不下就換到左邊／上面），夾在 3D 區域裡、不吃滑鼠；
    /// 已經點開同一棟的細節卡就不重複
    @ViewBuilder private var cityHover: some View {
        if let id = hovered, Self.isCity(id), id != cityOpen {
            // 懸停卡讀最新細節（含不發布的：伺服器延遲、檢查時間）；還沒收集過就用發布的那份
            let live = CityMonitor.shared.latest
            let data = live.disks.isEmpty && live.clouds.isEmpty ? city : live
            GeometryReader { g in
                let o = Self.hoverOrigin(point: hoverPoint, card: hoverCardSize, in: g.size)
                CityHoverCard(id: id.hasPrefix("ship:") ? "city:port" : id, city: data)
                    .fixedSize()
                    .background(GeometryReader { c in Color.clear.preference(key: HoverCardSizeKey.self, value: c.size) })
                    .offset(x: o.x, y: o.y)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            .onPreferenceChange(HoverCardSizeKey.self) { hoverCardSize = $0 }
        }
    }

    /// 懸停卡左上角：先放滑鼠右下 16 點；右邊放不下換到左邊、下面放不下換到上面；最後夾在畫面內（留 8 點）
    static func hoverOrigin(point p: CGPoint, card c: CGSize, in v: CGSize) -> CGPoint {
        var x = p.x + 16, y = p.y + 16
        if x + c.width > v.width - 8 { x = p.x - 16 - c.width }
        if y + c.height > v.height - 8 { y = p.y - 16 - c.height }
        x = min(max(8, x), max(8, v.width - c.width - 8))
        y = min(max(8, y), max(8, v.height - c.height - 8))
        return CGPoint(x: x, y: y)
    }

    /// 重新裝潢（右上角選單、右鍵）：請 AI 重挑這層主題；示範資料不呼叫
    private func redecorate(_ project: String) {
        if OfficeDemo.mode != nil { onToast("示範資料：不重新裝潢"); return }
        onToast(BoardModel.shared.redecorate(project))
    }


    /// 索引列點樓層：鏡頭對準整層；同一層再點一次回到預設鏡頭
    private func focusFloor(_ id: String) {
        defer { OfficeMemory.selectedFloor = selectedFloor }
        if selectedFloor == id { selectedFloor = nil; resetTick += 1; return }
        selectedFloor = id
        camRequest = CamRequest(tick: camRequest.tick + 1, target: .floor(id))
    }

    /// 設備警示：輪流飛到下一個有問題的建築並打開它的細節卡
    private func focusCityAlert(_ ids: [String]) {
        guard let id = AttentionSummary.next(after: ids.contains(lastCityAlert ?? "") ? lastCityAlert : nil, in: ids) else { return }
        lastCityAlert = id
        selectedFloor = nil
        answeringId = nil; guardOpen = false
        cityOpen = id
        camRequest = CamRequest(tick: camRequest.tick + 1, target: .city(id))
    }

    /// 需要你列：依時間先後輪流飛到下一個人；等你回答的直接開回答卡，做完的把細節卡釘 6 秒
    private func focusAttention(_ ids: [String], answer: Bool) {
        guard let id = AttentionSummary.next(after: ids.contains(lastAttention ?? "") ? lastAttention : nil, in: ids) else { return }
        lastAttention = id
        selectedFloor = nil
        camRequest = CamRequest(tick: camRequest.tick + 1, target: .person(id))
        guardOpen = false
        if answer { answeringId = id } else {
            answeringId = nil
            pinned = id
            Task { try? await Task.sleep(for: .seconds(6)); if pinned == id { pinned = nil } }
        }
    }

    /// 點角色：右邊窗格換成它的對話（隊長＝隊長對話）；等你回答的另外開回答卡。點保全開保全面板
    private func click(_ id: String) {
        if id.hasPrefix("neural:") { openGraph(String(id.dropFirst(7))); return }
        if id == "b1-board" { answeringId = nil; guardOpen = false; cityOpen = nil; boardOpen = true; return }
        boardOpen = false
        if id.hasPrefix("city:") { answeringId = nil; guardOpen = false; cityOpen = id; return }
        cityOpen = nil
        if id == "guard" { answeringId = nil; guardOpen = true; return }
        guard let c = shown.first(where: { $0.id == id }) else { return }
        guardOpen = false
        answeringId = Mood.of(c) == .waiting ? id : nil
        talk(c.captain ? nil : id)
    }

    private func jump(_ id: String) {
        guard let c = shown.first(where: { $0.id == id }) else { return }
        if !BoardActions.focus(pid: c.pid) {
            onToast(c.kind == "bg" ? "這是背景 session，沒有視窗；用 claude attach 打開" : "找不到這個 session 的視窗")
        }
    }

    /// 點地下室神經網路（10-22）：用預設瀏覽器開 3D 知識星雲。
    /// 10-22 Kang：「點了只有 ProjectB，不是應該這棟大樓相關的都要顯示嗎？」⇒ 開整棟大樓那一頁（每個專案一種顏色，左上圖例可只看一個專案）。
    /// 整棟那頁做不出來才退回那個專案自己的（或任一份）。測試視窗只回報、不開瀏覽器
    private func openGraph(_ project: String) {
        if BoardWindow.testMode {
            let u = GraphSource.shared.htmlFor(project: project)?.url ?? GraphPaths.building
            print("office neural open →", u.path); fflush(stdout); onToast("測試：開啟整棟大樓知識星雲"); return
        }
        onToast("正在整理整棟大樓的知識星雲…")
        let toast = onToast
        GraphSource.shared.openBuilding(clicked: project) { r in
            if let r {
                NSWorkspace.shared.open(r.url)
                toast(r.count > 0 ? "開啟整棟大樓知識星雲（\(r.count) 個專案）" : "開啟整棟大樓知識星雲")
            } else if let (name, url) = GraphSource.shared.htmlFor(project: project) {
                NSWorkspace.shared.open(url)
                toast("整棟版做不出來，先開 \(name) 知識圖譜")
            } else {
                toast("知識圖譜產生失敗（找不到 graphify 或專案資料夾）")
            }
        }
    }

    /// 「立即掃描」：示範資料、測試視窗（沒配假腳本）都不掃真的網路
    private func guardScan() {
        let msg: String
        if OfficeDemo.mode != nil { msg = "示範資料：不掃描" }
        else if BoardWindow.testMode && ProcessInfo.processInfo.environment["SHOWORK_WIFIWATCH_SCRIPT"] == nil { msg = "測試視窗不掃描真的網路" }
        else { msg = BoardModel.shared.guardScan() ? "開始掃描 Wi-Fi（約數十秒）" : "已經在掃描了" }
        if BoardWindow.testMode { print("office guardScan →", msg); fflush(stdout) }
        onToast(msg)
    }

    /// 右鍵選單（跟部門島同一組動作）；保全：打開面板／立即掃描
    private func menu(_ id: String) -> NSMenu? {
        if id == "guard" {
            let m = NSMenu()
            m.addItem(ClosureItem("打開保全面板") { guardOpen = true })
            let s = ClosureItem(guardScanning ? "掃描中⋯" : "立即掃描 Wi-Fi") { guardScan() }
            s.isEnabled = !guardScanning
            m.addItem(s)
            m.autoenablesItems = false
            return m
        }
        guard let c = shown.first(where: { $0.id == id }) else { return nil }
        let m = NSMenu()
        m.addItem(ClosureItem("跳到這個視窗") { jump(id) })
        if c.column == .review { m.addItem(ClosureItem("放行") { BoardActions.approve(c); onToast("已放行「\(c.title)」") }) }
        if !c.captain { m.addItem(ClosureItem("派工給它⋯") { onDispatch(c) }) }
        m.addItem(ClosureItem("退回並補指示⋯") { onSendBack(c) })
        m.addItem(ClosureItem("丟回待辦⋯") { onPark(c) })
        let r = ClosureItem("重新審核") { Reviewer.shared.start(c, force: true) }
        r.isEnabled = !(reviewing.contains(c.sessionId) || c.lastActivity == nil)
        m.addItem(r)
        m.addItem(.separator())
        m.addItem(ClosureItem("重新裝潢「\(c.project)」這層") { redecorate(c.project) })
        m.addItem(ClosureItem("拷貝 Session ID") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.sessionId, forType: .string)
        })
        m.autoenablesItems = false
        return m
    }
}

/// 城市懸停卡量到的大小（拿來夾在畫面內）
struct HoverCardSizeKey: PreferenceKey {
    static let defaultValue = CGSize(width: 320, height: 200)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - 需要你列、樓層索引列、操作說明（10-20 第 2 棒 UI/UX 優化 §2.2 A、B）

/// 鏡頭請求：tick 變了才執行一次
struct CamRequest: Equatable {
    enum Target: Equatable { case none, person(String), floor(String), city(String) }
    var tick = 0
    var target: Target = .none
}

/// 頂部「需要你」列：● N 等你、● N 卡住、● N 做完、「M 人在 K 層」；右邊放燈光／重新裝潢／重設視角／操作說明。
/// 資料只在看板刷新時變（FSEvents／15 秒保底），不加 timer
struct AttentionBar<Controls: View>: View {
    let summary: AttentionSummary
    var alerts = 0                          // 設備警示（外部空間城市，10-21）
    var onAlerts: () -> Void = {}
    let onWaiting: () -> Void
    let onStuck: () -> Void
    let onFinished: () -> Void
    @ViewBuilder let controls: () -> Controls

    /// 10-21 稽核：視窗窄（960）又同時有等你／卡住／設備警示／做完時，字被截成「7…」「6 設…」⇒ 依寬度退到短字、再退到只剩數字
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.short)
            row(.dots)
        }
        .font(.system(size: 14, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    enum Style { case full, short, dots }

    private func row(_ st: Style) -> some View {
        HStack(spacing: st == .dots ? 6 : 10) {
            if summary.isEmpty && alerts == 0 {
                Label("沒有人在等你", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            chip(summary.waiting.count, "等你", Color(red: 0.94, green: 0.27, blue: 0.27), st, action: onWaiting, help: "依時間先後輪流：鏡頭飛過去並打開回答卡")
            chip(summary.stuck.count, "卡住", Color(red: 0.98, green: 0.45, blue: 0.09), st, action: onStuck, help: "依時間先後輪流：鏡頭飛過去")
            chip(alerts, st == .full ? "設備警示" : "警示", Color(red: 0.94, green: 0.27, blue: 0.27), st, action: onAlerts, help: "設備警示（外部空間城市）：滿了的碟、離線的伺服器、防火牆、敞開的埠、電廠過熱；點一下輪流飛過去並打開細節")
            chip(summary.finished.count, "做完", Color(red: 0.13, green: 0.77, blue: 0.37), st, action: onFinished, help: "依時間先後輪流：鏡頭飛過去、細節卡停 6 秒")
            if st == .full { Text("\(summary.people) 人在 \(summary.floors) 層").foregroundStyle(.secondary).monospacedDigit().fixedSize() }
            Spacer(minLength: 8)
            controls()
        }
    }

    @ViewBuilder private func chip(_ n: Int, _ title: String, _ c: Color, _ st: Style, action: @escaping () -> Void, help: String) -> some View {
        if n > 0 {
            Button(action: action) {
                HStack(spacing: 5) {
                    Circle().fill(c).frame(width: 9, height: 9)
                    Text(st == .dots ? "\(n)" : "\(n) \(title)").monospacedDigit().fixedSize()   // 不准截字，擠不下讓 ViewThatFits 退到短版
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(c.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain).help(help)
        }
    }
}

/// 左側樓層索引列（寬 196）：由上往下＝大樓由上往下；點樓層＝鏡頭對準，再點一次回預設；閒置那行可展開；大廳行點了開保全卡
struct FloorRail: View {
    let rows: [FloorRailRow]
    let selected: String?
    let guardLevel: GuardLevel
    var cityAlerts = 0
    @Binding var idleOpen: Bool
    let onFloor: (String) -> Void
    let onHover: (String?) -> Void
    let onGuard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("樓層").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { r in
                        row(r)
                        if r.kind == .idle && idleOpen {
                            ForEach(Array(r.idleNames.enumerated()), id: \.offset) { _, p in
                                Button { onFloor(r.id) } label: {
                                    HStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 1.5).fill(p.accent.flatMap(Color.init(hex:)) ?? Color.gray.opacity(0.5)).frame(width: 3, height: 14)
                                        Text(p.floorNo).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                                        Text(p.name).font(.system(size: 13)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, 18).padding(.trailing, 8).frame(height: 22).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    cityRow
                }
                .padding(.horizontal, 4).padding(.bottom, 6)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func row(_ r: FloorRailRow) -> some View {
        Button {
            switch r.kind {
            case .idle: idleOpen.toggle(); if idleOpen { onFloor(r.id) }
            case .lobby: onGuard()
            default: onFloor(r.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(r.accent.flatMap(Color.init(hex:)) ?? Color.gray.opacity(0.4)).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if !r.floorNo.isEmpty { Text(r.floorNo).monospacedDigit().foregroundStyle(.secondary) }
                        Text(r.title).lineLimit(1).truncationMode(.middle)
                        if r.kind == .idle { Image(systemName: idleOpen ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(r.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 2)
                        badges(r)
                    }
                }
            }
            .padding(.horizontal, 6).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected == r.id ? Color.accentColor.opacity(0.18) : Color.clear))
            .opacity(r.kind == .project && !r.active ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in onHover(inside ? r.id : nil) }
        .help(r.kind == .idle ? "展開閒置專案清單" : r.kind == .lobby ? "打開保全面板" : "鏡頭對準這層；再點一次回到預設")
    }

    /// 最下面一行「城市」：點了鏡頭飛到俯瞰城市，再點一次回預設（10-21）
    private var cityRow: some View {
        Button { onFloor("city") } label: {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.65, green: 0.64, blue: 0.62)).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) { Image(systemName: "building.2").foregroundStyle(.secondary); Text("城市") }
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 6) {
                        Text("硬碟・雲端・伺服器・城牆").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 2)
                        if cityAlerts > 0 { Text("!\(cityAlerts)").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(Color(red: 0.94, green: 0.27, blue: 0.27)) }
                    }
                }
            }
            .padding(.horizontal, 6).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected == "city" ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("鏡頭飛到俯瞰城市（這台 Mac 的外部資源）；再點一次回到預設")
    }

    @ViewBuilder private func badges(_ r: FloorRailRow) -> some View {
        HStack(spacing: 4) {
            if r.kind == .lobby {
                Circle().fill(guardLevel.color).frame(width: 8, height: 8)
                Text(guardLevel.title).foregroundStyle(guardLevel.color)
            }
            if r.waiting > 0 { Text("●\(r.waiting)").foregroundStyle(Color(red: 0.94, green: 0.27, blue: 0.27)) }
            if r.stuck > 0 { Text("●\(r.stuck)").foregroundStyle(Color(red: 0.98, green: 0.45, blue: 0.09)) }
            if r.finished > 0 { Text("✓\(r.finished)").foregroundStyle(Color(red: 0.13, green: 0.77, blue: 0.37)) }
            if r.working > 0 { Text("\(r.working)").foregroundStyle(Color(red: 0.65, green: 0.55, blue: 0.98)) }
        }
        .font(.system(size: 12, weight: .bold).monospacedDigit())
    }
}

/// 操作說明（? 按鈕；第一次開 3D 檢視自動彈一次）
struct OfficeHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("操作說明").font(.headline)
            Group {
                Text("・拖曳：轉視角　捲動：放大縮小　按住滾輪拖曳：平移")
                Text("・WASD／方向鍵：走動　Q／E：升降")
                Text("・點角色（或它的名牌）：右邊看它的對話、直接跟它講話；等你回答的另外開回答卡；要開終端機按窗格上的終端機鈕或右鍵")
                Text("・右鍵角色：放行、退回、派工、重新裝潢⋯")
                Text("・左邊樓層列：點一下鏡頭對準那層，再點一次回到預設")
                Text("・上面「需要你」：依時間先後輪流飛過去")
            }
            .font(.callout)
        }
        .padding(14).frame(width: 400, alignment: .leading)
    }
}

extension Color {
    /// "#RRGGBB" → Color
    init?(hex: String) {
        guard let v = TP.hex(hex) else { return nil }
        self.init(nsColor: VoxMat.color(v))
    }
}

// MARK: - 看板／細節卡共用的字（10-20）

extension BlockedReason {
    /// 頭上的符號
    var symbol: String {
        switch self {
        case .permission: "🔒"
        case .rateLimit: "⏳"
        case .apiError: "⚠️"
        case .testRun: "🧪"
        case .build: "🔨"
        case .install: "📦"
        case .unknown: "?"
        }
    }
    var label: String {
        switch self {
        case .permission: "等你按允許"
        case .rateLimit: "額度用完，等重置"
        case .apiError: "API 錯誤"
        case .testRun: "測試跑很久"
        case .build: "建置跑很久"
        case .install: "安裝跑很久"
        case .unknown: "原因不明"
        }
    }
}

extension AIActivity {
    var label: String? {
        switch self {
        case .none: nil
        case .reading: "📖 讀檔中"
        case .editing: "⌨️ 改檔中"
        case .running: "▶️ 執行指令中"
        case .searching: "🔍 搜尋中"
        case .thinking: "💭 思考中"
        case .delegating: "🧑‍🤝‍🧑 交辦子 agent 中"
        }
    }
}

/// token 數縮寫：850、12K、1.2M、3.4B
func tokenShort(_ n: Int) -> String {
    let d = Double(n)
    if n < 1000 { return "\(n)" }
    if n < 1_000_000 { return d < 10_000 ? String(format: "%.1fK", d / 1e3) : "\(n / 1000)K" }
    if n < 1_000_000_000 { return d < 10_000_000 ? String(format: "%.1fM", d / 1e6) : "\(n / 1_000_000)M" }
    return String(format: "%.1fB", d / 1e9)
}

/// 卡住／等你的原因放在一句回報前面（看板那一列、細節卡）
func officeLine(_ c: BoardCard) -> String {
    guard let r = c.blockedReason else { return bubbleLine(c) }
    return "\(r.symbol) \(r.label)・\(bubbleLine(c))"
}

/// 停在角色上：左下角浮出的細節卡
private struct HoverCard: View {
    let card: BoardCard
    var theme: FloorDecor? = nil
    var body: some View {
        let m = Mood.of(card)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: KuboArt.tint(m))).frame(width: 8, height: 8)
                Text(card.title).font(.headline).lineLimit(1)
                Text(card.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Gauges(card: card)
            if let a = card.activity.label { Text(a).font(.callout.weight(.medium)) }
            Text(officeLine(card)).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if !card.subagents.isEmpty {
                Text("子 agent：" + card.subagents.map { $0.description.isEmpty ? ($0.subagentType ?? "未命名") : $0.description }.joined(separator: "、"))
                    .font(.caption).lineLimit(2)
            }
            if let t = card.tokens {
                Text("🔤 \(tokenShort(t.total))　輸入 \(tokenShort(t.input))・輸出 \(tokenShort(t.output))・快取寫 \(tokenShort(t.cacheCreation))・快取讀 \(tokenShort(t.cacheRead))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help("這個 session 累計的 token（不含子 agent）；這一輪輸出 \(t.lastTurnOutput)")
            }
            if let t = theme {
                Text("🏢 \(t.theme.title)・\(t.reason)").font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    .help(t.source == "ai" ? "這層的主題是 AI 依最近的工作挑的" : "這層的主題是本地關鍵字判斷的（還沒問過 AI）")
            }
            Text("\(card.reason)・\(m == .waiting ? "點一下回答" : "點一下跳到視窗")，右鍵更多").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(AnswerCard.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 點了等你回答的角色：問題全文＋直接回答（10-20）。
/// 只有「要你決定」（AI 講完一輪、在一般輸入框等你）才給文字框：走退回同一條路（tmux 打字＋Enter）。
/// 「等你回答」是終端機裡的選單（權限允許、AskUserQuestion 選項）：打字進去會被當成選項鍵，不可靠，所以只給「跳到視窗」。
struct AnswerCard: View {
    let card: BoardCard
    let onJump: () -> Void
    let onClose: () -> Void
    let onSend: (String) -> Void
    @State private var text = ""
    @State private var sent = false         // Return 可能同時觸發 onSubmit 和預設按鈕：只送一次（10-20 審查）
    @FocusState private var focused: Bool

    private var canType: Bool { card.reason.hasPrefix("要你決定") }
    /// 卡片底色：不透明（10-20 UI/UX 優化：毛玻璃會透出底下的螢幕空間標籤，字疊在一起）
    static let cardBg = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 0.97) : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 0.97)
    })

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: KuboArt.tint(.waiting))).frame(width: 8, height: 8)
                Text(card.title).font(.headline).lineLimit(1)
                Text(card.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("關閉").keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(officeLine(card)).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 140)
            if canType {
                HStack(spacing: 8) {
                    TextField("直接回答⋯", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4).focused($focused)
                        .onSubmit(send)
                    Button("送出", action: send)
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .fileDrop($text)
                HStack {
                    Text("在 tmux 裡會直接打進去送出；不在 tmux 的會拷貝並跳過去").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("跳到視窗", action: onJump).controlSize(.small)
                }
            } else {
                HStack {
                    Text(card.blockedReason == .permission ? "它在等你按允許：要在終端機裡選" : "它開了選單在等你：要在終端機裡選")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("跳到視窗", action: onJump).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .background(Self.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { focused = canType }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sent else { return }
        sent = true
        onSend(t)
    }
}

// MARK: - 前台・保全（10-20）

extension GuardLevel {
    var color: Color { Color(nsColor: OfficeBuilder.guardColor(self)) }
}

extension GuardDevice.Kind {
    var title: String {
        switch self {
        case .new: "新裝置"
        case .unnamed: "沒命名"
        case .unconfirmed: "待確認"
        case .named: "已命名"
        }
    }
}

/// 停在保全上：一句話摘要
private struct GuardHover: View {
    let status: GuardStatus
    let scanning: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("🛡️ Security").font(.headline)
                GuardBadge(level: status.level)
                if scanning { ProgressView().controlSize(.small); Text("掃描中").font(.caption) }
            }
            Text(status.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("點一下打開保全面板，右鍵可立即掃描").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(AnswerCard.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct GuardBadge: View {
    let level: GuardLevel
    var body: some View {
        Text(level.title).font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(level.color.opacity(0.25), in: Capsule())
            .overlay(Capsule().strokeBorder(level.color.opacity(0.8)))
    }
}

/// 保全面板裡的 push 守門：最近 24 小時檢查／擋下幾次＋最近幾筆（PushGuard，10-22）
private struct PushGuardSection: View {
    let status: GuardStatus
    @State private var allowed: Set<String> = []     // 這次開面板按過放行的（dir+head）
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Push 守門").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(status.pushChecked == 0 ? "24 小時內沒有 push" : "24 小時內 \(status.pushChecked) 次・擋下 \(status.pushBlocked) 次")
                    .font(.caption).foregroundStyle(status.pushBlocked > 0 ? .orange : .secondary).monospacedDigit()
            }
            ForEach(Array(status.pushRecent.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(e.verdict == .block ? "擋下" : e.verdict == .warn ? "提醒" : "放行").font(.caption.weight(.semibold))
                        .foregroundStyle(e.verdict == .block ? Color.red : e.verdict == .warn ? Color.orange : Color.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(e.repo)\(e.refs.isEmpty ? "" : "・" + e.refs.joined(separator: ","))・\(e.commits) 個 commit" + (e.name.map { "・\($0)" } ?? ""))
                            .font(.callout).lineLimit(1)
                        if !e.reasons.isEmpty {
                            Text(e.reasons.joined(separator: "；")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 4)
                    if e.verdict == .block, let h = e.head, !h.isEmpty, Date().timeIntervalSince(e.at) < 3600 {
                        let k = e.dir + h
                        Button(allowed.contains(k) ? "已放行" : "放行一次") {
                            guard OfficeDemo.mode == nil, OfficeDemo.guardMode == nil else { allowed.insert(k); return }   // 示範資料不寫檔
                            PushGuard.allow(e); allowed.insert(k)
                        }
                        .controlSize(.small).disabled(allowed.contains(k))
                        .help("這個 repo、這個 HEAD，30 分鐘內 AI 再推一次就不擋（用掉就失效）")
                    }
                    Text(e.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("AI 跑 git push 前保全會先檢查：ghosts、old-history、force push main、金鑰、私人資料直接擋；關鍵字在 board/guard/keywords.txt。誤擋就按「放行一次」")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 點了保全：Wi-Fi 狀態、要注意的裝置、立即掃描、定時巡邏（資料來自 wifiwatch）
private struct GuardCard: View {
    let status: GuardStatus
    let scanning: Bool
    var wall = ""
    @Binding var patrol: Bool
    let onScan: () -> Void
    let onClose: () -> Void
    @State private var showOnline = ProcessInfo.processInfo.environment["SHOWORK_OFFICE_GUARDLIST"] != nil   // 截圖驗證用：一開就展開

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("🛡️ Security").font(.headline)
                GuardBadge(level: status.level)
                Spacer(minLength: 8)
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("關閉").keyboardShortcut(.cancelAction)
            }
            Text(status.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !wall.isEmpty {
                Label(wall, systemImage: "shield.lefthalf.filled").font(.callout).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(wall.contains("關閉") || wall.contains("紅門") ? Color.red : Color.primary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("上次掃描").foregroundStyle(.secondary)
                    if let t = status.lastScan {
                        Text("\(t.formatted(date: .abbreviated, time: .shortened))（\(t.formatted(.relative(presentation: .named)))）")
                            .foregroundStyle(status.stale ? .orange : .primary)
                    } else {
                        Text("還沒掃描過").foregroundStyle(.orange)
                    }
                }
                GridRow {
                    Text("在線裝置").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("\(status.onlineCount) 台（名冊共 \(status.knownCount) 台）").monospacedDigit()
                        if !status.onlineDevices.isEmpty {
                            Button(showOnline ? "收起" : "列出全部") { showOnline.toggle() }
                                .buttonStyle(.link).help("列出上次掃描在線的每一台裝置")
                        }
                    }
                }
            }
            .font(.callout)
            if showOnline { OnlineDeviceList(devices: status.onlineDevices) }
            if status.flagged.isEmpty {
                Label(status.hasData ? "沒有陌生或沒命名的裝置" : "還沒有名冊（wifiwatch 沒跑過）", systemImage: status.hasData ? "checkmark.shield" : "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("要注意的裝置（\(status.flagged.count)）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(status.flagged, id: \.mac) { d in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(d.online ? Color.green : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                                    .help(d.online ? "上次掃描時在線" : "上次掃描時不在")
                                Text(d.kind.title).font(.caption.weight(.semibold))
                                    .foregroundStyle(d.kind == .unconfirmed ? .orange : .red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text([d.ip ?? (d.privacyOnly ? "只有 IPv6（多半是家裡手機的隱私位址）" : nil), d.vendor, d.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・"))
                                        .font(.callout).lineLimit(1)
                                    Text(d.mac + (d.firstSeen.map { "・第一次看到 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                                        .font(.caption).monospaced().foregroundStyle(.secondary).lineLimit(1)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            Divider()
            PushGuardSection(status: status)
            Divider()
            HStack(spacing: 10) {
                Toggle("定時巡邏", isOn: $patrol).toggleStyle(.switch).controlSize(.small)
                    .help("開著時，常駐程式每 30 分鐘最多掃一次（只在 ShoWork42 常駐程式裡有效）")
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                Button(scanning ? "掃描中⋯" : "立即掃描", action: onScan)
                    .disabled(scanning)
                    .help("跑 wifiwatch：ping 整個網段、讀 ARP，約數十秒；有新裝置會記進名冊")
            }
            Text("命名裝置：wifiwatch.sh --label <MAC> <名字>").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 460, alignment: .leading)
        .background(AnswerCard.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 保全面板「列出全部」：上次掃描在線的每一台（10-24 Kang：在線 20 台要看得到是哪些）
private struct OnlineDeviceList: View {
    let devices: [GuardDevice]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(devices, id: \.mac) { d in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(d.kind == .named ? Color.green : d.kind == .unconfirmed ? Color.orange : Color.red).frame(width: 7, height: 7)
                            .help(d.kind.title)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.label ?? d.hostname ?? "（沒命名）").font(.callout).lineLimit(1)
                                .foregroundStyle(d.label == nil ? .secondary : .primary)
                            Text([d.ip ?? "只有 IPv6", d.vendor, d.mac].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
    }
}

/// Agent交流互動板（點牆上的螢幕打開）：全部留言、最新在上（資料 board/b1-board.jsonl，開的時候讀一次）
private struct B1BoardCard: View {
    let onClose: () -> Void
    @State private var posts: [B1Post] = Array(B1Board.all().reversed())
    @State private var top: Int? = OfficeMemory.boardTop
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Agent交流互動板").font(.headline)
                Text("共 \(posts.count) 則").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 8)
                Button { posts = Array(B1Board.all().reversed()) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("重新整理").accessibilityLabel("重新整理")
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("關閉").accessibilityLabel("關閉").keyboardShortcut(.cancelAction)
            }
            Text("AI 在 B1 休息時留下的工作心得；每則也會轉給隊長當流程優化的參考").font(.caption).foregroundStyle(.secondary)
            if posts.isEmpty {
                Text("還沒有留言。").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(posts, id: \.id) { p in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("#\(p.id)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                                    Text(p.name + (p.project.isEmpty ? "" : "（\(p.project)）")).font(.callout.weight(.semibold))
                                    if let r = p.re { Text("↪#\(r)").font(.caption).foregroundStyle(.secondary) }
                                    Spacer(minLength: 4)
                                    Text(p.at.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                }
                                Text(p.text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                            .id(p.id)
                            if p.id != posts.last?.id { Divider() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $top, anchor: .top)
                .onChange(of: top) { _, v in OfficeMemory.boardTop = v }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)       // 留言少時不要撐出一大塊空白
            }
        }
        .padding(12)
        .frame(width: 460, alignment: .leading)
        .background(AnswerCard.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 示範資料

/// 截圖／量 CPU 用的假資料（只看環境變數，正式使用不會設）：
///   SHOWORK_OFFICE_DEMO=all     每種動作、卡住原因、子 agent、等你回答各一個＋休息（咖啡吧）＋隊長；保全＝警示
///   SHOWORK_OFFICE_DEMO=idle    真資料，但沒有人在工作（量閒置 CPU）
///   SHOWORK_OFFICE_DEMO=floors  N 層假專案（SHOWORK_OFFICE_DEMO_FLOORS，預設 15），量十幾層大樓的夜景燈光
///   SHOWORK_OFFICE_DEMO=camera  真資料，開窗 6 秒後最後一個人變成「要你決定」（看鏡頭會不會飛過去）
///   SHOWORK_OFFICE_GUARD=normal|notice|alert  保全換成假狀態（不設：all 用警示、其他用真資料）
enum OfficeDemo {
    static let mode = ProcessInfo.processInfo.environment["SHOWORK_OFFICE_DEMO"]
    static let guardMode = ProcessInfo.processInfo.environment["SHOWORK_OFFICE_GUARD"]

    /// 示範的右側對話窗格（10-25）：一般 AI 的對話，含中途的話與工具摘要
    static var personThread: [CaptainLine] {
        let t = Date().addingTimeInterval(-600)
        return [
            CaptainLine(id: "p1", at: t, role: .kang, text: "幫我把登入頁的錯誤訊息改成中文", via: "戰情中心"),
            CaptainLine(id: "p2", at: t.addingTimeInterval(20), role: .captain, text: "好，我先找登入頁在哪。"),
            CaptainLine(id: "p3", at: t.addingTimeInterval(25), role: .tool, text: "搜尋檔案"),
            CaptainLine(id: "p4", at: t.addingTimeInterval(30), role: .tool, text: "讀檔：LoginView.swift"),
            CaptainLine(id: "p5", at: t.addingTimeInterval(60), role: .tool, text: "修改：LoginView.swift"),
            CaptainLine(id: "p6", at: t.addingTimeInterval(80), role: .tool, text: "執行指令：跑單元測試"),
            CaptainLine(id: "p7", at: t.addingTimeInterval(120), role: .captain, text: "改好了：3 個錯誤訊息都換成中文，**測試 12 個全過**。要順便改註冊頁嗎？"),
        ]
    }

    /// 示範的隊長對話與派工單（第 3 步截圖用）
    static var captainThread: [CaptainLine] {
        let t = Date()
        return [
            CaptainLine(id: "d1", at: t.addingTimeInterval(-1500), role: .kang, text: "把 ProjectD 上架做完，客製 NFC 訂購頁一起做", via: "戰情中心"),
            CaptainLine(id: "d2", at: t.addingTimeInterval(-1480), role: .captain, text: "收到，兩條線並行：\n- **Dora** 繼續 ProjectD 上架\n- 客製訂購頁我開 workflow，三個決策已發到收件匣，你拍板就開工"),
            CaptainLine(id: "d3", at: t.addingTimeInterval(-900), role: .report, text: "【工作回報】Dora（ProjectD）：重建商品 完成度 92%", via: "AI工作戰情中心"),
            CaptainLine(id: "d4", at: t.addingTimeInterval(-600), role: .report, text: "【派工回報 T1022020414】Ethan：完成——794c14b 已 push", via: "AI工作戰情中心"),
            CaptainLine(id: "d5", at: t.addingTimeInterval(-590), role: .captain, text: "Ethan 的固定英文名已上線，我核對過 origin/main 一致。Dora 商品建到 11 個，有 3 個價格被 Apple 限制調整，建完列表給你看。"),
            CaptainLine(id: "d6", at: t.addingTimeInterval(-120), role: .kang, text: "年繳打七折可以", via: "終端機"),
        ]
    }
    static var captainTasks: [CaptainTask] {
        [CaptainTask(id: "T1022021500", from: "x", to: "Dora", project: "ProjectD", text: "ProjectD 上架：重建 15 個訂閱商品並列最終價格表"),
         CaptainTask(id: "T1022022000", from: "x", to: "Bella", project: "Okle42", text: "客製 NFC 訂購頁：先出三版版型")]
    }
    static let start = Date()

    static func apply(_ cards: [BoardCard]) -> [BoardCard] {
        guard let mode, let base = cards.first(where: { !$0.id.contains("#") }) else { return cards }
        switch mode {
        case "idle":
            return cards.map { c in
                var c = c
                if c.column == .active || c.column == .stuck { c.column = .done; c.reason = "閒置"; c.activity = .none; c.subagents = []; c.blockedReason = nil }
                return c
            }
        case "floors":
            // 10-25 夜景量測：N 個假專案各一層（SHOWORK_OFFICE_DEMO_FLOORS，預設 15），重現 Kang 十幾層的大樓
            let n = Int(ProcessInfo.processInfo.environment["SHOWORK_OFFICE_DEMO_FLOORS"] ?? "") ?? 15
            return (0..<n).map { i in
                var c = base
                c.id = "floor-\(i)"; c.sessionId = c.id; c.project = String(format: "Demo-F%02d", i + 1); c.title = "F\(i + 1)-工作"
                c.column = .active; c.reason = "工作中"; c.activity = .none; c.report = nil; c.review = nil; c.captain = false
                c.visiting = nil; c.unused = false; c.blockedReason = nil; c.subagents = []; c.permit = nil
                return c
            }
        case "camera":
            guard Date().timeIntervalSince(start) > 6, var last = cards.last(where: { !$0.id.contains("#") && Mood.of($0) != .waiting }) else { return cards }
            last.column = .review; last.reason = "要你決定：鏡頭測試，要不要飛過來？"; last.activity = .none
            return cards.map { $0.id == last.id ? last : $0 }
        case "all":
            var out: [BoardCard] = []
            func make(_ project: String, _ name: String, _ col: BoardColumn, _ reason: String, _ f: (inout BoardCard) -> Void = { _ in }) {
                var c = base
                c.id = "demo-\(String(format: "%02d", out.count))"; c.sessionId = c.id; c.project = project; c.title = name; c.column = col; c.reason = reason
                c.report = nil; c.review = nil; c.captain = false; c.visiting = nil; c.unused = false
                c.activity = .none; c.blockedReason = nil; c.subagents = []
                c.tokens = TokenUsage(input: 1200 * (out.count + 1), output: 48_000 * (out.count + 1), cacheCreation: 310_000, cacheRead: 1_150_000 * (out.count + 1))
                c.detail = "示範：\(name)"
                f(&c); out.append(c)
            }
            for (n, a) in [("Reader-讀檔", AIActivity.reading), ("Editor-改檔", .editing), ("Runner-跑指令", .running),
                           ("Seeker-搜尋", .searching), ("Thinker-思考", .thinking)] {
                make("Demo-動作", n, .active, "工作中") { c in
                    c.activity = a
                    c.report = SelfReport(status: .working, progress: 40 + out.count * 7, confidence: 80, summary: "示範：\(n)")
                }
            }
            make("Demo-動作", "Boss-交辦", .active, "工作中") { c in
                c.activity = .delegating
                c.subagents = [SubagentInfo(description: "office3d-upgrade", subagentType: "general-purpose"),
                               SubagentInfo(description: "查 SceneKit 渲染", subagentType: "Explore"),
                               SubagentInfo(description: "local_workflow", subagentType: "local_workflow", background: true),
                               SubagentInfo(description: "寫測試", subagentType: "general-purpose")]
            }
            for r in BlockedReason.allCases where r != .unknown {
                make("Demo-卡住", "\(r.rawValue)-卡住", .stuck, "超過 10 分鐘沒動靜") { $0.blockedReason = r }
            }
            make("Demo-卡住", "Mystery-卡住", .stuck, "超過 10 分鐘沒動靜")
            make("Demo-等你", "Asker-權限", .review, "等你回答") { c in
                c.blockedReason = .permission; c.detail = "要跑 rm -rf build/，等你按允許"
                c.permit = PermitRequest(id: "demo-permit", sessionId: c.sessionId, pid: nil, tool: "Bash", summary: "rm -rf build/ && swift build -c release",
                                         detail: "清掉舊的建置重新編譯", alwaysRules: #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"swift build:*"}],"behavior":"allow","destination":"localSettings"}]"#,
                                         at: Date().addingTimeInterval(-40))
            }
            make("Demo-等你", "Quiz-選擇題", .review, "等你回答") { c in
                c.permit = PermitRequest(id: "demo-ask", sessionId: c.sessionId, pid: nil, tool: "AskUserQuestion", summary: "午餐吃什麼？／要加什麼配料？",
                                         at: Date().addingTimeInterval(-25))
                c.permit?.questions = [
                    AskQuestion(question: "午餐吃什麼？", header: "午餐", options: [.init(label: "拉麵", description: "日式拉麵"), .init(label: "咖哩", description: "咖哩飯")]),
                    AskQuestion(question: "要加什麼配料？", header: "配料", multiSelect: true, options: [.init(label: "蛋"), .init(label: "海苔"), .init(label: "叉燒")]),
                ]
            }
            make("Demo-等你", "Planner-計畫", .review, "等你回答") { c in
                c.permit = PermitRequest(id: "demo-plan", sessionId: c.sessionId, pid: nil, tool: "ExitPlanMode", summary: "計畫寫好了，要照這個做嗎？",
                                         at: Date().addingTimeInterval(-10))
                c.permit?.input = ##"{"plan":"# 計畫：建立 hello.txt\n\n1. 在專案A 資料夾建立 **hello.txt**\n2. 內容寫一行 `hi`\n3. 跑 `cat hello.txt` 確認"}"##
            }
            make("Demo-等你", "Chooser-決定", .review, "要你決定：A 還是 B？") { c in
                c.report = SelfReport(status: .review, ask: "要用 A 方案（快）還是 B 方案（穩）？A 半天做完但只有單元測試；B 要一天但會加真機驗收。")
            }
            make("Demo-等你", "Done-做完", .review, "做完了，你還沒看")
            for n in ["Coffee-休息", "Latte-休息", "Mocha-休息"] { make("Demo-休息", n, .done, "閒置") }
            make("Demo-休息", "Sleepy-沒交代", .done, "閒置") { $0.unused = true }
            make("Demo-隊長", "Captain-派工", .active, "工作中") { c in c.captain = true; c.activity = .thinking }
            // 影分身：人住 Demo-休息、cd 去 Demo-動作逛（那層前帶畫半透明分身，驗證站位不穿家具）
            for n in ["Visitor-逛", "Guest-逛"] { make("Demo-休息", n, .active, "工作中") { $0.visiting = "Demo-動作" } }
            return out
        default:
            return cards
        }
    }

    /// 示範資料的大樓（10-20 第四版）：用一份記憶體裡的名冊（不碰你的 board/tower.json），示範專案依序配不同主題；閒晃延續上一次
    @MainActor final class TowerCache {
        private var reg = TowerRegistry()
        private var prev: [String: WanderState] = [:]
        private var prevCars: [WanderCar] = []        // 兩部電梯停哪、何時有空（10-22）
        private var sig = ""
        private var out: (TowerPlan, [String: FloorDecor], WanderPlan) = (TowerPlan(), [:], WanderPlan())
        static let themes: [String: TowerTheme] = ["demo-動作": .app_studio, "demo-卡住": .print_shop, "demo-等你": .call_room,
                                                   "demo-休息": .library, "demo-隊長": .monitor]
        func make(_ deps: [OfficeDepartment], cards: [BoardCard], real: [String: FloorDecor]) -> (TowerPlan, [String: FloorDecor], WanderPlan) {
            let now = Date()
            let s = deps.map { "\($0.name)\($0.isActive)" }.joined(separator: ",") + "|" + cards.map { "\($0.id)\(Mood.of($0).rawValue)" }.joined(separator: ",")
                + "|\(Int(now.timeIntervalSince1970 / WanderPlanner.bucket))"
            if s == sig { return out }
            sig = s
            let (plan, _) = TowerPlan.build(departments: deps, cards: cards, registry: &reg, usage: { [:] }, now: now)
            var d = real
            for f in plan.projectFloors {
                guard let name = f.project else { continue }
                if let t = Self.themes[name.lowercased()] {
                    d[name.lowercased()] = FloorDecor(theme: t, accentColor: t.accent, props: Array(t.optionalProps.prefix(3)), reason: "示範", source: "test", decidedAt: now)
                } else if d[name.lowercased()] == nil {
                    d[name.lowercased()] = FloorDecor.local(WorkSignature.make(DecorInput(project: name)), now: now)
                }
            }
            for (k, v) in TowerStore.themeOverrides() { d[k] = v }
            let w = WanderPlanner.plan(people: TowerStore.people(cards, tower: plan), tower: plan, previous: prev, now: now,
                                       visible: true, mode: TowerStore.wanderMode, rain: OfficeWeather.shared.current?.kind.isWet ?? false,
                                       cars: prevCars)
            prev = w.states; prevCars = w.cars
            out = (plan, d, w)
            return out
        }
    }

    /// 示範資料的部門：常駐名冊照真的，示範專案當臨時部門接在後面
    static func departments(_ real: [OfficeDepartment], cards: [BoardCard]) -> [OfficeDepartment] {
        guard mode != nil else { return real }
        return OfficeDepartments.build(residents: real.filter(\.isResident).map(\.name), cards: cards)
    }

    /// 示範保全（假 MAC，不是你名冊裡的）
    static func guardStatus(_ real: GuardStatus) -> GuardStatus {
        guard let m = guardMode ?? (mode == "all" ? "alert" : nil) else { return real }
        var g = GuardStatus()
        g.hasData = true; g.knownCount = 14; g.onlineCount = 9
        g.lastScan = Date().addingTimeInterval(m == "notice" ? -30 * 3600 : -25 * 60)
        g.stale = m == "notice"
        switch m {
        case "normal":
            g.level = .normal
        case "notice":
            g.level = .notice
            g.flagged = [GuardDevice(mac: "02:00:00:00:00:02", ip: "192.0.2.88", vendor: "示範廠商", label: "★不在你清單上的裝置", kind: .unconfirmed, online: false)]
        default:
            g.level = .alert
            g.flagged = [GuardDevice(mac: "02:00:00:00:00:01", ip: "192.0.2.77", vendor: "Espressif（示範）", kind: .new, online: true, firstSeen: Date().addingTimeInterval(-600)),
                         GuardDevice(mac: "02:00:00:00:00:02", ip: "192.0.2.88", vendor: "示範廠商", label: "★不在你清單上的裝置", kind: .unconfirmed, online: true)]
        }
        var parts: [String] = []
        if g.stale { parts.append("很久沒掃描了") }
        parts.append("上次在線 \(g.onlineCount) 台／名冊 \(g.knownCount) 台")
        let s = g.flagged.filter { $0.kind != .unconfirmed }.count, p = g.flagged.count - s
        if s > 0 { parts.append("\(s) 台沒命名") }
        if p > 0 { parts.append("\(p) 台待確認") }
        g.summary = parts.joined(separator: "，") + "（示範）"
        if m == "alert" {
            let t = Date()
            g.merge(pushes: [
                { var e = PushEvent(at: t.addingTimeInterval(-300), name: "Ethan", repo: "Okle42/示範", dir: "/x", refs: ["main"], commits: 2, verdict: .block,
                          reasons: ["force push 到 main 會改寫遠端歷史"]); e.head = "abc"; return e }(),
                PushEvent(at: t.addingTimeInterval(-3600), name: "Dora", repo: "Okle42/示範二", dir: "/y", refs: ["main"], commits: 1, verdict: .ok, reasons: []),
            ])
        }
        return g
    }
}

/// NSMenuItem 帶 closure
final class ClosureItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: - SceneKit 橋接

struct OfficeScene: NSViewRepresentable {
    let islands: [Island]
    let tower: TowerPlan
    let decor: [String: FloorDecor]
    let wander: WanderPlan
    let guardStatus: GuardStatus
    let guardScanning: Bool
    var city = CityState()
    let night: Bool
    var look: SkyLook? = nil         // 10-21 日出日落：有給就用連續天色，沒給照 night 二分
    var weather = WeatherLook.clear  // 10-21 台北真實天氣：雨、閃電（天色已疊在 look 裡）
    var style = OfficeStyle.voxel     // 10-22 畫面風格
    let loaded: Bool            // 看板讀過一次了（還沒讀到前卡片是空的，不能當成「第一次載入」）
    let resetTick: Int
    var camRequest = CamRequest()
    var railHover: String? = nil
    var cardSize: CGSize? = nil         // 左下角開著的卡片大約多大（那一塊不畫標籤）
    let onHover: (String?) -> Void
    var onHoverPoint: (CGPoint) -> Void = { _ in }
    let onClick: (String) -> Void
    let menu: (String) -> NSMenu?

    func makeNSView(context: Context) -> OfficeSCNView {
        let v = OfficeSCNView(frame: .zero, options: nil)
        v.builder = OfficeBuilder()
        v.scene = v.builder.scene
        v.backgroundColor = OfficeBuilder.bg
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.defaultCameraController.maximumVerticalAngle = 55     // 10-22 Kang：85° 會轉到幾乎正上方往下看（樓板被切、卡在怪角度）
        v.antialiasingMode = .multisampling2X
        // 省電（10-20 實測 30 fps＋陰影＋4x 反鋸齒 CPU 30–75%）：12 fps 跟部門島的 8 fps 同一級；不開陰影
        v.preferredFramesPerSecond = v.baseFps
        v.rendersContinuously = false
        v.isPlaying = false                 // 按需渲染：有動畫才播（refreshPlaying）
        v.pointOfView = v.builder.camera
        // B1 機房平常藏著：第一次往下移才編 shader、上傳 GPU 會頓一下 ⇒ 開場就在背景先準備好（10-22 Kang：移到地下室要等一下才有畫面）
        v.prepare([v.builder.basement.root], completionHandler: nil)
        // 電纜光點（10-22 Kang：電力像慢慢輸入大樓）：每 30 秒播 3 秒讓光點流一段；機器熱、視窗看不到就不播（省電：不是一直畫）
        let pulse = Timer(timeInterval: 30, repeats: true) { [weak v] _ in
            MainActor.assumeIsolated {
                guard let v, v.windowVisible, !HeatGate.shared.paused, !v.builder.underground else { return }
                v.playFor(3)
            }
        }
        pulse.tolerance = 5
        RunLoop.main.add(pulse, forMode: .common)
        // 地下室 B1 神經網路（10-22）：GraphSource 發布新的 Graphify 圖譜就換（同一張不重建）；還沒跑過 Graphify 時是 NeuralGraph.demo()
        v.graphSub = GraphSource.shared.$graph.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak v] g in
            MainActor.assumeIsolated { guard let v else { return }; v.builder.setNeuralGraph(g); v.playFor(0.2) }
        }
        if ProcessInfo.processInfo.environment["SHOWORK_OFFICE_STATS"] != nil { v.showsStatistics = true }
        // 螢幕空間標籤（10-20 UI/UX 優化）：CALayer 疊在 3D 上；位置在渲染回呼裡更新（不另開 timer）
        if ProcessInfo.processInfo.environment["SHOWORK_OFFICE_LABELS"] != "off" {     // off：量效能時比較用
            v.labels.view.frame = v.bounds
            v.labels.view.autoresizingMask = [.width, .height]
            v.addSubview(v.labels.view)
            v.delegate = v.labels
        }
        return v
    }

    func updateNSView(_ v: OfficeSCNView, context: Context) {
        v.onHover = onHover; v.onHoverPoint = onHoverPoint; v.onClick = onClick; v.menuFor = menu
        v.builder.setWeather(weather)
        if v.style != style { v.applyStyle(style) }
        let nightChanged = v.builder.setLook(look ?? (night ? .night : .day))
        if nightChanged { v.backgroundColor = OfficeBuilder.bg }
        let reframe = v.builder.update(tower: tower, decor: decor, wander: wander, islands: islands,
                                       guardStatus: guardStatus, scanning: guardScanning, animate: v.canAnimate)
        // 第一次（有大小之後）、按「重設視角」⇒ 重新取景；大樓高度變了（樓層進出）只在你沒動過視角時重新取景（不搶走你的視角）
        if v.lastReset != resetTick || reframe == .layout || (reframe == .size && !v.userMoved) {
            if v.lastReset != resetTick || reframe == .layout { v.userMoved = false }
            v.lastReset = resetTick
            v.framed = false
        }
        if !CityMonitor.off { v.builder.updateCity(city, animate: v.canAnimate && !HeatGate.shared.paused) }
        v.frameIfNeeded()
        v.refreshLabels(guardStatus: guardStatus, scanning: guardScanning)
        if v.lastCam != camRequest.tick {
            v.lastCam = camRequest.tick
            v.perform(camRequest.target)
        }
        if v.builder.highlightFloor(railHover) { v.playFor(0.15) }
        v.labels.setOccluder(cardSize.map { CGRect(x: 0, y: 0, width: $0.width + 12, height: $0.height + 12) })
        if cardSize != v.lastCard { v.lastCard = cardSize; v.playFor(0.15) }
        v.noticeWaiting(Set(islands.flatMap(\.people).filter { $0.mood == .waiting }.map(\.id)), loaded: loaded)
        v.playFor(max(v.builder.takeTransient(), nightChanged ? 0.3 : 0))
        v.updateLOD()
    }

    static func dismantleNSView(_ v: OfficeSCNView, coordinator: ()) {
        // 辦公室收起來（換成部門島）：告訴資料層看不到了，不再排閒晃
        if OfficeDemo.mode == nil, !BoardWindow.testMode { BoardModel.shared.wanderVisible = false }
    }
}

final class OfficeSCNView: SCNView {
    var builder: OfficeBuilder!
    /// 訂閱 GraphSource.shared.graph（地下室神經網路的資料）
    var graphSub: AnyCancellable?
    var onHover: ((String?) -> Void)?
    var onHoverPoint: ((CGPoint) -> Void)?
    var onClick: ((String) -> Void)?
    var menuFor: ((String) -> NSMenu?)?
    var lastReset = 0
    var lastCam = 0
    var lastCard: CGSize?
    private(set) var style = OfficeStyle.voxel
    /// 換風格：後製＋鏡頭（微縮模型＝正交、等角視角；換完重新取景）
    func applyStyle(_ s: OfficeStyle) {
        style = s
        OfficeBuilder.style = s
        builder.setStyle(s)
        technique = OfficeStyleFX.technique(s, device: device)
        if let pov = pointOfView, pov !== builder.camera { builder.camera.transform = pov.presentation.transform; pointOfView = builder.camera; builder.weatherFX.follow(builder.camera) }   // 10-23：同 OfficeBuilder.place
        if let c = builder.camera.camera {
            c.usesOrthographicProjection = s == .diorama
            if s == .diorama {
                let t = defaultCameraController.target, p = builder.camera.position
                c.orthographicScale = OfficeStyleFX.orthoScale(dist: Double(hypot(hypot(p.x - t.x, p.y - t.y), p.z - t.z)))
            }
        }
        framed = false
        playFor(0.3)
    }
    var framed = false
    lazy var labels = OfficeLabels()
    private var labelSig = ""

    /// 標籤資料（誰、什麼狀態、錨點）：內容變了才交給渲染執行緒，並補畫一張（閒置時 SceneKit 不會自己畫）
    private var lastGuard: (GuardStatus, Bool)?
    func refreshLabels(guardStatus: GuardStatus, scanning: Bool) {
        lastGuard = (guardStatus, scanning)
        let (ps, fs) = builder.labelTargets()
        var specs: [LabelSpec] = []
        for p in ps.sorted(by: { $0.id < $1.id }) {
            if p.id == "guard" { specs.append(OfficeLabels.guardSpec(guardStatus, scanning: scanning, anchor: p.anchor)) }
            else if let c = p.card { specs.append(OfficeLabels.spec(c, mood: p.mood, anchor: p.anchor, floor: p.floor)) }
        }
        for c in builder.cityLabelTargets() { specs.append(OfficeLabels.citySpec(id: c.id, text: c.text, alert: c.alert, anchor: c.anchor)) }
        let floors = fs.map { FloorLabelSpec(id: $0.id, node: $0.node, height: $0.height, title: $0.title, accent: $0.accent, kind: $0.kind, names: $0.names) }
        let sig = specs.map { "\($0.id)|\($0.text)|\(ObjectIdentifier($0.anchor!).hashValue)" }.joined(separator: ",") + "#" + floors.map { "\($0.id)|\($0.title)|\(ObjectIdentifier($0.node).hashValue)" }.joined(separator: ",")
        guard sig != labelSig else { return }
        labelSig = sig
        labels.set(specs, floors: floors)
        playFor(0.15)
    }

    /// 需要你列／索引列的鏡頭請求
    func perform(_ t: CamRequest.Target) {
        switch t {
        case .none: return
        case .person(let id):
            guard let n = builder.personNode(id) else { return }
            userMoved = true
            fly(to: n, distance: 16)          // 看得到整個人＋這層的左右（7 太近，只看到一顆頭）
            if probing { print("office camera →", id); fflush(stdout) }
        case .city(let id):
            userMoved = true
            if let p = builder.city.point(id) { fly(toPoint: p, distance: 26) } else { builder.frameCity(self); camMoved(0.7) }
        case .floor("city"):
            builder.frameCity(self)
            userMoved = true
            camMoved(0.7)
            if probing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("office stats city", self.builder.stats()); print("office labels city", self.labels.stats)
                for c in self.builder.cityLabelTargets() { let q = self.projectPoint(c.anchor.presentation.worldPosition); print("city label", c.id, OfficeLabels.int(q.x), OfficeLabels.int(q.y), String(format: "%.3f", q.z), self.labels.rect(c.id).map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "未畫") }
                fflush(stdout) } }
        case .floor(let id):
            guard builder.frameFloor(id, self) else { return }
            userMoved = true
            camMoved(0.7)
            if probing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.printFloorPixels("focus \(id)") } }
        }
    }

    /// 驗收：每層在畫面上多高（點）、樓板寬佔畫面寬幾 %
    func printFloorPixels(_ tag: String) {
        // 每層：畫面上的高度（點）／樓板寬佔畫面寬／樓層高佔畫面高
        let s = builder.floorPixels(self).map { String(format: "%@=%.0fpt/%.0f%%W/%.0f%%H", $0.0, $0.1, $0.2 * 100, $0.1 / max(1, bounds.height) * 100) }.joined(separator: " ")
        print("floor px [\(tag)] view=\(Int(bounds.width))x\(Int(bounds.height))", s); fflush(stdout)
    }
    private var downAt: NSPoint?
    private var hoverId: String?
    private var prevWaiting: Set<String>?
    private let probing = ProcessInfo.processInfo.environment["SHOWORK_OFFICE_PROBE"] != nil
    let baseFps = Int(ProcessInfo.processInfo.environment["SHOWORK_OFFICE_FPS"] ?? "") ?? 12
    static let walkFps = 10, moveFps = 24

    override var acceptsFirstResponder: Bool { true }

    /// 視窗看得到嗎（被蓋住、縮到 Dock 就不是）
    var windowVisible: Bool { window?.occlusionState.contains(.visible) ?? false }
    /// 可以播搬家／閒晃動畫嗎：測試視窗在螢幕外不推進動畫，一律直接到位
    var canAnimate: Bool { !BoardWindow.testMode && !Look.reduceMotion && windowVisible }

    /// 你動過視角（拖、捲、走）之後，視窗改大小就不再自動取景；按「重設視角」才恢復
    var userMoved = false
    func frameIfNeeded() {
        guard !framed, bounds.width > 10, bounds.height > 10 else { return }
        framed = true
        builder.frameCamera(self)
        // 關窗重開（10-24 C）：你動過的視角接回去
        if let m = OfficeMemory.camera, !userMoved {
            builder.camera.transform = m.transform; pointOfView = builder.camera; builder.weatherFX.follow(builder.camera)
            defaultCameraController.target = m.target
            userMoved = true
        }
        camMoved(0.7)
        updateLOD()
    }

    /// 鏡頭停下來時算一次：看板遠近、面向鏡頭的牆淡掉、門牌換牆、夜晚燈光指派（不每幀算）
    func updateLOD() {
        followRain()
        if userMoved, !BoardWindow.testMode || ProcessInfo.processInfo.environment["SHOWORK_TEST_REOPEN"] != nil, let pov = pointOfView {
            OfficeMemory.camera = (pov.presentation.transform, defaultCameraController.target)
        }
        let wasUnder = builder.underground
        if builder.updateLOD(camera: pointOfView?.presentation.worldPosition ?? SCNVector3Zero, target: defaultCameraController.target) {
            playFor(0.3)
        }
        // 進出地下室（10-22 B1 機房）：城市名牌要拿掉／放回；圖譜開始／停止自轉 ⇒ 重算要不要持續渲染
        if builder.underground != wasUnder {
            if let (g, s) = lastGuard { refreshLabels(guardStatus: g, scanning: s) }
            refreshPlaying()
        }
    }

    // MARK: 按需渲染（10-20 Kang：全員閒置時 12 fps 一直畫，CPU 還是 3–20%）
    // 場景裡有持續動畫（「改檔」打字、保全掃描中）才 isPlaying；其餘時候停住，資料變了／滑鼠動了 SceneKit 自己會重畫那一張。
    // 會跑一下就停的（跳三下、鏡頭飛過去、慣性轉動、搬家、閒晃）用 playFor 播到時間到就停，到點只排一次 asyncAfter，不輪詢。
    // 幀率：搬家 24（只有那 2 秒）、有人在走 10、其餘 12。
    private var playUntil = Date.distantPast
    private var checkPending = false
    func playFor(_ s: TimeInterval) {
        if s > 0 { playUntil = max(playUntil, Date().addingTimeInterval(s)) }
        refreshPlaying()
        scheduleCheck()
    }
    private func scheduleCheck() {
        let wait = playUntil.timeIntervalSinceNow
        guard !checkPending, wait > 0 else { return }
        checkPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in
            guard let self else { return }
            self.checkPending = false
            self.refreshPlaying()
            self.scheduleCheck()
        }
    }
    func refreshPlaying() {
        let visible = BoardWindow.testMode || windowVisible   // 測試視窗開在螢幕外，照樣要畫
        OfficeLabels.visibleFlag = visible
        // 10-24：場景裡有永遠在跑的動作（城市電線電流、打字的手、手電筒截短…），SceneKit 只要有動作在跑就一直畫，
        // isPlaying=false 擋不住 ⇒ 視窗關著／縮到 Dock／被蓋住時整個場景暫停（動作停在原地，回來接著跑）。實測：關窗後還畫約 7% CPU
        if let sc = scene, sc.isPaused == visible { sc.isPaused = !visible; Log.note("OFFICE scene paused=\(!visible) window=\(window != nil) occ=\(window?.occlusionState.rawValue ?? 0)") }
        let now = Date()
        let fps = now < builder.moveUntil ? Self.moveFps : builder.looping ? baseFps : now < builder.walkUntil ? Self.walkFps : baseFps
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
        // 機器熱（cool42 warm 以上／系統 serious 以上）⇒ 持續動畫全停，只剩「操作或資料變了」那一下（10-20 Kang）
        let hot = HeatGate.shared.paused
        // 地下室神經網路自轉（只在鏡頭在 B1 時）也算持續動畫；鏡頭回到地上就停
        let want = visible && (((builder.looping || builder.basementSpinning) && !hot) || now < playUntil)
        if isPlaying != want {
            isPlaying = want
            if probing { print("office playing", want, "fps", fps); fflush(stdout) }
        }
    }

    /// 鏡頭動了（拖、捲、走、飛）：播到慣性停，停了再算一次 cutaway
    private var lodDue = Date.distantPast, lodPending = false
    func camMoved(_ s: TimeInterval) {
        playFor(s)
        lodDue = max(lodDue, Date().addingTimeInterval(s))
        guard !lodPending else { return }
        lodPending = true
        fireLOD()
    }
    private func fireLOD() {
        let wait = lodDue.timeIntervalSinceNow
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait) + 0.05) { [weak self] in
            guard let self else { return }
            if self.lodDue.timeIntervalSinceNow > 0 { self.fireLOD(); return }
            self.lodPending = false
            self.updateLOD()
        }
    }

    /// 出現「新的」等你回答：你沒在動視角 ⇒ 鏡頭飛過去（不自動飛回）；你動過視角 ⇒ 不搶鏡頭，只讓它頭上的符號多跳三下
    func noticeWaiting(_ ids: Set<String>, loaded: Bool) {
        // 10-20 第三版：辦公室在第一次讀到卡片之前就畫出來了，還沒讀到卡片時不算「第一次載入」
        guard loaded else { return }
        if probing, let prev = prevWaiting, prev != ids { print("office waiting", prev.sorted(), "→", ids.sorted()); fflush(stdout) }
        defer { prevWaiting = ids }
        guard let prev = prevWaiting, let id = ids.subtracting(prev).sorted().first,
              let n = builder.personNode(id) else { return }
        if !userMoved && downAt == nil && framed {
            fly(to: n)
            if probing { print("office camera →", id); fflush(stdout) }
        } else {
            playFor(builder.bounceMark(id))
            if probing { print("office bounce", id); fflush(stdout) }
        }
    }
    /// 角色（或保全）身上的點：點擊盒中心
    private func center(_ n: SCNNode) -> SCNVector3 {
        (n.childNode(withName: "hitbox", recursively: true) ?? n).worldPosition
    }
    private func fly(to n: SCNNode, distance: CGFloat? = nil) {
        fly(toPoint: center(n), distance: distance, guardView: n.name == "guard")
    }
    /// 飛到某一點：維持你現在的水平方向，但仰角壓低（大樓剖面：從太高的地方看會被上一層樓板擋住）
    func fly(toPoint target: SCNVector3, distance: CGFloat? = nil, guardView: Bool = false) {
        guard let pov = pointOfView else { return }
        let t0 = defaultCameraController.target, p = pov.position
        var dir = SCNVector3(p.x - t0.x, p.y - t0.y, p.z - t0.z)
        let len = sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
        if len < 0.001 { dir = SCNVector3(0.37, 0.15, 0.92) } else { dir = SCNVector3(dir.x / len, dir.y / len, dir.z / len) }
        // 保全：從大廳正面偏右看進去（看得到櫃台旁的保全和後面的監控螢幕）
        if guardView { dir = SCNVector3(0.35, 0.16, 0.92) }
        let h = max(0.001, hypot(dir.x, dir.z)), y = OfficeBuilder.style == .diorama ? 0.26 : min(max(dir.y, 0.06), 0.24), k = sqrt(1 - y * y) / h
        dir = SCNVector3(dir.x * k, y, dir.z * k)
        if dir.z < 0.2 { dir.z = 0.2 }      // 從背後看：後牆擋住，轉到前半圈
        let dist = distance ?? min(max(len, 6), 10)
        // 測試視窗在螢幕外不推進動畫：直接定位
        SCNTransaction.begin(); SCNTransaction.animationDuration = BoardWindow.testMode ? 0 : 1.0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pov.position = SCNVector3(target.x + dir.x * dist, target.y + dir.y * dist, target.z + dir.z * dist)
        pov.look(at: target, up: SCNVector3(0, 1, 0), localFront: SCNNode.localFront)   // 10-21：沿用舊 up 會歪
        SCNTransaction.commit()
        defaultCameraController.target = target
        if let c = pov.camera, c.usesOrthographicProjection { c.orthographicScale = OfficeStyleFX.orthoScale(dist: Double(dist)) }
        camMoved(1.2)
    }

    // 視窗被蓋住／縮到 Dock ⇒ 停止渲染；告訴資料層不要排閒晃、路上的人直接落地
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let w = window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusion), name: NSWindow.didChangeOcclusionStateNotification, object: w)
            NotificationCenter.default.addObserver(self, selector: #selector(heatChanged), name: HeatGate.changed, object: nil)
        }
        reportVisible()
        refreshPlaying()
    }
    /// 熱了／退燒了：路上的人直接落地、重算要不要播
    @objc private func heatChanged() {
        if HeatGate.shared.paused { builder.settle() }
        reportVisible()
        refreshPlaying()
        playFor(0.2)
    }
    @objc private func occlusion() {
        Log.note("OFFICE occlusion visible=\(windowVisible) isVisible=\(window?.isVisible ?? false)")
        rendersContinuously = false
        if !windowVisible { builder.settle() }
        reportVisible()
        refreshPlaying()
    }
    private func reportVisible() {
        guard OfficeDemo.mode == nil, !BoardWindow.testMode else { return }
        BoardModel.shared.wanderVisible = window != nil && windowVisible && !Look.reduceMotion && !HeatGate.shared.paused
    }

    override func setFrameSize(_ s: NSSize) {
        let changed = s != frame.size
        super.setFrameSize(s)
        if changed && !userMoved { framed = false }
        labels.resize(s)
        frameIfNeeded(); probeOnce()
    }
    // 轉視角有慣性：拖曳中與放開後播一秒，讓慣性滑完
    override func mouseDragged(with e: NSEvent) { userMoved = true; camMoved(1.0); super.mouseDragged(with: e); followRain(); checkUnderground() }

    /// 雨要掛在實際在畫的鏡頭上（見 WeatherFX.follow）；換過就記一筆，之後查得到真的發生過
    private func followRain() {
        if builder.weatherFX.follow(pointOfView) {
            Log.note("OFFICE rain 改掛到鏡頭 \(pointOfView?.name ?? "nil")（原本的 builder.camera \(pointOfView === builder.camera ? "同一個" : "不是同一個")）")
        }
    }
    override func rightMouseDragged(with e: NSEvent) { userMoved = true; camMoved(1.0); super.rightMouseDragged(with: e) }
    /// 滾輪＝放大縮小（10-20 Kang：SceneKit 預設滾輪是上下平移）：沿著鏡頭→轉軸那條線拉近拉遠
    /// 鏡頭一越過地面就切地下室（10-22 Kang：原本要等鏡頭停下來才切，移下去要等一下才有畫面）
    func checkUnderground() {
        guard let y = pointOfView?.position.y else { return }
        let was = builder.underground
        _ = builder.setUnderground(y < 0)
        if builder.underground != was {
            if let (g, s) = lastGuard { refreshLabels(guardStatus: g, scanning: s) }
            refreshPlaying(); playFor(0.4)
        }
    }
    /// 測試：等 delay 秒後，再等大樓穩定（樓層數與總高度連續 4 次、每 0.5 秒一樣）才動手；最多再等 15 秒。
    /// 10-25：鏡頭在樓層還沒讀完時就定位，大約一半的截圖構圖跑掉（隊長 Penny：讓三張一致變成必然，不是機率）
    private func afterTowerSettles(_ delay: Double, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            var last = "", same = 0
            for tries in 0...30 {
                let sig = "\(builder.tower.floors.count)|\(builder.tower.totalHeight)|\(BoardModel.shared.loaded)"
                same = sig == last ? same + 1 : 0; last = sig
                if same >= 3 { break }
                if tries == 30 { print("office probe：等 15 秒大樓還在變，照樣量"); fflush(stdout) }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            body()
        }
    }

    override func scrollWheel(with e: NSEvent) {
        defer { checkUnderground() }
        userMoved = true
        guard let pov = pointOfView else { return }
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
        guard dy != 0 else { return }
        let t = defaultCameraController.target, p = pov.position
        let v = SCNVector3(p.x - t.x, p.y - t.y, p.z - t.z)
        let dist = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        guard dist > 0.001 else { return }
        let next = min(max(dist * exp(-dy), 2), 260)       // 往上滾（dy>0）拉近
        let k = next / dist
        pov.position = SCNVector3(t.x + v.x * k, t.y + v.y * k, t.z + v.z * k)
        // 微縮模型（正交鏡頭）沒有近大遠小：只移鏡頭畫面不會變，要跟著改畫面大小（10-22 Kang：滾輪放大縮小失靈）
        if let c = pov.camera, c.usesOrthographicProjection { c.orthographicScale = OfficeStyleFX.orthoScale(dist: Double(next)) }
        camMoved(0.3)        // 停住時改鏡頭不一定會自己重畫（10-20 審查）：補播一下，到點就停
    }
    override func magnify(with e: NSEvent) { userMoved = true; camMoved(0.6); super.magnify(with: e) }

    /// 按住滾輪拖曳＝平移（10-20 Kang）：鏡頭和轉軸一起沿畫面的左右／上下移動，滑鼠底下的東西跟著手走
    override func otherMouseDown(with e: NSEvent) { if e.buttonNumber == 2 { window?.makeFirstResponder(self) } else { super.otherMouseDown(with: e) } }
    override func otherMouseDragged(with e: NSEvent) {
        guard e.buttonNumber == 2, let pov = pointOfView else { return super.otherMouseDragged(with: e) }
        userMoved = true
        pan(dx: e.deltaX, dy: e.deltaY, pov: pov)
        checkUnderground()
        camMoved(0.3)
    }
    func pan(dx: CGFloat, dy: CGFloat, pov: SCNNode) {
        let t = defaultCameraController.target, p = pov.position
        let dist = sqrt(pow(p.x - t.x, 2) + pow(p.y - t.y, 2) + pow(p.z - t.z, 2))
        // 每一點像素對應的世界距離：依鏡頭到轉軸的距離和視角換算
        let fov = (pov.camera?.fieldOfView ?? 42) * .pi / 180
        var k = 2 * dist * tan(fov / 2) / max(1, bounds.height)
        if let c = pov.camera, c.usesOrthographicProjection { k = 2 * CGFloat(c.orthographicScale) / max(1, bounds.height) }   // 正交：畫面高＝2×orthographicScale
        let r = pov.worldRight, u = pov.worldUp
        let d = SCNVector3(-r.x * dx * k + u.x * dy * k, -r.y * dx * k + u.y * dy * k, -r.z * dx * k + u.z * dy * k)
        pov.position = p + d
        defaultCameraController.target = t + d
    }

    /// 截圖驗證用：SHOWORK_OFFICE_PROBE=1 ⇒ 把每個角色（含保全）投影到畫面上，用點擊同一條路（person(at:)）點點看，印出對不對。
    /// SHOWORK_OFFICE_MOVE=<專案>[@秒]：定在「這層剛升上來」第幾秒（預設 0.9）；SHOWORK_OFFICE_FOCUS=<卡片 id>|guard|roof|lobby|floor:<專案>
    private var probed = false
    private func probeOnce() {
        let env = ProcessInfo.processInfo.environment
        guard !probed, bounds.width > 10, env["SHOWORK_OFFICE_PROBE"] != nil || env["SHOWORK_OFFICE_FOCUS"] != nil || env["SHOWORK_OFFICE_MOVE"] != nil
                || env["SHOWORK_OFFICE_CAM"] != nil || env["SHOWORK_OFFICE_POOF"] != nil || env["SHOWORK_OFFICE_HOVER"] != nil else { return }
        probed = true
        // SHOWORK_OFFICE_PROBE_DELAY：幾秒後量（同時開好幾個測試視窗時，看板讀得比較慢）
        let delay = Double(env["SHOWORK_OFFICE_PROBE_DELAY"] ?? "") ?? 2
        afterTowerSettles(delay) { [self] in
            if probing {
                var ok = 0, miss = 0
                for (id, n) in builder.peopleNodes().sorted(by: { $0.0 < $1.0 }) {
                    let p = projectPoint(center(n))
                    let inView = p.x >= 0 && p.y >= 0 && p.x <= bounds.width && p.y <= bounds.height && p.z < 1
                    let got = person(at: NSPoint(x: p.x, y: p.y))
                    if got == id { ok += 1 } else { miss += 1 }
                    print("probe", id, got == id ? "OK" : "MISS(\(got ?? "nil"))\(inView ? "" : " 畫面外")")
                }
                print("probe total OK=\(ok) MISS=\(miss)")
                print("office stats", builder.stats())
                print("office tower", builder.towerLayout())
                printFloorPixels("default")
                print("office labels", labels.stats)
                // 點標籤＝點角色：每個標籤中心點點看
                var lok = 0, lmiss = 0
                for (id, _) in builder.peopleNodes() {
                    guard let r = labels.rect(id) else { continue }
                    let got = labels.label(at: CGPoint(x: r.midX, y: r.midY))
                    if got == id { lok += 1 } else { lmiss += 1; print("probe label MISS", id, got ?? "nil") }
                }
                print("probe labels OK=\(lok) MISS=\(lmiss)")
                // 滾輪：合成事件直接送進這個 view（不動真的滑鼠），看鏡頭到轉軸的距離
                @MainActor func dist() -> CGFloat {
                    let t = defaultCameraController.target, p = pointOfView?.position ?? t
                    return sqrt(pow(p.x - t.x, 2) + pow(p.y - t.y, 2) + pow(p.z - t.z, 2))
                }
                let d0 = dist()
                for dy: Int32 in [3, -6] {
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0),
                       let ev = NSEvent(cgEvent: cg) { scrollWheel(with: ev) }
                    print("probe scroll", dy, String(format: "%.2f → %.2f", d0, dist()))
                }
                // 按住滾輪平移：直接呼叫同一個 pan（合成中鍵拖曳事件會動到真滑鼠，不用）；畫面往右拖 100pt，轉軸應往鏡頭左邊走
                if let pov = pointOfView {
                    let ta = defaultCameraController.target, pa = pov.position
                    pan(dx: 100, dy: 0, pov: pov)
                    let tb = defaultCameraController.target, pb = pov.position
                    let moved = sqrt(pow(tb.x - ta.x, 2) + pow(tb.y - ta.y, 2) + pow(tb.z - ta.z, 2))
                    let same = abs((pb.x - pa.x) - (tb.x - ta.x)) + abs((pb.y - pa.y) - (tb.y - ta.y)) + abs((pb.z - pa.z) - (tb.z - ta.z))
                    let left = (tb.x - ta.x) * pov.worldRight.x + (tb.y - ta.y) * pov.worldRight.y + (tb.z - ta.z) * pov.worldRight.z
                    print("probe pan", String(format: "移動 %.2f、鏡頭與轉軸位移差 %.4f、往右分量 %.2f", moved, same, left))
                    pan(dx: -100, dy: 0, pov: pov)
                }
                // WASD：合成按鍵直接送進這個 view（不動真的鍵盤），看轉軸有沒有跟著走
                let t0 = defaultCameraController.target
                if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                             context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13) { keyDown(with: ev) }
                let t1 = defaultCameraController.target
                print("probe key w", String(format: "target z %.2f → %.2f", t0.z, t1.z))
                // 捲完還原（不然後面測「新的等你回答 ⇒ 鏡頭飛過去」會被當成你動過視角）
                userMoved = false; framed = false; frameIfNeeded()
                print("office stats after reframe", builder.stats())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.printFloorPixels("after reframe"); print("office labels after", self.labels.stats); fflush(stdout) }
            }
            if let mv = env["SHOWORK_OFFICE_MOVE"] {
                let parts = mv.split(separator: "@").map(String.init)
                let ok = builder.debugPoseMove(parts[0], t: parts.count > 1 ? Double(parts[1]) ?? 0.9 : 0.9)
                print("office move pose", mv, ok ? "OK" : "沒有這層"); fflush(stdout)
            }
            // SHOWORK_OFFICE_POOF=<秒>[,in]：忍術過場定格在第幾秒（離開；加 ,in＝出現），鏡頭飛到那個人旁邊（FOCUS_DIST，預設 10）
            if let pf = env["SHOWORK_OFFICE_POOF"] {
                let parts = pf.split(separator: ",")
                let t = Double(parts.first ?? "") ?? 0.15
                let before = builder.nodeCount
                if let (id, p) = builder.debugPoof(t: t, appear: parts.count > 1 && parts[1] == "in") {
                    fly(toPoint: p, distance: CGFloat(Double(env["SHOWORK_OFFICE_FOCUS_DIST"] ?? "") ?? 10))
                    userMoved = true
                    print("office poof", id, "t=\(t)", "nodes \(before)→\(builder.nodeCount)")
                } else { print("office poof 找不到坐在座位上的人") }
                fflush(stdout)
            }
            // SHOWORK_OFFICE_FOCUS：再飛到那個角色／樓層旁邊（截近照看造型）
            if let f = env["SHOWORK_OFFICE_FOCUS"] {
                let d = CGFloat(Double(env["SHOWORK_OFFICE_FOCUS_DIST"] ?? "") ?? 7)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let p = self.builder.focusPoint(f) { self.fly(toPoint: p, distance: d) }
                    else if let n = self.builder.personNode(f) { self.fly(to: n, distance: d) }
                    else { print("office focus 找不到", f) }
                    self.userMoved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.updateLOD(); print("office stats focus", self.builder.stats()); fflush(stdout) }
                }
            }
            // SHOWORK_OFFICE_HOVER=<城市 id>[,label]（10-21 第二輪）：模擬滑鼠停在那棟建築上（預設建築本體的投影點；加 ,label＝停在名牌上），
            // 走 mouseMoved 同一條 hover(at:)，不動真的滑鼠。SHOWORK_OFFICE_HOVER_DELAY 秒後做（預設 1.5，等鏡頭定位、名牌畫好）
            if let hv = env["SHOWORK_OFFICE_HOVER"] {
                let parts = hv.split(separator: ",").map(String.init)
                let id = parts[0], onLabel = parts.count > 1 && parts[1] == "label"
                DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["SHOWORK_OFFICE_HOVER_DELAY"] ?? "") ?? 1.5)) { [self] in
                    var pt: NSPoint?
                    if onLabel, let r = labels.rect(id) { pt = NSPoint(x: r.midX, y: r.midY) }      // 名牌框跟 label(at:) 同一個座標系（這個 view 的）
                    if pt == nil, let c = builder.city.hitCenter(id) {
                        let q = projectPoint(c); pt = NSPoint(x: q.x, y: q.y)
                    }
                    guard let p = pt else { print("office hover 找不到", id); fflush(stdout); return }
                    lastHoverPick = .distantPast
                    hover(at: p)
                    print("office hover", id, onLabel ? "名牌" : "建築", "at", Int(p.x), Int(p.y), "→", hoverId ?? "nil", hoverId == id ? "OK" : "MISS"); fflush(stdout)
                }
            }
            // SHOWORK_OFFICE_CAM=方位,仰角,距離[,tx,ty,tz]（度、公尺）：鏡頭定在指定位置（10-21 稽核：系統化掃描每個角度）
            if let c = env["SHOWORK_OFFICE_CAM"] {
                let v = c.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if v.count >= 3 {
                    let t = v.count >= 6 ? SIMD3(v[3], v[4], v[5]) : SIMD3(0, self.builder.tower.totalHeight / 2, 0)
                    self.builder.placeTest(self, target: t, dist: v[2], az: v[0], el: v[1])
                    self.userMoved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.updateLOD(); print("office cam", c, self.builder.stats()); fflush(stdout) }
                }
            }
            fflush(stdout)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// 先問螢幕空間標籤（標籤在 3D 之上），沒點到再問 3D
    func pick(_ p: NSPoint) -> String? { labels.label(at: p) ?? person(at: p) }

    /// 點到哪個角色（節點名 "p:<卡片 id>"，或保全 "guard"，往上找）。
    /// 只找角色與保全（categoryBitMask），不在整層樓的大 mesh 上算三角形；先認看得到的東西，都沒有才認透明點擊盒
    func person(at p: NSPoint) -> String? {
        let hits = hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: false,
                                        .categoryBitMask: OfficeBuilder.pickMask])
        func owner(_ node: SCNNode) -> String? {
            var n: SCNNode? = node
            while let x = n {
                if let s = x.name {
                    if s.hasPrefix("p:") { return String(s.dropFirst(2)) }
                    if s.hasPrefix("city:") { return s }
                    if s == "guard" { return "guard" }
                    if s == "b1-board" { return builder.underground ? s : nil }      // 地上時 B1 藏著，點不到
                }
                n = x.parent
            }
            return nil
        }
        for h in hits where h.node.name != "hitbox" { if let id = owner(h.node) { return id } }
        for h in hits where h.node.name == "hitbox" { if let id = owner(h.node) { return id } }
        return nil
    }

    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow; window?.makeFirstResponder(self); super.mouseDown(with: e) }
    override func mouseUp(with e: NSEvent) {
        super.mouseUp(with: e)
        camMoved(1.0)
        // 拖曳是轉視角，不算點
        if let d = downAt, hypot(d.x - e.locationInWindow.x, d.y - e.locationInWindow.y) < 4 {
            let p = convert(e.locationInWindow, from: nil)
            if let id = pick(p) { onClick?(id) }
            else if let proj = neuralProject(at: p) {
                // 10-22 Kang：點地下室中間那團神經網路 ⇒ 開那個專案的 Graphify 互動圖譜（OfficeView.click 處理 "neural:" 開頭）
                builder.basement.flash(); playFor(0.8)
                onClick?("neural:" + proj)
            }
        }
        downAt = nil
    }

    /// 鏡頭在地下室時，這一點有沒有點到中間那團神經網路（點到 ⇒ 最近的節點屬於哪個專案）。地上一律 nil（不影響點人物、點樓層）
    func neuralProject(at p: NSPoint) -> String? {
        guard builder.underground else { return nil }
        let a = unprojectPoint(SCNVector3(p.x, p.y, 0)), b = unprojectPoint(SCNVector3(p.x, p.y, 1))
        return builder.basement.pickProject(from: a, to: b)
    }
    /// 懸停偵測（10-21 第二輪：節流）：只在滑鼠移動時做，最多每 50 ms 一次 hitTest；中間丟掉的那一下由最後一次補做（一次性 asyncAfter，不是 timer）
    private var lastHoverPick = Date.distantPast
    private var hoverTrailing: NSPoint?
    private var hoverTrailingPending = false
    static let hoverThrottle: TimeInterval = 0.05
    override func mouseMoved(with e: NSEvent) { hover(at: convert(e.locationInWindow, from: nil)) }
    func hover(at p: NSPoint) {
        let now = Date()
        guard now.timeIntervalSince(lastHoverPick) >= Self.hoverThrottle else {
            hoverTrailing = p
            if !hoverTrailingPending {
                hoverTrailingPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverThrottle) { [weak self] in
                    guard let self else { return }
                    self.hoverTrailingPending = false
                    if let q = self.hoverTrailing { self.hoverTrailing = nil; self.hover(at: q) }
                }
            }
            return
        }
        lastHoverPick = now
        hoverTrailing = nil
        let id = pick(p)
        if id != hoverId {
            hoverId = id; builder.highlight(id)
            // 位置換成「3D 區域左上角為原點」（SwiftUI 的座標）
            if id != nil { onHoverPoint?(CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)) }
            onHover?(id)
        }
    }
    override func mouseExited(with e: NSEvent) { hoverTrailing = nil; hoverId = nil; builder.highlight(nil); onHover?(nil) }
    override func menu(for e: NSEvent) -> NSMenu? {
        pick(convert(e.locationInWindow, from: nil)).flatMap { menuFor?($0) }
    }

    // WASD／方向鍵：在地面上走（鏡頭跟轉軸一起平移）；Q／E 升降
    override func keyDown(with e: NSEvent) {
        guard let pov = pointOfView else { return super.keyDown(with: e) }
        userMoved = true
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 2.4 : 1.0
        var f = pov.worldFront; f.y = 0
        let fl = max(0.001, hypot(f.x, f.z)); f.x /= fl; f.z /= fl
        let r = SCNVector3(-f.z, 0, f.x)
        var d = SCNVector3Zero
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "w": d = SCNVector3(f.x * step, 0, f.z * step)
        case "s": d = SCNVector3(-f.x * step, 0, -f.z * step)
        case "a": d = SCNVector3(-r.x * step, 0, -r.z * step)
        case "d": d = SCNVector3(r.x * step, 0, r.z * step)
        case "q": d = SCNVector3(0, -step, 0)
        case "e": d = SCNVector3(0, step, 0)
        default:
            switch Int(e.keyCode) {
            case 126: d = SCNVector3(f.x * step, 0, f.z * step)
            case 125: d = SCNVector3(-f.x * step, 0, -f.z * step)
            case 123: d = SCNVector3(-r.x * step, 0, -r.z * step)
            case 124: d = SCNVector3(r.x * step, 0, r.z * step)
            default: return super.keyDown(with: e)
            }
        }
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.12
        pov.position = pov.position + d
        SCNTransaction.commit()
        camMoved(0.25)
        defaultCameraController.target = defaultCameraController.target + d
    }
}

/// 天氣列（10-23；10-25 改成每個人自己選地點，預設只有台北）：清單的地點並排，主天氣（畫面跟它）有兩個以上時加粗，
/// 各附最近一次成功更新的時間；沒抓到過顯示「—」。點一下開地點面板（搜尋、加入、移除、換主天氣）。
struct WeatherStrip: View {
    @ObservedObject var weather: OfficeWeather
    @State private var open = false
    /// 測試視窗：SHOWORK_OFFICE_WEATHER_PANEL=1 把地點面板直接疊在天氣列下面（popover 是另一個視窗，自存截圖拍不到）
    private let testPanel = BoardWindow.testMode && OfficeView.testEnv("SHOWORK_OFFICE_WEATHER_PANEL") != nil

    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        if weather.enabled {
            Button { open.toggle() } label: {
                HStack(spacing: 10) {
                    ForEach(weather.sites, id: \.self) { site in
                        let r = weather.report(site)
                        let bad = r == nil && weather.failed.contains(site)
                        HStack(spacing: 4) {
                            Image(systemName: r.map { OfficeWeather.symbol($0.now.kind) } ?? (bad ? "cloud.slash" : "hourglass"))
                            Text(site.title).fontWeight(site == weather.main && weather.sites.count > 1 ? .semibold : .regular)
                            Text(r?.now.kind.title ?? (bad ? "—" : "讀取中"))
                            if let r { Text(Self.clock.string(from: r.at)).foregroundStyle(.tertiary).monospacedDigit() }
                        }
                        .help(r.map { "\($0.now.summary(site))\n\(Self.clock.string(from: $0.at)) 更新（Open-Meteo 每 10 分鐘）" + (site == weather.main ? "\n3D 辦公室的雲、雨、颱風跟著這裡" : "") + "\n點一下換地點" }
                              ?? (bad ? "\(site.title)：抓不到天氣（離線或服務沒回應），10 分鐘後再試" : "\(site.title)：讀取中"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout).foregroundStyle(.secondary).fixedSize()
            .accessibilityLabel("天氣地點")
            .popover(isPresented: $open, arrowEdge: .bottom) { WeatherPlaces(weather: weather) }
            .overlay(alignment: .topLeading) {
                if testPanel {
                    WeatherPlaces(weather: weather).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .fixedSize().offset(y: 28)
                }
            }
        }
    }
}

/// 地點面板：目前的清單（第一個是主天氣，星號換主天氣、減號移除、至少留一個）＋搜尋任何城市加入（最多 WeatherSite.limit 個）
struct WeatherPlaces: View {
    @ObservedObject var weather: OfficeWeather
    @State private var query = OfficeView.testEnv("SHOWORK_OFFICE_WEATHER_QUERY") ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("天氣地點").font(.headline)
            VStack(spacing: 4) {
                ForEach(weather.sites, id: \.self) { site in
                    let main = site == weather.main
                    HStack(spacing: 8) {
                        Button { weather.sites = WeatherSite.makingMain(site, in: weather.sites) } label: {
                            Image(systemName: main ? "star.fill" : "star").foregroundStyle(main ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain).help(main ? "主天氣：3D 辦公室的雲、雨、颱風跟著這裡" : "設成主天氣").accessibilityLabel(main ? "主天氣" : "設成主天氣")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(site.title)
                            if let d = site.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { weather.sites = WeatherSite.removing(site, from: weather.sites) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(weather.sites.count <= 1)
                            .help(weather.sites.count <= 1 ? "至少要留一個地點" : "移除").accessibilityLabel("移除 \(site.title)")
                    }
                }
            }
            Divider()
            if weather.sites.count >= WeatherSite.limit {
                Text("最多 \(WeatherSite.limit) 個地點，先移除一個才能再加").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("搜尋城市或地區（例如 高雄、東京）", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, q in weather.search(q) }
                    .onAppear { if !query.isEmpty { weather.search(query) } }
                if let n = weather.searchNote { Text(n).font(.caption).foregroundStyle(.secondary) }
                ForEach(weather.results, id: \.self) { r in
                    let have = weather.sites.contains { $0.same(r) }
                    Button { weather.sites = WeatherSite.adding(r, to: weather.sites); query = "" } label: {
                        HStack {
                            Text(r.fullName).lineLimit(1)
                            Spacer()
                            Image(systemName: have ? "checkmark" : "plus.circle")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(have)
                }
            }
            Text("每台電腦各自記住；最多 \(WeatherSite.limit) 個，星號那個是主天氣").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14).frame(width: 300)
    }
}
