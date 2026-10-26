import AppKit
import SceneKit
import simd
import ShoWorkCore

// 3D 辦公室第四版的場景：科技大樓剖面（10-20 Kang 拍板，規範 docs/design/office-tower/設計規範.md）。
//   樓層由下往上疊：一樓大廳＋前台保全 → 閒置薄層（只放門牌）→ 有 AI 的專案樓層（固定樓層號）→ 頂樓空中花園。資料來自 BoardModel.tower。
//   一層一個模組（OfficeTower.swift）：靜態東西合併成一個 mesh、四面牆各一個節點（面向鏡頭的那面淡掉＝cutaway）、門牌可以換牆。
//   樓層換位置（TowerPlan 變了）：整層像模組一樣往前飄出→升降→插回、其他樓層讓位，約 2 秒，播完停止渲染。
//   角色閒晃照 BoardModel.wander（WanderPlanner）：桌↔電梯↔頂樓↔別人樓層，≤10 fps，視窗被蓋住就直接落地。
//   燈光（office.lighting）：白天／夜晚／自動（10-21 起跟台北真實日出日落連續混合，規範 §3.8.1）；切換只改燈光與材質強度、不重建。
// 原本的棋盤分區／中庭環狀格局（office.layout）10-20 拿掉（設定鍵留著相容，不再讀）。
// 省電：沒人在走、沒在搬家、沒人打字時不渲染；樓層內容（主題、桌數、有沒有人）變了才重建那一層。

@MainActor
final class OfficeBuilder {
    static let dayBg = VoxMat.color(TP.skyDay), nightBg = VoxMat.color(TP.skyNight)
    /// 目前的天空地平線色（SCNView.backgroundColor 用；日出日落時跟著天色走）
    private(set) static var bg: NSColor = dayBg
    let scene = SCNScene()
    let camera = SCNNode()
    private let world = SCNNode()
    private let env: SCNNode
    private var core = SCNNode(), coreFacades: [Facade] = [], coreSig = ""
    /// 兩部電梯車廂（10-22 Kang：兩部電梯、搭電梯不要破圖）：第 c 部在 TD.elevs[c]
    private let cars: [SCNNode]
    /// 每部車廂排好的上下段落（同一部接連載好幾趟時整份一起播）＋最後停在哪層（沒人搭時停在那，不跳回大廳）
    private var carLegs: [[TripPath.CarLeg]]
    private var carRest: [String]
    private let driver = SCNNode()          // 搬家動畫掛在這個節點上跑
    private let ambient = SCNNode(), sun = SCNNode(), fill = SCNNode(), moonFill = SCNNode()
    /// 戶外的東西（城市、大地面）：categoryBitMask 拿掉第 0 位元 ⇒ 室內暖補光照不到（主光、環境光照得到）
    static let outdoorMask = 1 << 4
    private var omni: [SCNNode] = []
    /// 夜晚室內暖補光強度（白天 fill 340；測試 SHOWORK_OFFICE_NIGHTFILL 調）：每層有自己的燈之後只留一點，讓背光面不全黑
    static let nightFill: Double = env("SHOWORK_OFFICE_NIGHTFILL") ?? 60
    /// 專案樓層每層一盞室內燈的強度（頂樓 700；10-25 Kang：自發光版太亮、牆地同色、外牆也亮 ⇒ 改真光源）
    static let floorOmni: Double = env("SHOWORK_OFFICE_OMNI") ?? 500      // 10-25 Kang 選 500
    /// 大廳那盞（10-25 Kang：700 → 900）；頂樓照舊 700
    static let lobbyOmni: Double = env("SHOWORK_OFFICE_LOBBY") ?? 900
    /// 每層室內燈的衰減終點（公尺）：有光照位元分層，拉長也不會照到上下層
    static let floorRange: CGFloat = env("SHOWORK_OFFICE_RANGE").map { CGFloat($0) } ?? 11
    /// 每層室內燈的光照位元（隊長 Penny：SceneKit 每個 geometry 最多吃 8 盞燈，多的靜默丟掉）：第 i 個專案樓層用 bit 8+(i%16)，
    /// 那層的幾何（玻璃除外）加這個位元、那層的燈只照這個位元 ⇒ 每個 geometry 只吃自己那盞＋太陽／補光，永遠不超過上限。
    /// 相隔 16 層才會共用同一個位元（48 公尺，遠超過燈的衰減距離）
    /// 測試：SHOWORK_OFFICE_LEGACY_NIGHT=1 ＝ 10-25 以前的夜晚燈光（量測對照用）
    static let legacyNight = env("SHOWORK_OFFICE_LEGACY_NIGHT") != nil
    static func floorLightBit(_ i: Int) -> Int { 1 << (8 + i % 16) }
    static let floorLightBits: Int = (0..<16).reduce(0) { $0 | floorLightBit($1) }
    private static func env(_ k: String) -> Double? { BoardWindow.testMode ? ProcessInfo.processInfo.environment[k].flatMap(Double.init) : nil }
    private var omniBase: Double = 700
    /// 外部空間城市（10-21，OfficeCity.swift）
    let city = CityBuilder()
    /// 雨與閃電（10-21 台北真實天氣，OfficeRain.swift）
    let weatherFX = WeatherFX()
    /// 地下室 B1 機房＋浮空神經網路（10-22，OfficeBasement.swift）：鏡頭平移到地下（世界 y < 0）才出現
    let basement = OfficeBasement()
    /// 鏡頭在地下室（大地面、城市淡出；B1 出現、圖譜自轉）
    private(set) var underground = false

    struct Module { var parts: ModuleParts; var key: String; var floor: TowerFloor }
    private var modules: [String: Module] = [:]
    private(set) var tower = TowerPlan()
    private var decor: [String: FloorDecor] = [:]

    /// 一個角色：外觀（造型＋坐站）與位置分開記；只有位置變就搬節點，不重建
    struct Person { var node: SCNNode; var look: String; var place: String; var mood: Mood
        var islander: Islander; var floor: String; var seat: Int; var seats: Int }
    private var persons: [String: Person] = [:]
    private var tripsDone = Set<String>()   // 播完的行程（等下次刷新清掉前不要重播）
    private var ghosts: [String: (node: SCNNode, key: String)] = [:]
    private var boards: [String: (node: SCNNode, key: String)] = [:]
    private var guardNode: SCNNode?
    private var guardKey = ""
    private var lit: String?
    private var lastWander = WanderPlan()

    /// 場景裡有沒有一直在跑的動畫（「改檔」打字、保全掃描中轉天線）；有才持續渲染
    private(set) var looping = false
    /// 搬家／閒晃播到什麼時候（OfficeSCNView 依這兩個決定幀率：搬家 24、閒晃 10）
    private(set) var moveUntil = Date.distantPast
    private(set) var walkUntil = Date.distantPast
    private var moving: MoveAnim?
    private var leaving: [SCNNode] = []
    /// 這次更新新加、會自己停的動畫最長要播幾秒（跳三下、搖一下、搬家、閒晃）
    private var transient: TimeInterval = 0
    func takeTransient() -> TimeInterval { defer { transient = 0 }; return transient }
    private func bump(_ s: TimeInterval) { transient = max(transient, s) }

    static let maxPeople = 16
    static let kuboScale = CGFloat(TowerSpec.kuboScale)   // 10-20 UI/UX 優化：1.3 → 1.6（坐姿頭頂佔層高 53%，ACCAI 那種比例）
    /// 樓層看板只在鏡頭夠近時顯示（鏡頭停下來才算一次）
    static let boardDistance: CGFloat = 30
    /// 點擊只找角色與保全（categoryBitMask 第 2 位元），不在整層樓的大 mesh 上算三角形
    static let pickMask = 2
    /// cutaway：牆的外法線跟鏡頭方向的內積超過這個就淡掉（斜 45° 時兩面都淡）
    static let cutDot: Float = 0.25
    /// 牆淡出的秒數（--office-bench 設 0：SCNRenderer 自己給時間，隱式動畫不會走完）
    static var cutFade: TimeInterval = 0.25

    // 測試：SHOWORK_OFFICE_TRIP_T=<秒>（測試視窗）把路上的人定在行程第幾秒（螢幕外視窗不推進動畫）
    /// 測試：SHOWORK_OFFICE_DOOR=0|0.5|1 所有電梯門定格開幾成（截圖驗關、半開、全開）
    static let testDoor: Float? = BoardWindow.testMode ? ProcessInfo.processInfo.environment["SHOWORK_OFFICE_DOOR"].flatMap(Float.init) : nil
    private let testTripT: Double? = BoardWindow.testMode ? ProcessInfo.processInfo.environment["SHOWORK_OFFICE_TRIP_T"].flatMap(Double.init) : nil

    init() {
        scene.rootNode.addChildNode(world)
        env = TowerCore.environment()
        env.categoryBitMask = Self.outdoorMask
        world.addChildNode(env)
        cars = TD.elevs.map { e in
            let c = TowerCore.car(); c.simdPosition = SIMD3(e.x, TD.room, e.y); return c
        }
        carLegs = cars.map { _ in [] }
        carRest = cars.map { _ in "lobby" }
        for c in cars { world.addChildNode(c) }
        for c in TD.elevs.indices {      // B1 的電梯門（吃 B1 自己的冷光）
            let d = TowerCore.landingDoor(c); TowerCore.setDoor(d, open: Self.testDoor ?? 0)
            d.enumerateHierarchy { n, _ in if n.geometry != nil { n.categoryBitMask = (n.categoryBitMask & ~1) | OfficeBasement.mask } }
            basement.root.addChildNode(d)
        }
        world.addChildNode(driver)
        world.addChildNode(city.root)
        world.addChildNode(basement.root)
        ambient.light = SCNLight(); ambient.light!.type = .ambient
        scene.rootNode.addChildNode(ambient)
        sun.light = SCNLight(); sun.light!.type = .directional
        sun.eulerAngles = Self.sunEuler
        sun.light!.categoryBitMask = ~OfficeBasement.mask     // 太陽照不進地下室（B1 只吃自己的冷光）
        scene.rootNode.addChildNode(sun)
        // 室內暖補光（10-21 主光改版）：環境光改冷之後，白天室內的米色後牆變灰、整層暗一階 ⇒ 只照大樓（第 0 位元）的弱暖色環境光，
        // 讓剖面室內維持暖、室外冷（娃娃屋剖面「剖開處自然是焦點」）；夜晚室內有 omni，關掉
        // 10-21 實測：ambient 不吃 categoryBitMask（照樣照到全場），directional 才吃 ⇒ 兩盞補光都用 directional
        fill.light = SCNLight(); fill.light!.type = .directional; fill.light!.categoryBitMask = 1
        fill.eulerAngles = SCNVector3(-0.45, 0.2, 0)          // 從鏡頭這側稍高處往裡照（剖面的正面、地板受光）
        fill.light!.color = VoxMat.color(0xFFE2BE)
        scene.rootNode.addChildNode(fill)
        // 夜晚戶外月光補光（只照城市、大地面；從右前上方，跟主光對側 ⇒ 背光面也看得出來）：大樓室內照不到 ⇒ 城市量體看得出來（頂面 L25–35），大樓暖光仍是全畫面最亮
        moonFill.light = SCNLight(); moonFill.light!.type = .directional; moonFill.eulerAngles = SCNVector3(-0.85, 0.55, 0); moonFill.light!.categoryBitMask = Self.outdoorMask
        moonFill.light!.color = VoxMat.color(0x8E9CC4)
        scene.rootNode.addChildNode(moonFill)
        // 夜晚 omni：大廳、頂樓各 1＋每個專案樓層 1（10-25 起，數量跟著樓層數，assignOmni 不夠才補）
        let cam = SCNCamera()
        cam.fieldOfView = 34; cam.projectionDirection = .vertical   // 10-20 UI/UX 優化：42 → 34（鏡頭退遠一點，上下樓層大小比較平均）; cam.zNear = 0.1; cam.zFar = 600
        // 10-21：上一行的 zNear／zFar 被寫進註解裡，實際是預設 zFar 100 ⇒ 俯瞰城市（鏡頭距離 100 以上）後半截被切掉；滾輪拉遠到 260 時大樓也會被切
        cam.zNear = 1; cam.zFar = 500       // zNear 維持原本實際生效的 1（深度精度）
        cam.wantsHDR = true; cam.wantsExposureAdaptation = false
        cam.bloomThreshold = 0.8; cam.bloomBlurRadius = 8
        camera.camera = cam
        scene.rootNode.addChildNode(camera)
        weatherFX.attach(camera: camera, scene: scene)
        applyLights()
    }

    // MARK: 燈光（規範 §3.8）

    /// 白天／夜晚固定（bench、舊呼叫）＝改版前的兩組燈光
    func setNight(_ n: Bool) -> Bool { setLook(n ? .night : .day) }

    /// 微縮模型（10-22 Kang「跟體素太像」）：拿掉 1600 m 大地面，整座城放在一塊有木頭邊的底座上；底座外面由後製畫成桌面
    private lazy var plinth: SCNNode = {
        let m = VoxelMesh(), k = Kit(m: m)
        let x0: Float = -33, x1: Float = 45, z0: Float = -15, z1: Float = 22   // 含港口水面（x 到 44、z 到 21.2）
        k.b(.identity, (x0 + x1) / 2, -0.4, (z0 + z1) / 2, x1 - x0, 0.4, z1 - z0, VoxMat.dayNight(TP.groundDay, TP.groundNight))
        k.b(.identity, (x0 + x1) / 2, -1.8, (z0 + z1) / 2, x1 - x0 + 0.6, 1.4, z1 - z0 + 0.6, VoxMat.dayNight(0x9A6A40, 0x4A3220))
        let n = m.node(name: "plinth"); n.categoryBitMask = Self.outdoorMask
        return n
    }()
    func setStyle(_ s: OfficeStyle) {
        let dio = s == .diorama
        env.isHidden = dio
        if dio { if plinth.parent == nil { world.addChildNode(plinth) } } else { plinth.removeFromParentNode() }
    }

    /// 目前套用的天色（nil＝還沒套過）
    private(set) var look: SkyLook?
    private var lastApply = Date.distantPast
    /// 日出日落（10-21，規範 §3.8.1）：天色依太陽仰角連續混合。只改燈光參數、背景、共用材質的顏色／發光強度，不重建節點。
    /// 跟上次差很少（仰角 < 0.2°、方位角 < 0.5°）就不動（回 false ⇒ 不重畫）
    @discardableResult
    func setLook(_ l: SkyLook) -> Bool {
        if let o = look, Self.close(o, l), lastApply != .distantPast { return false }
        // 晨昏時天色一直在變：同一段過渡裡最多 55 秒套一次（畫面 body 常因卡片更新重算，不要每次都重畫）；切換白天／夜晚／自動立刻套
        if let o = look, Date().timeIntervalSince(lastApply) < 55, (o.sunDir == nil) == (l.sunDir == nil), o != .day, o != .night, l != .day, l != .night,
           abs(o.dark - l.dark) < 0.05, abs(o.lamps - l.lamps) < 0.05 { return false }
        look = l; lastApply = Date()
        applyLights()
        if BoardWindow.testMode { print("sky apply dark=\(String(format: "%.3f", l.dark)) lamps=\(String(format: "%.3f", l.lamps)) el=\(l.sunDir.map { String(format: "%.2f", $0.elevation) } ?? "-")"); fflush(stdout) }
        return true
    }
    /// 天氣（10-21，規範 §3.8.2）：雨／閃電交給 WeatherFX；天色的變化已經疊在 setLook 收到的 SkyLook 裡（SkyLook.weathered）。
    /// 換天氣要在 setLook 之前呼叫：有變就讓接下來那次 setLook 不被 55 秒節流擋掉
    @discardableResult
    func setWeather(_ w: WeatherLook) -> Bool {
        guard weatherFX.set(w) else { return false }
        lastApply = .distantPast
        return true
    }

    static func close(_ a: SkyLook, _ b: SkyLook) -> Bool {
        if a == b { return true }
        guard (a.sunDir == nil) == (b.sunDir == nil) else { return false }
        if let p = a.sunDir, let q = b.sunDir, abs(p.elevation - q.elevation) >= 0.2 || abs(p.azimuth - q.azimuth) >= 0.5 { return false }
        return abs(a.dark - b.dark) < 0.004 && abs(a.lamps - b.lamps) < 0.004 && abs(a.keyIntensity - b.keyIntensity) < 3
            && abs(a.ambientIntensity - b.ambientIntensity) < 3 && simd_reduce_max(abs(a.horizon - b.horizon)) < 0.004
            && simd_reduce_max(abs(a.keyColor - b.keyColor)) < 0.004 && abs(a.overcast - b.overcast) < 0.01
    }

    /// 主光（10-21 主光改版，研究 R2-2-1）：從左前上方打（光行進方向 ≈ (0.465, −0.800, −0.380)），影子落在右後方、鏡頭看得到；
    /// 頂面最亮、迎光的正面中間、右側面最暗（原本光從正前方來，正面比頂面還亮，房子像紙板）
    static let sunEuler = SCNVector3(-0.927, -0.885, 0)
    /// 靜態假影子的方向：每 1 公尺高往水平方向位移多少（x, z）。直接用主光的方向算，不寫死
    static let shadowStep: SIMD2<Float> = {
        let n = SCNNode(); n.eulerAngles = sunEuler
        let f = n.simdWorldFront
        return SIMD2(f.x / -f.y, f.z / -f.y)
    }()

    /// 真實太陽 → 世界座標：鏡頭在大樓南邊往北看（+z＝南、+x＝東），再轉 25.7°，讓美術主光（sunEuler，水平 230.7°）
    /// 對到 10 月台北 12:30 左右的太陽（方位 ≈ 205°）⇒ 中午的畫面跟改版前的白天幾乎一樣
    static let compassOffset = 25.7
    static func worldAngle(azimuth: Double) -> Double { (azimuth + compassOffset) * .pi / 180 }
    /// 美術主光的水平方向（同一套 (sin, −cos) 角度，≈ 230.7°）
    static let artAngle: Double = {
        let n = SCNNode(); n.eulerAngles = sunEuler
        let toSun = -n.simdWorldFront
        var a = atan2(Double(toSun.x), Double(-toSun.z)); if a < 0 { a += 2 * .pi }; return a
    }()

    private static func ns(_ c: SIMD3<Double>) -> NSColor { NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1) }

    private func applyLights() {
        let l = look ?? .day
        let fixedDay = l == .day, fixedNight = l == .night
        VoxMat.setBlend(dark: l.dark, lamps: l.lamps)
        TowerSign.setDark(l.dark)
        // 漸層天空盒＋霧（霧色＝地平線色＝天空盒下半）；霧距跟鏡頭距離走（updateLOD 鏡頭停下時才算）
        if fixedDay || fixedNight {
            scene.background.contents = fixedNight ? TowerCore.skyNight : TowerCore.skyDay
            Self.bg = fixedNight ? Self.nightBg : Self.dayBg
        } else {
            let az = l.sunDir.map { Self.worldAngle(azimuth: $0.azimuth) } ?? Self.artAngle
            scene.background.contents = TowerCore.sky(horizon: SIMD3<Float>(l.horizon), zenith: SIMD3<Float>(l.zenith), glow: SIMD3<Float>(l.glow),
                                                      glowAmount: Float(l.glowAmount), sunAngle: Float(az))
            Self.bg = Self.ns(l.horizon)
        }
        scene.fogColor = Self.bg
        scene.fogDensityExponent = 1
        // 大地面底色
        VoxMat.dayNight(TP.groundDay, TP.groundNight).diffuse.contents = fixedDay ? VoxMat.color(TP.groundDay) : fixedNight ? VoxMat.color(TP.groundNight) : Self.ns(l.ground)
        // 冷暖分光：環境光冷、太陽暖（日）；夜晚月光藍＋冷環境光，暖光只留給大樓室內（焦點）
        ambient.light!.intensity = l.ambientIntensity
        ambient.light!.color = Self.ns(l.ambientColor)
        sun.light!.intensity = l.keyIntensity
        sun.light!.color = Self.ns(l.keyColor)
        // 主光方向：真實太陽（東升西落、仰角跟著變，最低 3°）；白天固定／夜晚月光＝美術角度
        if let d = l.sunDir {
            let el = d.elevation * .pi / 180, th = Self.worldAngle(azimuth: d.azimuth)
            let toSun = SIMD3<Float>(Float(cos(el) * sin(th)), Float(sin(el)), Float(-cos(el) * cos(th)))
            sun.simdOrientation = simd_quatf(from: SIMD3(0, 0, -1), to: -toSun)
        } else {
            sun.eulerAngles = Self.sunEuler
        }
        let ps = gridScale
        VoxMat.setPower(CGFloat(ps))
        // 10-25 Kang：夜晚只有離鏡頭最近的 4 層有 omni，整棟看起來像只有中間幾層開燈 ⇒ 每層一盞 omni（assignOmni），
        // 補光夜晚只開一點，讓背光面不全黑；一盞 directional、只照大樓（第 0 位元）
        let fillI = l.fill + (Self.legacyNight ? 0 : Self.nightFill) * l.lamps
        fill.light!.intensity = fillI * (0.4 + 0.6 * ps)
        fill.isHidden = fillI <= 0
        moonFill.light!.intensity = l.moonFill
        moonFill.isHidden = l.moonFill <= 0
        // 靜態假影子是照美術主光方向烤好的：太陽轉到別的方向、或太低，就淡掉（夜晚那組保持原樣）
        var kDay = 1.0
        if let d = l.sunDir {
            var diff = abs(Self.worldAngle(azimuth: d.azimuth) - Self.artAngle).truncatingRemainder(dividingBy: 2 * .pi)
            if diff > .pi { diff = 2 * .pi - diff }
            kDay = Self.smooth(100, 45, diff * 180 / .pi) * Self.smooth(4, 15, d.elevation)
        } else if !fixedDay && l.dark >= 0.5 { kDay = 0 }      // 月光（仰角 −4° 以下）；天氣變暗的白天 dark ≤ 0.45 不算
        // 雲遮住太陽：假影子跟著淡（晴天 overcast 0 ⇒ 不變）
        let k = max(kDay, Self.smooth(0.5, 0.95, l.dark)) * (1 - l.overcast)
        for m in [CityBuilder.shade, CityBuilder.shadeOut] { m.transparency = CGFloat(k) }
        // 夜晚：bloom、四角壓暗；燈開始亮就開 HDR（省電：全白天不開）。地下室（神經網路、機櫃 LED）不分日夜一律開
        camera.camera!.bloomIntensity = underground ? 0.9 : 0.6 * l.lamps * ps
        camera.camera!.wantsHDR = underground || l.lamps > 0.001
        basement.setPower(CGFloat(ps))
        camera.camera!.vignettingIntensity = Self.env("SHOWORK_OFFICE_NOVIGNETTE") != nil ? 0 : 0.35 * l.dark   // 測試：量逐層亮度時關掉四角壓暗
        camera.camera!.vignettingPower = 1.0
        omniBase = 700 * l.lamps * ps
        weatherFX.setDark(l.dark)
        omniDirty = true
        assignOmni()
    }
    /// 0→1 的平滑過渡（a→b，a 可以比 b 大）
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }

    // MARK: 更新

    /// 要不要重新取景：第一次（一定要）；大樓高度變了（你沒動過視角才要）
    enum Reframe { case none, layout, size }

    /// 還沒讀到資料前：只有大廳和頂樓
    static let fallback = TowerPlan(floors: [TowerFloor(kind: .lobby, id: "lobby", floorNo: "01", y: 0, height: TowerSpec.lobbyHeight),
                                             TowerFloor(kind: .roof, id: "roof", floorNo: "RF", y: TowerSpec.lobbyHeight, height: TowerSpec.roofHeight)])

    /// 樓層內容（主題、桌數、有沒有人、門牌）變了才重建那一層；樓層換位置播搬家；狀態變只換那個人／那面看板。
    /// `animate`＝視窗看得到、不是測試視窗、沒開「減少動態效果」（不然一律直接跳到結果）
    @discardableResult
    func update(tower newPlan: TowerPlan, decor: [String: FloorDecor], wander: WanderPlan, islands: [Island],
                guardStatus: GuardStatus, scanning: Bool, animate: Bool, now: Date = Date()) -> Reframe {
        let plan = newPlan.floors.isEmpty ? Self.fallback : newPlan
        let old = tower
        let first = modules.isEmpty
        let structural = plan.floors.map { "\($0.id)@\($0.y)" } != old.floors.map { "\($0.id)@\($0.y)" }
        if structural, moving != nil { finishMove() }
        self.decor = decor
        tower = plan
        guardLevel = guardStatus.level

        // 1. 模組：內容變了的重建（位置先放舊的 y，等一下統一處理）
        var created = Set<String>()
        for f in plan.floors {
            let key = moduleKey(f)
            if let m = modules[f.id], m.key == key { modules[f.id]!.floor = f; continue }
            let parts = buildModule(f)
            if f.kind == .lobby {       // 10-25 1 樓正門：對開電動側滑玻璃門
                let d = TowerCore.frontDoor(); TowerCore.setDoor(d, open: Self.testDoor ?? 0, .front); parts.node.addChildNode(d)
            }
            if f.kind != .idle {        // 10-25 電梯玻璃滑門（薄層沒有電梯門洞）
                for c in TD.elevs.indices { let d = TowerCore.landingDoor(c); TowerCore.setDoor(d, open: Self.testDoor ?? 0); parts.node.addChildNode(d) }
            }
            if let m = modules[f.id] {
                parts.node.position = m.parts.node.position
                m.parts.node.removeFromParentNode()
                if guardNode?.parent === m.parts.node { guardNode = nil; guardKey = "" }
            } else {
                parts.node.position = SCNVector3(0, CGFloat(f.y), 0)
                created.insert(f.id)
            }
            cutNow(parts)
            world.addChildNode(parts.node)
            modules[f.id] = Module(parts: parts, key: key, floor: f)
            boards[f.id] = nil; ghosts[f.id] = nil
            lodDirty = true; cutSig = ""; omniDirty = true      // 新樓層要分到自己的燈、自己的光照位元
            if Self.trace { print("office rebuild floor", f.id, "boxes=\(parts.boxes)"); fflush(stdout) }
        }
        let gone = modules.keys.filter { id in !plan.floors.contains { $0.id == id } }

        // 2. 位置：第一次／不能播 ⇒ 直接到位；樓層換位置 ⇒ 搬家動畫
        let moves = first ? [] : TowerPlan.moves(from: old, to: plan)
        if structural && animate && !first && !Look.reduceMotion {
            startMove(old: old, plan: plan, moves: moves, created: created, gone: gone)
        } else {
            for id in gone { modules[id]?.parts.node.removeFromParentNode(); modules[id] = nil }
            for f in plan.floors { modules[f.id]?.parts.node.position = SCNVector3(0, CGFloat(f.y), 0); modules[f.id]?.parts.node.eulerAngles.y = 0 }
        }
        for id in gone where modules[id] != nil && moving == nil { modules[id]?.parts.node.removeFromParentNode(); modules[id] = nil }
        if structural && Self.trace { print("office tower", plan.floors.map(\.id), "moves", moves.map(\.floorId)); fflush(stdout) }

        // 3. 電梯井、溜滑梯、結構柱：大樓高度變了才重建（搬家中用比較高的那個）
        let top = Float(max(plan.totalHeight, moving == nil ? 0 : old.totalHeight))
        let roofY = Float(plan.floor(id: "roof")?.y ?? 0)
        rebuildCore(top: top, roofFloor: roofY)
        if structural { omniDirty = true }
        assignOmni()        // 10-25：樓層讀進來之後沒有重新分燈 ⇒ 只有大廳、頂樓有燈（鏡頭動了才補上）

        // 4. 人、影分身、看板、保全
        let byKey = Dictionary(islands.map { ($0.project.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        if structural && moving != nil { snapTravelers() }
        lastWander = wander
        updatePeople(islands, wander: wander, animate: animate && moving == nil, now: now)
        updateGhosts(byKey)
        updateBoards(byKey)
        updateGuard(guardStatus, scanning: scanning)
        updateEmergency()
        updateCooler(city.state.power)
        highlight(lit)
        if !fidgetStarted { fidgetStarted = true; scheduleFidget() }
        looping = !Look.reduceMotion && (scanning || weatherFX.raining || persons.values.contains { $0.mood == .working && $0.islander.card.activity == .editing })
        if first { return .layout }
        return old.totalHeight != plan.totalHeight ? .size : .none
    }

    private func moduleKey(_ f: TowerFloor) -> String {
        switch f.kind {
        case .project:
            let d = decor[(f.project ?? "").lowercased()]
            return "p|\(f.project ?? "")|\(f.floorNo)|\(f.seats)|\(f.active)|\(d?.theme.rawValue ?? "")|\(d?.accentColor ?? "")|\(d?.props.joined(separator: ",") ?? "")"
        case .idle: return "i|" + f.plates.map { "\($0.floorNo):\($0.name):\($0.accent ?? "")" }.joined(separator: ",")
        case .lobby: return "lobby|\(tower.floors.contains { $0.kind == .idle })"
        case .roof: return "roof"
        }
    }

    private func buildModule(_ f: TowerFloor) -> ModuleParts {
        let p: ModuleParts
        switch f.kind {
        case .project: p = TowerModules.project(f, decor: decor[(f.project ?? "").lowercased()]) { s in if Self.trace { print("office prop", f.id, s) } }
        case .idle: p = TowerModules.idle(f)
        case .lobby: p = TowerModules.lobby(sign: !tower.floors.contains { $0.kind == .idle })
        case .roof: p = TowerModules.roof()
        }
        p.node.name = "floor:\(f.id)"
        return p
    }

    private func rebuildCore(top: Float, roofFloor: Float) {
        let ys = tower.floors.map { Float($0.y) }
        let sig = "\(top)|\(roofFloor)|\(ys)"
        guard sig != coreSig else { return }
        coreSig = sig
        core.removeFromParentNode()
        let (n, f) = TowerCore.build(top: top, roofFloor: roofFloor, floorYs: ys)
        core = n; coreFacades = f
        cutNow(facades: f)
        world.addChildNode(core)
        // 擋雨盒：一樓地面到頂樓花園地板（沒有頂樓就到樓頂），牆外緣
        let roofTop = tower.floor(id: "roof") != nil ? roofFloor + Float(TowerSpec.slab) : top
        weatherFX.shelter(in: world, lo: SIMD3(-TD.W / 2, 0, TD.zB), hi: SIMD3(TD.W / 2, roofTop, TD.zF))
        cutSig = ""; lodDirty = true
    }

    // MARK: 搬家（規範 §3.7）

    private func startMove(old: TowerPlan, plan: TowerPlan, moves: [TowerMove], created: Set<String>, gone: [String]) {
        let floaters = Set(moves.map(\.floorId))
        // 從薄層冒出來／降回薄層的位置：舊（新）大樓第一層薄層，沒有薄層就是大廳頂
        let oldIdle = Float(old.floors.first { $0.kind == .idle }?.y ?? TowerSpec.lobbyHeight)
        let newIdle = Float(plan.floors.first { $0.kind == .idle }?.y ?? TowerSpec.lobbyHeight)
        var items: [MoveAnim.Item] = []
        for f in plan.floors {
            guard let m = modules[f.id] else { continue }
            let from: Float = created.contains(f.id) ? (floaters.contains(f.id) ? oldIdle : Float(f.y)) : Float(m.parts.node.position.y)
            var glow: SCNNode?
            if floaters.contains(f.id) { let g = TowerModules.glowFrame(); m.parts.node.addChildNode(g); glow = g }
            items.append(.init(node: m.parts.node, fromY: from, toY: Float(f.y), floats: floaters.contains(f.id), glow: glow))
        }
        leaving = []
        for id in gone {
            guard let m = modules[id] else { continue }
            let g = TowerModules.glowFrame(); m.parts.node.addChildNode(g)
            items.append(.init(node: m.parts.node, fromY: Float(m.parts.node.position.y), toY: newIdle, floats: true, glow: g))
            leaving.append(m.parts.node)
            modules[id] = nil
        }
        let anim = MoveAnim(items: items)
        anim.apply(0)
        moving = anim
        moveUntil = Date().addingTimeInterval(MoveAnim.duration + 0.1)
        bump(MoveAnim.duration + 0.1)
        MoveAnim.run(anim, on: driver) { [weak self] in MainActor.assumeIsolated { self?.finishMove() } }
    }

    /// 搬家結束（或被新的變化打斷）：直接到最後的位置、拿掉光框、離開的樓層移掉
    private func finishMove() {
        guard let anim = moving else { return }
        moving = nil
        driver.removeAction(forKey: "move")
        anim.apply(MoveAnim.duration)
        for it in anim.items { it.glow?.removeFromParentNode() }
        for n in leaving { n.removeFromParentNode() }
        leaving = []
        moveUntil = .distantPast
        rebuildCore(top: Float(tower.totalHeight), roofFloor: Float(tower.floor(id: "roof")?.y ?? 0))
        parkCars(onlyIdle: true)   // 樓層高度變了：停著的車廂跟著停的那層走
        cutSig = ""; lodDirty = true; omniDirty = true
        assignOmni()
    }

    /// 視窗被蓋住／縮小：搬家直接到結果、路上的人直接落地（不留一半）
    func settle() {
        finishMove()
        guard persons.values.contains(where: { $0.place.hasPrefix("trip:") }) else { return }
        snapTravelers()
        for (id, p) in persons where p.place.isEmpty {
            placePerson(p.islander, floor: p.floor, seat: p.seat, seats: p.seats, state: lastWander.states[id], animate: false, now: Date())
        }
    }

    /// 測試截圖（SHOWORK_OFFICE_MOVE=<專案>[@秒]）：假裝這層剛從薄層升上來，定在第 t 秒的樣子（螢幕外視窗不推進動畫）
    func debugPoseMove(_ project: String, t: Double) -> Bool {
        guard let f = tower.floor(project: project), let m = modules[f.id] else { return false }
        let idleY = Float(tower.floors.first { $0.kind == .idle }?.y ?? TowerSpec.lobbyHeight)
        var items: [MoveAnim.Item] = []
        for g in tower.floors where g.y > f.y {
            if let mm = modules[g.id] { items.append(.init(node: mm.parts.node, fromY: Float(g.y - TowerSpec.floorHeight), toY: Float(g.y), floats: false, glow: nil)) }
        }
        let glow = TowerModules.glowFrame(); m.parts.node.addChildNode(glow)
        items.append(.init(node: m.parts.node, fromY: idleY, toY: Float(f.y), floats: true, glow: glow))
        MoveAnim(items: items).apply(t)
        return true
    }

    // MARK: 角色（座位、頂樓、閒晃）

    /// 造型有關的才算（token 每則訊息都變，不放進來，免得一直重建）
    static func personKey(_ p: Islander) -> String {
        let c = p.card
        return "\(p.mood.rawValue)|\(p.accessory?.rawValue ?? "")|\(c.title)|\(c.activity.rawValue)|\(c.blockedReason?.rawValue ?? "")|"
            + c.subagents.map(\.description).joined(separator: ",")
    }

    private func floorY(_ id: String) -> Float {
        if id == TowerLayout.b1Floor { return OfficeBasement.baseY }       // B1（10-22）：不在 TowerPlan 裡，固定在大廳正下方
        if let m = modules[id] { return Float(m.parts.node.position.y) }
        return Float(tower.floor(id: id)?.y ?? 0)
    }

    /// 第一次讀到人之後才播「出現」的煙（開窗時整棟的人不要一起冒煙）
    private var peopleSeeded = false
    /// 過場可以播嗎：沒開「減少動態效果」、沒因為太熱暫停（animate 另外已經包含視窗看得到、不是測試視窗）
    static var poofOK: Bool { !Look.reduceMotion && !HeatGate.shared.paused }

    private func updatePeople(_ islands: [Island], wander: WanderPlan, animate: Bool, now: Date) {
        var seen = Set<String>()
        for i in islands {
            let fid = TowerFloor.projectId(i.project)
            guard modules[fid] != nil else { continue }
            let all = i.people.sorted { $0.id < $1.id }
            for (k, p) in all.enumerated() where k < Self.maxPeople {
                seen.insert(p.id)
                placePerson(p, floor: fid, seat: k, seats: all.count, state: wander.states[p.id], animate: animate, now: now)
            }
        }
        // 離開的人（session 關掉）：忍術「ドロン」——爆一團煙、在煙裡縮掉（10-21 Kang：原本憑空消失很突兀）
        for (id, old) in persons where !seen.contains(id) {
            persons[id] = nil
            if animate && Self.poofOK, let parent = old.node.parent {
                Poof(at: old.node.simdPosition, in: parent, person: old.node, appear: false).run()
                bump(PoofCurve.duration + 0.1)
            } else {
                old.node.removeFromParentNode()
            }
        }
        peopleSeeded = peopleSeeded || !islands.isEmpty
        tripsDone = tripsDone.filter { id in wander.states.values.contains { s in s.trip.map { "\($0.sid)@\($0.start.timeIntervalSince1970)" } == id } }
    }

    /// 一個人現在該在哪：路上（播行程）、自己的座位、頂樓站位。外觀沒變只搬位置
    private func placePerson(_ p: Islander, floor fid: String, seat k: Int, seats n: Int, state: WanderState?, animate: Bool, now: Date) {
        let st = state ?? WanderState(spot: .desk)
        var trip = st.trip.flatMap { t -> WanderTrip? in
            let key = "\(t.sid)@\(t.start.timeIntervalSince1970)"
            return tripsDone.contains(key) ? nil : t
        }
        if let t = trip, testTripT == nil, !animate || now >= t.end { trip = nil }
        let seatPos = TowerLayout.seat(k, of: n, floor: fid)
        let seatedAtDesk = k < 12
        enum Where { case desk, roof(Int), cafe(Int), b1(Int), trip(WanderTrip)
            var isB1: Bool { if case .b1 = self { return true }; return false } }
        let w: Where
        if let t = trip { w = .trip(t) }
        else if case .roof(let s) = st.spot, modules["roof"] != nil { w = .roof(max(0, s)) }
        else if case .cafe(let s) = st.spot, modules["lobby"] != nil { w = .cafe(max(0, s)) }
        else if case .b1(let s) = st.spot { w = .b1(max(0, s)) }
        else { w = .desk }
        let seated: Bool, place: String
        switch w {
        case .desk: seated = seatedAtDesk; place = "desk:\(fid):\(k)/\(n)"
        case .roof(let s): seated = false; place = "roof:\(s)"
        case .cafe(let s): seated = false; place = "cafe:\(s)"
        case .b1(let s): seated = false; place = "b1:\(s)"
        case .trip(let t): seated = false; place = "trip:\(t.start.timeIntervalSince1970)"
        }
        // 地下室禁止飲食（10-22 Kang）：在 B1、或正要去 B1 的人手上不拿咖啡杯
        let noCup = w.isB1 || trip?.dest.isB1 == true
        let look = Self.personKey(p) + "|\(seated)|\(seatedAtDesk)|\(noCup)"
        let parent: SCNNode? = switch w {
        case .desk: modules[fid]?.parts.node
        case .roof: modules["roof"]?.parts.node
        case .cafe: modules["lobby"]?.parts.node
        case .b1: basement.root            // 鏡頭在地上時 basement.root 藏著 ⇒ 人也跟著看不到（正常）
        case .trip: world
        }
        var person: Person
        var isNew = false
        if let old = persons[p.id], old.look == look {
            person = old
            // 同一個人、同一個位置、還掛在對的樓層上（樓層重建過要重新掛）⇒ 不動
            if old.place == place && old.node.parent === parent && parent != nil {
                persons[p.id]!.islander = p
                return
            }
        } else {
            isNew = persons[p.id] == nil
            let intro = persons[p.id].map { $0.mood != p.mood } ?? true
            persons[p.id]?.node.removeFromParentNode()
            let node = makePerson(p, seated: seated, atDesk: seated && seatedAtDesk, noCup: noCup, intro: intro)
            person = Person(node: node, look: look, place: "", mood: p.mood, islander: p, floor: fid, seat: k, seats: n)
            if Self.trace { print("office rebuild person", p.id.prefix(8), place); fflush(stdout) }
        }
        person.node.removeAction(forKey: "trip")
        person.place = place; person.mood = p.mood; person.islander = p; person.floor = fid; person.seat = k; person.seats = n
        persons[p.id] = person
        let node = person.node
        func attach(_ parent: SCNNode?) { if node.parent !== parent { node.removeFromParentNode(); parent?.addChildNode(node) } }
        attach(parent)
        Self.b1Lit(node, w.isB1)
        switch w {
        case .desk:
            node.simdPosition = SIMD3(Float(seatPos.x), TD.room, Float(seatPos.z)); node.eulerAngles.y = CGFloat(seatPos.a)   // 自由座：照座位朝向（螢幕、子 agent 都掛在人底下一起轉）
        case .roof(let s):
            let r = TowerLayout.roofSlot(s)
            node.simdPosition = SIMD3(Float(r.x), TD.room, Float(r.z)); node.eulerAngles.y = CGFloat(s % 3 == 0 ? 0.3 : s % 3 == 1 ? -0.3 : 0)
        case .cafe(let s):
            let c = TowerLayout.cafeSlot(s)
            node.simdPosition = SIMD3(Float(c.x), TD.room, Float(c.z)); node.eulerAngles.y = CGFloat(c.a)
        case .b1(let s):
            // B1 模組本地座標（地坪＝TD.room），面向圖譜中心看神經網路
            let b = TowerLayout.b1Slot(s)
            node.simdPosition = SIMD3(Float(b.x), TD.room, Float(b.z)); node.eulerAngles.y = CGFloat(b.a)
        case .trip(let t):
            let path = tripPath(t, seat: (fid, seatPos))
            let el = testTripT ?? now.timeIntervalSince(t.start)
            path.apply(node, at: el)
            if let tt = testTripT { poseCars(t, at: tt) }   // 測試定格：車廂也定在同一秒（人才在車廂裡）
            if testTripT == nil {
                let key = "\(t.sid)@\(t.start.timeIntervalSince1970)", id = p.id
                TripPath.run(path, from: el, on: node) { [weak self] in
                    MainActor.assumeIsolated { self?.tripEnded(id, key: key) }
                }
                scheduleCars(t, now: now)
                walkUntil = max(walkUntil, t.end)
                bump(max(0.1, t.end.timeIntervalSince(now)))
            }
        }
        // 新來的人（新開的 session）：先冒一團煙、從煙裡彈出來（開窗第一次載入不播）
        if isNew && peopleSeeded && animate && Self.poofOK, let parent = node.parent {
            Poof(at: node.simdPosition, in: parent, person: node, appear: true).run()
            bump(PoofCurve.duration + 0.1)
        }
    }

    /// 人在 B1：吃 B1 自己的冷光（OfficeBasement.mask）、不吃大樓的暖補光（第 0 位元）；回到地上換回來。點擊位元（pickMask）不動
    private static func b1Lit(_ n: SCNNode, _ on: Bool) {
        func set(_ c: SCNNode) {
            guard c.geometry != nil else { return }
            c.categoryBitMask = on ? (c.categoryBitMask & ~1) | OfficeBasement.mask : (c.categoryBitMask & ~OfficeBasement.mask) | 1
        }
        set(n)
        n.enumerateChildNodes { c, _ in set(c) }
    }

    /// 測試定格（SHOWORK_OFFICE_POOF=<秒>[,in]）：螢幕外視窗不推進動畫 ⇒ 第一個人（id 排序）直接擺成過場第 t 秒的樣子。
    /// 離開版會把那個人搬進煙的節點底下（不從名單拿掉，定格用）；回傳 (id, 煙的世界座標) 給鏡頭對準
    func debugPoof(t: Double, appear: Bool) -> (String, SCNVector3)? {
        guard let (id, p) = persons.sorted(by: { $0.key < $1.key }).first(where: { $0.value.place.hasPrefix("desk:") }), let parent = p.node.parent else { return nil }
        let f = Poof(at: p.node.simdPosition, in: parent, person: p.node, appear: appear)
        f.apply(t)
        let w = f.root.worldPosition
        return (id, SCNVector3(w.x, w.y + 0.9, w.z))
    }

    /// 探針：場景節點總數（過場結束後要回到原本的數量）
    var nodeCount: Int { var n = 0; scene.rootNode.enumerateHierarchy { _, _ in n += 1 }; return n }

    /// 行程播完：回到座位／頂樓（同一個行程在下次刷新清掉之前不要重播）
    private func tripEnded(_ id: String, key: String) {
        tripsDone.insert(key)
        guard let p = persons[id] else { return }
        persons[id]!.place = ""
        placePerson(p.islander, floor: p.floor, seat: p.seat, seats: p.seats, state: lastWander.states[id], animate: false, now: Date())
    }

    /// 開始搬家時：路上的人直接落地（規範：搬家期間不同時播閒晃）
    private func snapTravelers() {
        for (id, p) in persons where p.place.hasPrefix("trip:") {
            p.node.removeAction(forKey: "trip")
            if let t = lastWander.states[id]?.trip { tripsDone.insert("\(t.sid)@\(t.start.timeIntervalSince1970)") }
            persons[id]!.place = ""
        }
        parkCars()
        walkUntil = .distantPast
    }

    /// 這趟的車廂段落（世界座標、絕對時間）：有 carMoves 照它（含空車先去接人）；舊排程沒有 ⇒ 退回搭乘段落、全算第 0 部
    private func tripCarLegs(_ t: WanderTrip) -> [(car: Int, leg: TripPath.CarLeg, to: String)] {
        if t.carMoves.isEmpty {
            return zip(t.nodes, t.nodes.dropFirst()).filter { $0.1.move == .elevator }.map { a, b in
                (b.car ?? 0, TripPath.CarLeg(y0: floorY(a.floor) + TD.room, y1: floorY(b.floor) + TD.room,
                                             start: t.start.addingTimeInterval(a.t), end: t.start.addingTimeInterval(b.t)), b.floor)
            }.filter { cars.indices.contains($0.car) }
        }
        return t.carMoves.filter { cars.indices.contains($0.car) }.map { m in
            (m.car, TripPath.CarLeg(y0: floorY(m.from) + TD.room, y1: floorY(m.to) + TD.room,
                                    start: t.start.addingTimeInterval(m.start), end: t.start.addingTimeInterval(m.end)), m.to)
        }
    }

    /// 把這趟的車廂段落併進各部車廂的排程、重新播（同一段（同一部、同起訖時間）只留一份；同一趟重新掛上來不會重複）
    private func scheduleCars(_ t: WanderTrip, now: Date) {
        var touched = Set<Int>()
        for (c, leg, to) in tripCarLegs(t) {
            carLegs[c].removeAll { $0.start == leg.start && $0.end == leg.end }
            carLegs[c].append(leg)
            touched.insert(c)
            if leg.end >= (carLegs[c].map(\.end).max() ?? leg.end) { carRest[c] = to }
        }
        for c in touched.sorted() {
            carLegs[c].removeAll { $0.end < now.addingTimeInterval(-60) }
            carLegs[c].sort { $0.start < $1.start }
            let e = TD.elevs[c]
            TripPath.runCar(cars[c], x: e.x, z: e.y, legs: carLegs[c], rest: cars[c].simdPosition.y, now: now)
            scheduleDoors(c, now: now)
        }
    }

    // MARK: 電梯門（10-25）

    /// 第 c 部電梯每一層的門＋那層地坪的世界高度（車廂底＝這個高度）
    private func doors(_ c: Int) -> [(y: Float, node: SCNNode)] {
        var out: [(Float, SCNNode)] = []
        if let d = basement.root.childNode(withName: "edoor-\(c)", recursively: false) { out.append((OfficeBasement.baseY + TD.room, d)) }
        for m in modules.values {
            if let d = m.parts.node.childNode(withName: "edoor-\(c)", recursively: false) { out.append((Float(m.parts.node.position.y) + TD.room, d)) }
        }
        return out
    }

    /// 照第 c 部車廂的排程排門：停在某層的時段（等人上車、到站後開著 doorDwell 秒）那層開，其他層關。一次性動作，跑完就停
    private func scheduleDoors(_ c: Int, now: Date) {
        let legs = carLegs[c]
        var stops: [(y: Float, from: Date, to: Date)] = []
        if let f = legs.first, f.start > now { stops.append((f.y0, now, f.start)) }                 // 車廂已經在這層、等人上車
        // 到站：提早 doorTime 開始開，車廂停好時門剛好全開（人走出來不穿過玻璃）
        let early = -TowerCore.doorTime
        for (a, b) in zip(legs, legs.dropFirst()) where b.start > a.end { stops.append((a.y1, a.end.addingTimeInterval(early), b.start)) }
        if let l = legs.last { stops.append((l.y1, l.end.addingTimeInterval(early), l.end.addingTimeInterval(TowerCore.doorDwell))) }
        var end = now
        for d in doors(c) {
            let mine = stops.filter { abs($0.y - d.y) < 0.05 }.map { (from: $0.from, to: $0.to) }
            end = max(end, TowerCore.runDoor(d.node, stops: mine, now: now))
        }
        bump(max(0.1, end.timeIntervalSince(now) + 0.1))
    }

    /// 測試定格（SHOWORK_OFFICE_TRIP_T）：車廂直接放到這趟第 t 秒的高度
    private func poseCars(_ t: WanderTrip, at s: Double) {
        let at = t.start.addingTimeInterval(s)
        var legs: [Int: [TripPath.CarLeg]] = [:]
        for (c, leg, _) in tripCarLegs(t) { legs[c, default: []].append(leg) }
        for (c, l) in legs {
            let e = TD.elevs[c]
            cars[c].removeAction(forKey: "car")
            cars[c].simdPosition = SIMD3(e.x, TripPath.carY(l.sorted { $0.start < $1.start }, at: at, rest: cars[c].simdPosition.y), e.y)
        }
    }

    /// 車廂直接停到最後的樓層（路上的人落地、搬家後樓層高度變了）：排程那邊有記（WanderPlan.cars）就照它，否則照最後播的那段終點；
    /// `onlyIdle`＝只動沒在跑的車廂（搬家結束時：剛開始的行程不要被打斷）
    private func parkCars(onlyIdle: Bool = false) {
        for (c, car) in cars.enumerated() {
            if onlyIdle && car.action(forKey: "car") != nil { continue }
            car.removeAction(forKey: "car")
            carLegs[c] = []
            if lastWander.cars.indices.contains(c) { carRest[c] = lastWander.cars[c].floor }
            let id = modules[carRest[c]] != nil || tower.floor(id: carRest[c]) != nil || carRest[c] == TowerLayout.b1Floor ? carRest[c] : "lobby"
            let e = TD.elevs[c]
            car.simdPosition = SIMD3(e.x, floorY(id) + TD.room, e.y)
            for d in doors(c) { TowerCore.setDoor(d.node, open: Self.testDoor ?? 0) }     // 停著＝門關（測試：SHOWORK_OFFICE_DOOR=0…1 定格開幾成）
        }
    }

    /// 行程 → 世界座標路線：走路照節點直線、電梯垂直、溜滑梯沿螺旋、瞬移直接跳
    /// `seat`＝這個人的樓層＋座位（自由座朝向不一定面向鏡頭）：從座位出發、走回座位的那一刻，身體轉成座位的朝向 a
    private func tripPath(_ t: WanderTrip, seat: (floor: String, pos: (x: Double, z: Double, a: Double))) -> TripPath {
        var keys: [TripPath.Key] = []
        func atSeat(_ n: WanderNode) -> Bool { n.floor == seat.floor && abs(n.x - seat.pos.x) < 0.05 && abs(n.z - seat.pos.z) < 0.05 }
        let seatFace = Float(seat.pos.a)
        let roofY = floorY("roof")
        let slideTop = roofY + TD.room + 0.3
        for (i, n) in t.nodes.enumerated() {
            let y = floorY(n.floor) + TD.room
            let p = SIMD3(Float(n.x), y, Float(n.z))
            switch n.move {
            case .start: keys.append(.init(t: n.t, p: p, face: atSeat(n) ? seatFace : 0, ride: false))
            case .walk: keys.append(.init(t: n.t, p: p, face: nil, ride: false))
            case .elevator: keys.append(.init(t: n.t, p: p, face: .pi / 2, ride: true))
            case .teleport:
                if let last = keys.last { keys.append(.init(t: n.t, p: last.p, face: last.face, ride: true)) }
                keys.append(.init(t: n.t, p: p, face: nil, ride: true))
            case .wait:
                // 拜訪：面向主人（主人在左邊 0.9）；茶水角：面向鏡頭
                var face: Float = 0
                if case .visit = t.dest { face = -.pi / 2 }
                // 在電梯門口等電梯（10-22 Kang：沒有電梯要等）：面向電梯門
                if TowerLayout.elevatorDoors.contains(where: { abs($0.x - n.x) < 0.3 && abs($0.z - n.z) < 0.3 }) { face = -.pi / 2 }
                if let last = keys.last { keys[keys.count - 1] = .init(t: last.t, p: last.p, face: face, ride: last.ride) }
                keys.append(.init(t: n.t, p: p, face: face, ride: true))
            case .slide:
                // 溜滑梯：先走到螺旋起點，再沿螺旋滑到這層的高度，最後走進右門
                let t0 = i > 0 ? t.nodes[i - 1].t : n.t
                let a0 = TD.slideA0, a1 = TD.slideAngle(top: slideTop, y: y)
                let steps = max(2, Int((a1 - a0) / TD.slideStep))
                let span = n.t - t0
                keys.append(.init(t: t0 + span * 0.05, p: TD.slidePoint(a0, top: slideTop, y: slideTop + 0.04), face: nil, ride: false))
                for s in 1...steps {
                    let a = a0 + (a1 - a0) * Float(s) / Float(steps)
                    let yy = slideTop - (a - a0) / TD.slideStep * TD.slideDrop + 0.04
                    keys.append(.init(t: t0 + span * (0.05 + 0.85 * Double(s) / Double(steps)), p: TD.slidePoint(a, top: slideTop, y: yy), face: a + .pi / 2, ride: true))
                }
                keys.append(.init(t: n.t, p: p, face: nil, ride: false))
            }
        }
        // 最後一步走回座位：抵達那一刻轉成座位朝向（走路中途仍照前進方向）
        if let last = t.nodes.last, atSeat(last), let k = keys.last { keys[keys.count - 1] = .init(t: k.t, p: k.p, face: seatFace, ride: k.ride) }
        return TripPath(keys: keys)
    }

    /// 螢幕空間標籤要的東西：每個人（含保全）的錨點節點＋卡片＋狀態＋所在樓層；樓層（id、節點、高度、樓層號、專案、主題）
    struct LabelPerson { let id: String; let anchor: SCNNode; let card: BoardCard?; let mood: Mood; let floor: String }
    struct LabelFloor { let id: String; let node: SCNNode; let height: Float; let floorNo: String; let title: String; let kind: TowerFloorKind; let names: [String]; let accent: UInt32? }
    func labelTargets() -> (people: [LabelPerson], floors: [LabelFloor]) {
        var ps: [LabelPerson] = []
        for (id, p) in persons {
            guard let a = p.node.childNode(withName: "anchor", recursively: true) else { continue }
            if p.place.hasPrefix("b1:") && !underground { continue }    // 在 B1 看神經網路的人：鏡頭在地上時看不到，名牌也不畫
            ps.append(LabelPerson(id: id, anchor: a, card: p.islander.card, mood: p.mood, floor: p.place.hasPrefix("b1:") ? "b1" : p.floor))
        }
        if let g = guardNode, let a = g.childNode(withName: "anchor", recursively: true) {
            ps.append(LabelPerson(id: "guard", anchor: a, card: nil, mood: .idle, floor: "lobby"))
        }
        let fs: [LabelFloor] = tower.floors.compactMap { f in
            guard let m = modules[f.id] else { return nil }
            let title: String
            switch f.kind {
            case .project: title = "\(f.floorNo)  \(f.project ?? "")・\((decor[(f.project ?? "").lowercased()]?.theme ?? .general).title)"
            case .idle: title = "閒置 \(f.plates.count) 個專案・名字在左側清單"
            case .lobby: title = "01  大廳・前台保全"
            case .roof: title = "RF  空中花園"
            }
            return LabelFloor(id: f.id, node: m.parts.node, height: Float(f.height), floorNo: f.floorNo, title: title, kind: f.kind,
                              names: f.plates.map { $0.floorNo.isEmpty ? $0.name : "\($0.floorNo) \($0.name)" },
                              accent: f.kind == .project ? TP.hex((decor[(f.project ?? "").lowercased()]?.theme ?? .general).accent) : f.kind == .lobby ? 0x1E3A8A : nil)
        }
        return (ps, fs)
    }

    /// 城市的名牌（建築＋出港的船）
    func cityLabelTargets() -> [(id: String, anchor: SCNNode, text: String, alert: Bool)] {
        guard !underground else { return [] }       // 鏡頭在地下室：城市藏起來了，名牌也不畫
        return city.labels + city.shipLabels.map { ($0.id, $0.anchor, $0.text, false) }
    }

    /// 城市資料變了：有變才重建；狀態剛變的警示燈、出港的船要播幾秒
    func updateCity(_ s: CityState, animate: Bool) {
        bump(city.update(s, animate: animate))
        setGrid(s.grid.stage, animate: animate)
        updateCooler(s.power)
    }

    // MARK: 電力（10-22 電廠＝AI 額度）

    private(set) var gridStage: CityGrid.Stage = .normal
    private var gridSet = false
    /// 額度階段 → 燈光乘數、逃生燈、AI 定格。只在跨門檻時做事；進入「吃緊」閃 2 秒（一次性），之後穩定變暗
    func setGrid(_ st: CityGrid.Stage, animate: Bool) {
        guard st != gridStage || !gridSet else { return }
        let old = gridStage
        gridStage = st; gridSet = true
        HeatGate.shared.setBlackout(st == .blackout)
        updateEmergency()
        if st == .flicker && old < .flicker && animate && !Look.reduceMotion {
            var steps: [(Double, CGFloat)] = []
            for i in 0..<8 { steps.append((Double(i) * 0.25, i % 2 == 0 ? 0.1 : 0.8)) }
            for (t, v) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    MainActor.assumeIsolated { guard self?.gridStage == .flicker else { return }; VoxMat.setPower(v) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in
                MainActor.assumeIsolated { self?.applyLights() }
            }
            bump(2.2)
        }
        applyLights()
        bump(0.3)
    }

    /// 電力乘數（燈、補光、bloom、發光材質）
    private var gridScale: Double {
        switch gridStage { case .normal: 1; case .dim: 0.6; case .flicker: 0.35; case .blackout: 0 }
    }

    private var emergency: SCNNode?
    private var emergencySig = ""
    /// 停電：每層正面右邊一盞綠色逃生燈（不吃電力乘數）
    private func updateEmergency() {
        let ys = gridStage == .blackout ? tower.floors.map { Float($0.y) } : []
        let sig = "\(ys)"
        guard sig != emergencySig else { return }
        emergencySig = sig
        emergency?.removeFromParentNode(); emergency = nil
        guard !ys.isEmpty else { return }
        let m = VoxelMesh(ao: 0), k = Kit(m: m)
        for y in ys { k.b(.identity, TD.W / 2 - 0.7, y + TD.room - 0.55, TD.zF + 0.02, 0.5, 0.22, 0.04, CityBuilder.signal(0x22C55E)) }
        let n = m.node(name: "emergency")
        world.addChildNode(n); emergency = n
    }

    private var cooler: SCNNode?
    private var coolerSig = ""
    /// 頂樓冷卻水塔（cool42；10-22 從城市搬上來，電廠讓給額度）：右前方空地，煙量＝溫度、hot 以上紅燈
    private func updateCooler(_ p: CityPower) {
        guard let roof = modules["roof"]?.parts.node else { return }
        let n = CityRules.smoke(p)
        let sig = "\(ObjectIdentifier(roof))|\(n)|\(p.alert)|\(p.known)|\(p.level ?? "")"
        guard sig != coolerSig else { return }
        coolerSig = sig
        cooler?.removeFromParentNode()
        let m = VoxelMesh(ao: 0), k = Kit(m: m)
        let x: Float = 5.0, z: Float = 1.6, r = TD.room
        let rs: [Float] = [0.55, 0.48, 0.42, 0.42, 0.48]
        for (i, w) in rs.enumerated() { k.b(.identity, x, r + Float(i) * 0.26, z, w * 2, 0.26, w * 2, TM.f(TP.ST2)) }
        let top = r + Float(rs.count) * 0.26
        k.b(.identity, x, top, z, 0.8, 0.03, 0.8, TM.f(TP.FN6))
        let col = p.alert || p.level == "warm" ? VoxMat.dayNight(0xC9B79A, 0x5A606A) : VoxMat.dayNight(0xE6E3DE, 0x5A606A)
        for i in 0..<n {
            let sz: Float = 0.4 + Float(i) * 0.14
            k.b(.identity, x + Float(i) * 0.18, top + 0.12 + Float(i) * 0.38, z - Float(i) * 0.06, sz, sz * 0.8, sz, col)
        }
        if p.alert { k.b(.identity, x, top + 0.03, z + 0.5, 0.14, 0.14, 0.14, CityBuilder.red) }
        let node = m.node(name: "cooler")
        roof.addChildNode(node); cooler = node
        let wp = roof.convertPosition(SCNVector3(x, top + 0.4, z), to: nil)
        city.setPoint("city:cooler", wp)
    }

    /// 俯瞰城市（左側索引列「城市」）：從右前方高處看整個街區，大樓在中間
    func frameCity(_ v: SCNView) {
        let aspect = Double(max(0.4, v.bounds.width / max(1, v.bounds.height)))
        let b = CityBuilder.bounds
        // 直式視窗（寬高比 < 1）：46° 時寬度先頂到、下半部空一大片 ⇒ 改 55° 更俯視，城市縱向變長填滿高度（研究 R2-2-6）
        let el: Double = aspect < 1 ? 55 : 46
        let (dist, t) = Self.fit(lo: b.lo, hi: b.hi, aspect: aspect, az: 18 * .pi / 180, el: el * .pi / 180, margin: 0.98)
        place(v, target: t, dist: dist, az: 18, el: el)
    }

    func peopleNodes() -> [(String, SCNNode)] { persons.map { ($0.key, $0.value.node) } + (guardNode.map { [("guard", $0)] } ?? []) }
    func personNode(_ id: String) -> SCNNode? { id == "guard" ? guardNode : persons[id]?.node }

    /// 鏡頭對準用的點：roof／lobby／floor:<專案>
    func focusPoint(_ key: String) -> SCNVector3? {
        let id: String
        if key == "roof" || key == "lobby" { id = key }
        else if key.hasPrefix("floor:") { id = TowerFloor.projectId(String(key.dropFirst(6))) }
        else { return nil }
        guard let m = modules[id] else { return nil }
        return SCNVector3(0, m.parts.node.position.y + CGFloat(TD.room) + 1.3, 0.5)
    }

    /// 頭上的符號多跳三下（你動過視角、鏡頭不飛過去時用）；回傳要播幾秒
    func bounceMark(_ id: String) -> TimeInterval {
        guard !Look.reduceMotion, let m = personNode(id)?.childNode(withName: "gem", recursively: true) else { return 0 }
        m.runAction(Self.hop(0.18, times: 3))
        return 3 * 0.6 + 0.2
    }
    static func hop(_ h: CGFloat, times: Int) -> SCNAction {
        .repeat(.sequence([.moveBy(x: 0, y: h, z: 0, duration: 0.2), .moveBy(x: 0, y: -h, z: 0, duration: 0.2), .wait(duration: 0.2)]), count: times)
    }

    /// 左側索引列滑鼠停在某層：那層樓板底下亮一圈 NE-1 光框（同搬家的光框；只加一個節點）
    private var floorGlow: SCNNode?
    @discardableResult
    func highlightFloor(_ id: String?) -> Bool {
        let cur = floorGlow?.parent?.name
        let want = id.map { "floor:\($0)" }
        guard cur != want else { return false }
        floorGlow?.removeFromParentNode(); floorGlow = nil
        if let id, let m = modules[id] { let g = TowerModules.glowFrame(); m.parts.node.addChildNode(g); floorGlow = g }
        return true
    }

    func highlight(_ id: String?) {
        lit = id
        // 只在真的變了才寫（10-20 量閒置 CPU：每次刷新都把同樣的值寫回去，SceneKit 會當成場景變了、多畫一張）
        func set(_ n: SCNNode?, _ h: Bool) { if let n, n.isHidden != h { n.isHidden = h } }
        for (pid, p) in persons { set(p.node.childNode(withName: "halo", recursively: false), pid != id) }
        set(guardNode?.childNode(withName: "halo", recursively: true), id != "guard")
    }

    /// 影分身：從別的專案 cd 過來逛的，半透明站在這層前帶
    private func updateGhosts(_ byKey: [String: Island]) {
        for f in tower.projectFloors {
            let island = byKey[(f.project ?? "").lowercased()]
            let key = island?.ghosts.map { "\($0.id)|\($0.mood.rawValue)" }.joined(separator: ",") ?? ""
            if ghosts[f.id]?.key == key { continue }
            ghosts[f.id]?.node.removeFromParentNode()
            let g = SCNNode()
            // 站在 PropPlacer 找的空地（10-22：原本固定 x −4.8 起、z 2.3，疊在★大件上穿圖）；空地不夠就少畫幾個
            let spots = modules[f.id]?.parts.ghostSpots ?? []
            for (x, at) in zip(island?.ghosts ?? [], spots) {
                let n = makeKubo(x.mood, accessory: x.accessory, seated: false, intro: false)
                n.opacity = 0.4
                n.simdPosition = SIMD3(at.x, TD.room, at.y)
                g.addChildNode(n)
            }
            modules[f.id]?.parts.node.addChildNode(g)
            ghosts[f.id] = (g, key)
        }
    }

    /// 一個人：角色（坐在椅子上面向桌子，或站在咖啡吧）＋亮著的螢幕＋名牌＋頭上符號＋子 agent＋點擊盒
    /// `intro`＝狀態剛變（等你＝跳三下、做完＝搖一下）；只是搬位置重建時不重播
    private func makePerson(_ p: Islander, seated: Bool, atDesk: Bool, noCup: Bool = false, intro: Bool = true) -> SCNNode {
        let root = SCNNode(); root.name = "p:\(p.id)"
        let tint = KuboArt.tint(p.mood)
        let act: AIActivity = p.mood == .working ? p.card.activity : .none
        // 螢幕：亮的顏色＝狀態（紫打字、紅等你、綠做完、橘卡住；休息／睡覺＝暗）。兩面都亮，背對你的人也看得到
        if atDesk && seated && p.mood != .idle && p.mood != .asleep && !p.card.captain {
            let scr = SCNNode(geometry: SCNBox(width: 0.58, height: 0.17, length: 0.05, chamferRadius: 0))
            scr.geometry?.firstMaterial = VoxMat.flat(tint, emit: (0.7, 3.0))
            scr.position = SCNVector3(0, 0.86, CGFloat(TowerLayout.chairBack) + 0.2)        // 桌上螢幕（OfficeTower desk：桌心前 0.2、底高 0.76）
            root.addChildNode(scr)
        }
        let kubo = makeKubo(p.mood, accessory: p.accessory, activity: act, seated: seated, cup: p.mood == .idle && !seated && !noCup, intro: intro)
        kubo.position.y = seated ? CGFloat(TowerSpec.seatTop) : 0      // 椅面頂（OfficeTower.desk）
        root.addChildNode(kubo)
        // 子 agent：椅子後面縮小、半透明的小 Kubo，頭上小牌寫在做什麼（最多 3 隻，多的寫 +N）
        var subs = p.card.subagents
        if act == .delegating && subs.isEmpty { subs = [SubagentInfo(description: "子任務")] }
        let spots: [(CGFloat, CGFloat)] = [(-0.75, -0.6), (0.75, -0.6), (0, -1.1)]
        for (k, _) in subs.prefix(3).enumerated() {
            let (x, z) = spots[k]
            let mini = makeKubo(.working, accessory: nil, seated: false, gem: false, intro: false)
            mini.scale = SCNVector3(0.6, 0.6, 0.6); mini.opacity = 0.6
            mini.position = SCNVector3(x, 0, z)
            root.addChildNode(mini)
        }
        // 10-20 第 4 棒：子 agent 原本頭上有 3D 小字牌（預設鏡頭下只剩 3 pt 的「Com…」，讀不到）⇒ 拿掉，改成名牌後面寫「子 agent N」
        // 10-20 UI/UX 優化：名牌與頭上符號改成螢幕空間標籤（OfficeLabels：固定 14／16 pt，不跟著樓層縮小、不被樓板切掉）；
        // 3D 裡只留一個不畫的錨點給標籤投影用（頭頂寶石上方），寶石保留（狀態色在 3D 裡也要有）
        let anchor = SCNNode(); anchor.name = "anchor"
        // 錨點在頭頂（不是寶石上方）：寶石離天花只剩 0.5，標籤放在寶石上面會壓到上一層樓板、看起來像上一層的人
        anchor.position = SCNVector3(0, seated ? CGFloat(TowerSpec.seatedHead) + 0.05 : 0.92 * Self.kuboScale + 0.05, 0)
        root.addChildNode(anchor)
        addHaloAndHitbox(root)
        Self.pickable(root)
        return root
    }

    /// 滑鼠停上去：地上一圈白光；點擊範圍：整個角色一個透明盒
    private func addHaloAndHitbox(_ root: SCNNode, size: CGFloat = 1.1) {
        let halo = SCNTorus(ringRadius: 0.6 * size, pipeRadius: 0.035)
        let hm = SCNMaterial(); hm.lightingModel = .constant; hm.diffuse.contents = NSColor.white; hm.emission.contents = NSColor.white
        halo.firstMaterial = hm
        let hn = SCNNode(geometry: halo); hn.name = "halo"; hn.position = SCNVector3(0, 0.06, 0); hn.isHidden = true
        root.addChildNode(hn)
        let hit = SCNBox(width: size, height: 2.2, length: size, chamferRadius: 0)
        hit.firstMaterial = SCNMaterial(); hit.firstMaterial!.transparency = 0; hit.firstMaterial!.writesToDepthBuffer = false
        let hitN = SCNNode(geometry: hit); hitN.name = "hitbox"; hitN.position = SCNVector3(0, 1.1, 0)
        hitN.isHidden = true        // 10-20 第四版：不畫（原本 opacity 0.001 每人還是多一個 draw call）；點擊時 hitTest 照樣找得到（ignoreHiddenNodes: false）
        root.addChildNode(hitN)
    }

    static func pickable(_ n: SCNNode) {
        n.categoryBitMask |= pickMask
        n.enumerateChildNodes { c, _ in c.categoryBitMask |= pickMask }
    }

    /// 方塊 Kubo：陶土橘身體、方塊眼睛、小手；`seated`＝坐在椅子上（腿往前彎），原點＝椅面（坐著）或地面（站著）。
    /// 面向 +z。`activity`＝進行中在用哪類工具（換道具，只有改檔會動）；頭上寶石＝狀態色
    private func makeKubo(_ mood: Mood, accessory: Accessory?, activity: AIActivity = .none, seated: Bool,
                          gem: Bool = true, gemColor: NSColor? = nil, cup: Bool = false, cap: Bool = false, intro: Bool = true) -> SCNNode {
        let k = SCNNode()
        k.scale = SCNVector3(Self.kuboScale, Self.kuboScale, Self.kuboScale)
        // 夜晚身體微微自己亮（10-20 審查：離燈籠遠的 Kubo 夜晚幾乎看不見；只改共用材質的強度，不加燈）
        let clay = VoxMat.flat(KuboArt.clay, emit: (0, 0.32)), dark = VoxMat.flat(KuboArt.clayDark, emit: (0, 0.28)), ink = VoxMat.flat(0x2a1d18)
        let still = Look.reduceMotion
        // 腿：站著＝直的；坐著＝大腿往前、小腿往下（在身體外，不跟著跳）
        if seated {
            let legs = VoxelMesh()
            for x: Float in [-0.17, 0.17] {
                legs.box(.identity, SIMD3(x, 0.06, 0.2), SIMD3(0.14, 0.12, 0.36), dark)
                legs.box(.identity, SIMD3(x, -0.17, 0.33), SIMD3(0.13, 0.36, 0.13), dark)
            }
            k.addChildNode(legs.node())
        } else {
            // 站著：兩條腿各自一個節點、軸心在髖（y 0.3），走路時 TripPath 前後擺（10-24 Kang：原本合成一塊，走路腳不會動）
            for (x, name) in [(Float(-0.17), "legL"), (Float(0.17), "legR")] {
                let leg = VoxelMesh()
                leg.box(.identity, SIMD3(0, -0.15, 0), SIMD3(0.14, 0.3, 0.14), dark)
                let n = leg.node(); n.name = name
                n.simdPosition = SIMD3(x, 0.3, 0)
                k.addChildNode(n)
            }
        }
        // 身體：以前的座標（身體底在 0.3）；坐著整個往下 0.3（身體底＝椅面）
        let body = SCNNode(); body.name = "body"
        body.position.y = seated ? -0.3 : 0
        k.addChildNode(body)
        let mesh = VoxelMesh()
        mesh.box(.identity, SIMD3(0, 0.61, 0), SIMD3(0.66, 0.62, 0.5), clay)
        // 眼睛（面向 +z）；讀檔、搜尋時往下看（瞇一點）
        let eh: Float = mood == .asleep ? 0.03 : mood == .finished ? 0.05 : (activity == .reading || activity == .searching) ? 0.08 : 0.15
        for x: Float in [-0.14, 0.14] {
            mesh.box(.identity, SIMD3(x, activity == .reading ? 0.64 : 0.68, 0.255), SIMD3(0.09, eh, 0.02), ink)
        }
        // 手的位置跟著道具走（坐著打字：手在桌上的鍵盤）
        let kbY: Float = seated ? 0.43 : 0.40         // 坐著：鍵盤剛好在桌面上（椅面 0.56、放大 1.6）
        let hands: [SIMD3<Float>] = switch activity {
        case .reading: [SIMD3(-0.24, 0.5, 0.36), SIMD3(0.24, 0.5, 0.36)]
        case .editing: [SIMD3(-0.16, kbY + 0.07, 0.42), SIMD3(0.16, kbY + 0.07, 0.42)]
        case .searching: [SIMD3(-0.4, 0.55, 0.12), SIMD3(0.42, 0.62, 0.3)]
        default: [SIMD3(-0.4, 0.55, 0.12), SIMD3(0.4, 0.55, 0.12)]
        }
        let typing = mood == .working && activity == .editing && !still
        for (n, h) in hands.enumerated() {
            if typing {
                // 打字：唯一一直在動的動畫（其他動作都是靜態造型）
                let a = SCNNode(geometry: SCNBox(width: 0.12, height: 0.12, length: 0.12, chamferRadius: 0))
                a.geometry?.firstMaterial = clay
                a.simdPosition = h
                let up = SCNAction.moveBy(x: 0, y: 0.05, z: 0, duration: 0.125), down = up.reversed()
                a.runAction(.repeatForever(n == 0 ? .sequence([up, down]) : .sequence([down, up])))
                body.addChildNode(a)
            } else {
                mesh.box(.identity, h, SIMD3(0.12, 0.12, 0.12), clay)
            }
        }
        // 頭上的狀態寶石（像徽章的小寶石）：紫工作／紅等你／綠做完／橘卡住
        let gc: NSColor? = gemColor ?? (gem ? (mood == .working || mood == .waiting || mood == .finished || mood == .stuck ? KuboArt.tint(mood) : nil) : nil)
        if let gc {
            let g = SCNNode(geometry: SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0))
            g.geometry?.firstMaterial = VoxMat.flat(gc, emit: (0.6, 1.3))
            g.position = SCNVector3(0, accessory == .crown ? 1.28 : 1.16, 0); g.eulerAngles = SCNVector3(0.6, 0.78, 0)
            g.name = "gem"
            body.addChildNode(g)
        }
        switch activity {
        case .reading:
            // 書：封面＋白色內頁，往自己這邊斜
            mesh.box(Xf(x: 0, y: 0.52, z: 0.4), SIMD3(0, 0, 0), SIMD3(0.46, 0.32, 0.03), VoxMat.flat(0x3361bf))
            for x: Float in [-0.105, 0.105] { mesh.box(Xf(x: x, y: 0.53, z: 0.43), SIMD3(0, 0, 0), SIMD3(0.2, 0.28, 0.02), VoxMat.flat(0xf5f5f5)) }
        case .editing:
            // 鍵盤（坐著＝在桌上）
            mesh.box(.identity, SIMD3(0, kbY, 0.44), SIMD3(0.56, 0.035, 0.2), VoxMat.flat(0x2e2e2e))
            mesh.box(.identity, SIMD3(0, kbY + 0.022, 0.44), SIMD3(0.5, 0.01, 0.15), VoxMat.flat(0xbf99ff, emit: (0.5, 1.2)))
        case .running:
            // 一台小終端機：黑底綠字「$ ▋」（坐著＝放在桌上右邊，不擋臉）
            let tn = SCNNode(geometry: SCNBox(width: 0.42, height: 0.28, length: 0.12, chamferRadius: 0))
            tn.geometry?.firstMaterial = VoxMat.flat(0x242424)
            tn.position = seated ? SCNVector3(0.5, 0.6, 0.42) : SCNVector3(0, 0.36, 0.42)
            let face = SCNPlane(width: 0.36, height: 0.22)
            let fm = SCNMaterial(); fm.lightingModel = .constant; fm.diffuse.contents = Self.terminalFace; fm.isDoubleSided = true
            face.firstMaterial = fm
            for z: CGFloat in [0.061, -0.061] { let fnode = SCNNode(geometry: face); fnode.position.z = z; tn.addChildNode(fnode) }
            body.addChildNode(tn)
        case .searching:
            // 放大鏡：鏡框＋淡藍鏡片＋握把，右手舉著
            let lens = SCNNode(); lens.position = SCNVector3(0.42, 0.86, 0.34); lens.eulerAngles.z = -0.35
            let rim = SCNTorus(ringRadius: 0.13, pipeRadius: 0.025); rim.firstMaterial = VoxMat.flat(0xd9b34d)
            let rn = SCNNode(geometry: rim); rn.eulerAngles.x = .pi / 2; lens.addChildNode(rn)
            let glass = SCNCylinder(radius: 0.12, height: 0.01); glass.firstMaterial = VoxMat.flat(0x99d9ff, emit: (0.6, 1.0))
            let gn = SCNNode(geometry: glass); gn.eulerAngles.x = .pi / 2; gn.opacity = 0.55; lens.addChildNode(gn)
            let handle = SCNBox(width: 0.05, height: 0.2, length: 0.05, chamferRadius: 0); handle.firstMaterial = VoxMat.flat(0x593823)
            let hn = SCNNode(geometry: handle); hn.position.y = -0.23; lens.addChildNode(hn)
            body.addChildNode(lens)
        case .thinking:
            // 頭上旁邊一顆想法泡泡「…」
            // 10-20 第 4 棒：原本是 3D 文字「…」（另一套字、遠看糊掉）⇒ 改成白泡泡＋三顆深色方點（純方塊）
            mesh.box(.identity, SIMD3(-0.62, 1.16, 0.1), SIMD3(0.42, 0.22, 0.06), VoxMat.flat(0xf7f7f7))
            for i in 0..<3 { mesh.box(.identity, SIMD3(-0.74 + Float(i) * 0.12, 1.16, 0.14), SIMD3(0.06, 0.06, 0.02), VoxMat.flat(0x2F3338)) }
            mesh.box(.identity, SIMD3(-0.38, 0.95, 0.1), SIMD3(0.07, 0.07, 0.07), VoxMat.flat(0xf7f7f7))
            mesh.box(.identity, SIMD3(-0.31, 0.88, 0.1), SIMD3(0.05, 0.05, 0.05), VoxMat.flat(0xf7f7f7))
        case .none, .delegating: break      // 交辦：旁邊的小 Kubo 就是（makePerson 畫）
        }
        if cup { mesh.box(.identity, SIMD3(0.45, 0.68, 0.18), SIMD3(0.12, 0.16, 0.12), VoxMat.flat(0xf5f0e6)) }
        // 配件
        switch accessory {
        case .crown:
            let gold = VoxMat.flat(0xffcc33, emit: (0.5, 1.0))
            mesh.box(.identity, SIMD3(0, 0.95, 0), SIMD3(0.5, 0.1, 0.4), gold)
            for (x, z) in [(-0.2, -0.15), (0.2, -0.15), (-0.2, 0.15), (0.2, 0.15), (0, 0.15)] as [(Float, Float)] {
                mesh.box(.identity, SIMD3(x, 1.04, z), SIMD3(0.09, 0.1, 0.09), gold)
            }
        case .headset:
            mesh.box(.identity, SIMD3(0, 0.94, 0), SIMD3(0.7, 0.05, 0.08), VoxMat.flat(0x262626))
            for x: Float in [-0.35, 0.35] { mesh.box(.identity, SIMD3(x, 0.7, 0), SIMD3(0.06, 0.2, 0.16), VoxMat.flat(0x262626)) }
        case .glasses:
            mesh.box(.identity, SIMD3(0, 0.69, 0.265), SIMD3(0.5, 0.04, 0.02), VoxMat.flat(0x1a1a1a))
            for x: Float in [-0.14, 0.14] { mesh.box(.identity, SIMD3(x, 0.68, 0.27), SIMD3(0.16, 0.13, 0.015), VoxMat.flat(0x1a1a1a)) }
        case nil: break
        }
        if cap {
            // 保全：藍色警帽＋帽徽＋胸前盾牌
            let blue = VoxMat.flat(0x1e3a8a)
            mesh.box(.identity, SIMD3(0, 0.98, 0), SIMD3(0.74, 0.14, 0.6), blue)
            mesh.box(.identity, SIMD3(0, 0.93, 0.36), SIMD3(0.74, 0.04, 0.22), blue)
            mesh.box(.identity, SIMD3(0, 1.0, 0.31), SIMD3(0.12, 0.09, 0.02), VoxMat.flat(0xfacc15, emit: (0.4, 0.8)))
            mesh.box(.identity, SIMD3(-0.15, 0.46, 0.255), SIMD3(0.13, 0.15, 0.02), VoxMat.flat(0xfacc15))
        }
        let mn = mesh.node()
        body.insertChildNode(mn, at: 0)
        // 等你＝跳三下、做完＝搖一下，之後靜止
        if !still && intro {
            switch mood {
            case .waiting: body.runAction(Self.hop(0.18, times: 3)); bump(3 * 0.6 + 0.2)
            case .finished:
                body.runAction(.sequence([.rotateBy(x: 0, y: 0, z: 0.08, duration: 0.6), .rotateBy(x: 0, y: 0, z: -0.16, duration: 1.2), .rotateBy(x: 0, y: 0, z: 0.08, duration: 0.6)]))
                bump(2.6)
            default: break
            }
        }
        if mood == .asleep { k.opacity = 0.85 }
        return k
    }

    /// 小終端機的螢幕（只畫一次）
    static let terminalFace: CGImage? = {
        let img = NSImage(size: NSSize(width: 180, height: 110), flipped: true) { r in
            NSColor(srgbRed: 0.03, green: 0.06, blue: 0.04, alpha: 1).setFill(); r.fill()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 30, weight: .bold),
                                                    .foregroundColor: NSColor(srgbRed: 0.35, green: 1, blue: 0.5, alpha: 1)]
            ("$ ▋" as NSString).draw(at: NSPoint(x: 16, y: 34), withAttributes: a)
            return true
        }
        return raster(img, scale: 2)
    }()

    // MARK: 前台・保全（大廳；規範 §3.4：站在前台右側、不被櫃台擋住）

    nonisolated static func guardColor(_ l: GuardLevel) -> NSColor {
        switch l {
        case .normal: VoxMat.color(0x22c55e)
        case .notice: VoxMat.color(0xfacc15)
        case .alert: VoxMat.color(0xef4444)
        }
    }

    private func updateGuard(_ g: GuardStatus, scanning: Bool) {
        guard let lobby = modules["lobby"]?.parts.node else { return }
        let key = "\(g.level.rawValue)|\(g.hasData)|\(scanning)"
        if key == guardKey, let n = guardNode, n.parent === lobby { return }
        guardKey = key
        // 巡邏中重建（掃描開始／結束、等級變了）：記下走到第幾秒，重建後從那裡接著走
        let resume = patrolling ? patrolStart.map { Date().timeIntervalSince($0) } : nil
        guardNode?.removeFromParentNode()
        let r = SCNNode(); r.name = "guard"
        let lv = Self.guardColor(g.level), wifi = VoxMat.color(0x38bdf8)
        // 監控螢幕：左右兩面＝資安等級、中間＝Wi-Fi；警示＝三面都紅
        let cols: [NSColor] = !g.hasData ? [VoxMat.color(0x6b7280), wifi, VoxMat.color(0x6b7280)] : g.level == .alert ? [lv, lv, lv] : [lv, wifi, lv]
        for (i, c) in cols.enumerated() {
            let s = SCNNode(geometry: SCNBox(width: 0.62, height: 0.36, length: 0.02, chamferRadius: 0))
            s.geometry?.firstMaterial = VoxMat.flat(c, emit: (0.4, 1.3))
            s.simdPosition = SIMD3(-0.45 + Float(i) * 0.75, TD.room + 1.82, TowerLobby.divZ + 0.235)   // 前台隔屏上的螢幕
            r.addChildNode(s)
        }
        // Wi-Fi 天線頂的寶石：掃描中會轉
        let ant = SCNNode(geometry: SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0))
        ant.geometry?.firstMaterial = VoxMat.flat(wifi, emit: (0.8, 1.6))
        ant.simdPosition = SIMD3(1.4, TD.room + 1.78, 0.3); ant.eulerAngles = SCNVector3(0.6, 0.78, 0)
        if scanning && !Look.reduceMotion { ant.runAction(.repeatForever(.rotateBy(x: 0, y: .pi, z: 0, duration: 1.2))) }
        r.addChildNode(ant)
        // 保全 Kubo：深藍警帽，站在前台右側、朝鏡頭偏左 20°
        let man = SCNNode(); man.name = "guard-man"; man.simdPosition = Self.guardPost; man.eulerAngles.y = CGFloat(Self.guardFace)
        let k = makeKubo(.idle, accessory: nil, seated: false, gemColor: lv, cap: true, intro: false)
        man.addChildNode(k)
        addHaloAndHitbox(man, size: 1.2)
        r.addChildNode(man)
        // 名牌與頭上符號：螢幕空間標籤（OfficeLabels「Security」），這裡只留錨點
        let anchor = SCNNode(); anchor.name = "anchor"; anchor.simdPosition = SIMD3(0, Float(1.25 * Self.kuboScale) + 0.1, 0)
        man.addChildNode(anchor)
        Self.pickable(r)
        lobby.addChildNode(r)
        guardNode = r
        patrolling = false
        let scanStarted = scanning && !wasScanning
        wasScanning = scanning
        if let t = OfficeView.testEnv("SHOWORK_OFFICE_PATROL").flatMap(Double.init) {   // 測試定格：巡邏第 t 秒的位置（螢幕外視窗不推進動畫）
            man.childNodes.first?.addChildNode(Self.flashlight())
            let path = patrolPath()
            path.apply(man, at: t)
            poseFrontDoor(path, at: t)
        } else if let el = resume, startPatrol(from: el, force: true) {
        } else if scanStarted, startPatrol(force: true) {
            // 10-23 Kang：按「立即掃描」（或定時掃描開始）⇒ 保全馬上出門巡一趟
        } else {
            schedulePatrol()
        }
    }

    // MARK: 微動作（10-23 Kang：人物整天定著不動、超級死板 ⇒ 方案 A）
    // 每 3–6 秒挑 1～2 個在座位／休息點（不在路上）的人做一個 1 秒左右的小動作，做完畫面又停下（bump 只多畫那一下）；
    // 動作照狀態：等你＝小跳一下、讀檔＝點頭、思考＝歪頭、搜尋＝左右張望、跑指令＝往前看一下、做完＝搖一下、
    // 休息＝喝一口（往後仰）或轉頭跟旁邊聊天、睡著＝慢慢呼吸一次。不是一直重畫 ⇒ CPU 只在動的那一下

    private var fidgetStarted = false

    private func scheduleFidget() {
        guard !Look.reduceMotion, !BoardWindow.testMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 3...6)) { [weak self] in
            guard let self else { return }
            self.fidget()
            self.scheduleFidget()
        }
    }

    private func fidget() {
        guard moving == nil else { return }
        // 鏡頭在地下室：只動 B1 的人（地上的看不到，動了白畫）；在地上反過來
        let pool = persons.values.filter { !$0.place.hasPrefix("trip:") && !$0.place.isEmpty && $0.place.hasPrefix("b1:") == underground }
        for p in pool.shuffled().prefix(Int.random(in: 1...2)) {
            guard let body = p.node.childNode(withName: "body", recursively: true), !body.hasActions else { continue }
            let (a, d) = Self.fidgetAction(p.mood, p.islander.card.activity, resting: !p.place.hasPrefix("desk:"))
            body.runAction(a)
            bump(d)
        }
    }

    /// 回傳 (動作, 秒數)。全部是「做完回到原位」的相對動作 ⇒ 疊不歪
    static func fidgetAction(_ mood: Mood, _ act: AIActivity, resting: Bool) -> (SCNAction, Double) {
        func swing(x: CGFloat = 0, y: CGFloat = 0, z: CGFloat = 0, _ t: Double, hold: Double = 0) -> (SCNAction, Double) {
            let go = SCNAction.rotateBy(x: x, y: y, z: z, duration: t); go.timingMode = .easeInEaseOut
            let back = SCNAction.rotateBy(x: -x, y: -y, z: -z, duration: t); back.timingMode = .easeInEaseOut
            return (.sequence([go, .wait(duration: hold), back]), t * 2 + hold)
        }
        switch mood {
        case .waiting: return (hop(0.1, times: 1), 0.6)
        case .finished: return swing(z: 0.08, 0.35, hold: 0.1)
        case .stuck: return swing(z: -0.1, 0.4, hold: 0.4)
        case .asleep:
            let up = SCNAction.scale(to: 1.04, duration: 0.9), down = SCNAction.scale(to: 1, duration: 0.9)
            return (.sequence([up, down]), 1.8)
        case .idle:
            if resting && Bool.random() { return swing(y: Bool.random() ? 0.6 : -0.6, 0.4, hold: 1.6) }   // 轉頭跟旁邊的人聊天
            return swing(x: -0.12, 0.35, hold: 0.5)                                                       // 喝一口
        case .working:
            switch act {
            case .reading: return swing(x: 0.1, 0.3, hold: 0.2)
            case .thinking: return swing(z: Bool.random() ? 0.12 : -0.12, 0.4, hold: 0.5)
            case .searching: return swing(y: Bool.random() ? 0.4 : -0.4, 0.35, hold: 0.3)
            case .editing: return swing(x: 0.05, 0.2)
            default: return swing(y: Bool.random() ? 0.25 : -0.25, 0.3, hold: 0.4)
            }
        }
    }

    // MARK: 保全巡邏（10-23 Kang：保全完全不會動，偶爾要帶手電筒去巡貨櫃場、大樓周圍、電力站）
    // 每 6–10 分鐘一趟：前台 → 大門 → 廣場 → 電廠正門（停下照一照）→ 回廣場 → 匯流道 → 貨櫃場入口（停下照一照）→ 原路回崗位。
    // 共用閒晃的 TripPath（折線節點、步行 1.1 m/s、身體上下兩格）；走路時才持續渲染（walkUntil），一趟約 90 秒 ⇒ 平均 CPU 跟閒晃同一級。
    // 警示（三面螢幕都紅）時守在螢幕前；減少動態、搬家中、鏡頭在地下室時不出發

    static let guardPost = SIMD3<Float>(2.25, TD.room, -0.3)
    static let guardFace: Float = -0.35
    private var patrolling = false
    private var patrolGen = 0
    private var patrolStart: Date?
    private var wasScanning = false

    private func schedulePatrol() {
        patrolGen += 1
        let gen = patrolGen
        guard !Look.reduceMotion, !BoardWindow.testMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 360...600)) { [weak self] in
            guard let self, self.patrolGen == gen else { return }
            self.startPatrol()
        }
    }

    /// 回傳 true＝出發了（測試／手動觸發也走這裡）
    @discardableResult
    func startPatrol(from elapsed: Double = 0, force: Bool = false) -> Bool {
        defer { if !patrolling { schedulePatrol() } }
        // force（掃描觸發、重建後接著走）：警示等級也照走；搬家中、地下室、減少動態仍不走
        guard !patrolling, force || guardLevel != .alert, moving == nil, !underground, !Look.reduceMotion,
              let man = guardNode?.childNode(withName: "guard-man", recursively: false), let kubo = man.childNodes.first else { return false }
        let path = patrolPath()
        guard elapsed < path.duration else { return false }
        patrolling = true
        patrolStart = Date().addingTimeInterval(-elapsed)
        let light = Self.flashlight()
        kubo.addChildNode(light)
        patrolGen += 1                          // 新的一趟：舊趟（重建前）的收尾回呼、排好的下一趟都作廢
        let gen = patrolGen
        let rest = path.duration - elapsed
        path.apply(man, at: elapsed)
        TripPath.run(path, from: elapsed, on: man) { [weak self] in
            MainActor.assumeIsolated { self?.endPatrol(gen) }
        }
        walkUntil = max(walkUntil, Date().addingTimeInterval(rest))
        bump(rest)
        scheduleFrontDoor(path, start: patrolStart!, now: Date())
        if elapsed == 0 { Log.note("OFFICE 保全出門巡邏 \(Int(path.duration)) 秒\(force ? "（掃描觸發）" : "")") }
        // 動畫沒推進（視窗被蓋住）時 done 不會來：時間到了照樣收回崗位
        DispatchQueue.main.asyncAfter(deadline: .now() + rest + 5) { [weak self] in self?.endPatrol(gen) }
        return true
    }

    private func endPatrol(_ gen: Int) {
        guard patrolling, gen == patrolGen, let man = guardNode?.childNode(withName: "guard-man", recursively: false) else { return }
        patrolling = false; patrolStart = nil
        man.removeAction(forKey: "trip")
        man.childNodes.first?.childNode(withName: "flashlight", recursively: false)?.removeFromParentNode()
        man.simdPosition = Self.guardPost; man.eulerAngles.y = CGFloat(Self.guardFace)
        if let d = frontDoor { TowerCore.runDoor(d, stops: [], now: Date(), .front) }     // 提早收回崗位：開著的門關起來
        schedulePatrol()
    }

    // MARK: 1 樓正門（10-25 Kang：對開電動側滑玻璃門，有人進出才開）

    private var frontDoor: SCNNode? { modules["lobby"]?.parts.node.childNode(withName: "fdoor", recursively: false) }

    /// 照行程排正門：人走進門口 1.4 公尺內提早 doorTime 開；最後一個人離開 1 秒後才關（隊長 Penny：多人進出不抖）。
    /// 一次性 SCNAction（TowerCore.runDoor），不每幀檢查；現在只有保全巡邏會走大門
    private func scheduleFrontDoor(_ path: TripPath, start: Date, now: Date) {
        guard let d = frontDoor else { return }
        let stops = frontDoorStops(path, start: start)
        let end = TowerCore.runDoor(d, stops: stops, now: now, .front)
        bump(max(0.1, end.timeIntervalSince(now) + 0.1))
        if Self.trace { print("office front door", stops.map { (Int($0.from.timeIntervalSince(start)), Int($0.to.timeIntervalSince(start))) }); fflush(stdout) }
    }

    /// 測試定格（SHOWORK_OFFICE_PATROL=t）：正門擺成巡邏第 t 秒該有的開度
    private func poseFrontDoor(_ path: TripPath, at t: Double) {
        guard let d = frontDoor else { return }
        let s = Date(timeIntervalSince1970: 0), at = s.addingTimeInterval(t), dt = TowerCore.doorTime
        var k: Double = 0
        for st in frontDoorStops(path, start: s) where at >= st.from && at <= st.to {
            k = min(1, at.timeIntervalSince(st.from) / dt, st.to.timeIntervalSince(at) / dt)
        }
        TowerCore.setDoor(d, open: Float(k), .front)
        print("office front door t=\(t) open=\(String(format: "%.2f", k)) stops=\(frontDoorStops(path, start: s).map { (Int($0.from.timeIntervalSince(s)), Int($0.to.timeIntervalSince(s))) })"); fflush(stdout)
    }

    private func frontDoorStops(_ path: TripPath, start: Date) -> [(from: Date, to: Date)] {
        let c = SIMD2<Float>(TowerCore.frontX, TD.zF)
        var near: [(from: Date, to: Date)] = []
        var enter: Double?
        var t = 0.0
        while t <= path.duration + 0.1 {
            let q = path.pose(t).p
            let isNear = simd_distance(SIMD2(q.x, q.z), c) < 1.4
            if isNear, enter == nil { enter = t }
            if !isNear, let e = enter { near.append((start.addingTimeInterval(e), start.addingTimeInterval(t))); enter = nil }
            t += 0.1
        }
        if let e = enter { near.append((start.addingTimeInterval(e), start.addingTimeInterval(path.duration))) }
        // 開：提早 doorTime；關：離開後 1 秒＋關門動畫；兩段重疊或接著就合併（不會關到一半又開）
        var stops: [(from: Date, to: Date)] = []
        for n in near {
            let s = n.from.addingTimeInterval(-TowerCore.doorTime), e = n.to.addingTimeInterval(1 + TowerCore.doorTime)
            if let last = stops.last, s <= last.to.addingTimeInterval(TowerCore.doorTime) { stops[stops.count - 1].to = max(last.to, e) }
            else { stops.append((s, e)) }
        }
        return stops
    }

    /// 巡邏路線（大廳模組本地座標；模組不轉 ⇒ 室外 = 世界座標減大廳高度）
    private func patrolPath() -> TripPath {
        let out = CityBuilder.ry - floorY("lobby")
        let doorX = TowerCore.frontX, plazaZ = TD.zF + 0.8
        // 10-25 大門搬到正中央（前台正前方）：從崗位先繞到前台右前方再走向門口，不穿過前台（前台 x −1.0…1.6、z −0.28…0.48）
        let deskTurn = SIMD3<Float>(1.95, TD.room, 1.3)
        var pts: [(SIMD3<Float>, Double)] = [            // (位置, 到了停幾秒)
            (deskTurn, 0),
            (SIMD3(doorX, TD.room, TD.zF - 0.6), 0),
            (SIMD3(doorX, out, plazaZ), 0),
            (SIMD3(CityBuilder.powerX, out, plazaZ), 0),
            (SIMD3(CityBuilder.powerX, out, CityBuilder.powerZ + 2.4), 4),     // 電廠正門前：照一照
            (SIMD3(CityBuilder.powerX, out, plazaZ), 0),
        ]
        if !city.state.disks.isEmpty {
            let yz = CityBuilder.z0 + 3.5                                      // 第一座堆場的中線
            pts += [(SIMD3(CityBuilder.trunkX, out, plazaZ), 0), (SIMD3(CityBuilder.trunkX, out, yz), 0),
                    (SIMD3(-13.4, out, yz), 4),                               // 堆場入口：照一照貨櫃
                    (SIMD3(CityBuilder.trunkX, out, yz), 0), (SIMD3(CityBuilder.trunkX, out, plazaZ), 0)]
        }
        pts += [(SIMD3(doorX, out, plazaZ), 0), (SIMD3(doorX, TD.room, TD.zF - 0.6), 0), (deskTurn, 0), (Self.guardPost, 0)]
        var keys: [TripPath.Key] = [.init(t: 0, p: Self.guardPost, face: Self.guardFace, ride: false)]
        var t = 0.0, last = Self.guardPost
        for (p, stay) in pts {
            t += Double(simd_length(p - last)) / 1.1
            keys.append(.init(t: t, p: p, face: nil, ride: false))
            if stay > 0 {
                // 停下：面向原本走的方向（照向電廠／貨櫃），左右掃一下
                let d = p - last, f = atan2(d.x, d.z)
                // 抵達那一點仍是走路（ride 會讓「走過來」那段變成滑過來、腳不動：10-24 Kang 看到巡邏有一段腳沒動）
                keys[keys.count - 1] = .init(t: t, p: p, face: f, ride: false)
                keys.append(.init(t: t + stay * 0.33, p: p, face: f + 0.5, ride: true))
                keys.append(.init(t: t + stay * 0.66, p: p, face: f - 0.5, ride: true))
                t += stay
                keys.append(.init(t: t, p: p, face: f, ride: true))
            }
            last = p
        }
        keys.append(.init(t: t + 0.01, p: Self.guardPost, face: Self.guardFace, ride: true))
        return TripPath(keys: keys)
    }

    /// 手電筒：右手一支＋往前的淡黃光錐（自發光、加法混色，不是真的燈 ⇒ 不增加場景的光照成本）
    private static func flashlight() -> SCNNode {
        let n = SCNNode(); n.name = "flashlight"
        n.position = SCNVector3(0.42, 0.62, 0.3)
        let body = SCNNode(geometry: SCNBox(width: 0.08, height: 0.08, length: 0.22, chamferRadius: 0))
        body.geometry?.firstMaterial = VoxMat.flat(0x262626)
        n.addChildNode(body)
        let h: CGFloat = 1.8
        let cone = SCNCone(topRadius: 0.04, bottomRadius: 0.36, height: h)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(srgbRed: 1, green: 0.93, blue: 0.6, alpha: 1)
        m.transparency = 0.22
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        cone.firstMaterial = m
        // 軸心＝窄口（手上）：beam 繞 x 轉 −90° ⇒ 本地 −y 朝前；光錐掛在 −h/2，窄口（+y）剛好在軸心（10-23 Kang：原本 +90° 光錐是反的）；再加 0.25 讓光往下照
        let beam = SCNNode(); beam.name = "beam"
        beam.position = SCNVector3(0, 0, 0.13)
        beam.eulerAngles.x = -.pi / 2 + 0.25
        let c = SCNNode(geometry: cone)
        c.position = SCNVector3(0, -h / 2, 0)
        c.castsShadow = false
        beam.addChildNode(c)
        n.addChildNode(beam)
        // 10-24 Kang：光錐會穿過牆、櫃台、電廠 ⇒ 每 0.1 秒沿光軸打一條線，撞到東西就把光錐縮到撞點（只縮長度＝被牆截斷的光）
        let full = Float(h)
        n.runAction(.repeatForever(.sequence([.run { f in if let b = f.childNode(withName: "beam", recursively: false) { Self.clipBeam(b, full: full) } }, .wait(duration: 0.1)])), forKey: "beam")
        return n
    }

    /// 光軸從手到光錐末端打一條線，最近的非保全自己的東西 ⇒ 光錐長度縮到那裡（SceneKit 渲染執行緒呼叫）
    nonisolated private static func clipBeam(_ beam: SCNNode, full: Float) {
        let a = beam.convertPosition(SCNVector3Zero, to: nil)
        let b = beam.convertPosition(SCNVector3(0, -CGFloat(full), 0), to: nil)
        let worldLen = simd_distance(SIMD3<Float>(a), SIMD3<Float>(b))
        guard worldLen > 0.01, let scene = Self.sceneRoot(of: beam) else { return }
        let hits = scene.hitTestWithSegment(from: a, to: b, options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue,
                                                                        SCNHitTestOption.categoryBitMask.rawValue: 1,
                                                                        SCNHitTestOption.backFaceCulling.rawValue: false])
        var best = worldLen
        for h in hits where !Self.isGuard(h.node) {
            best = min(best, simd_distance(SIMD3<Float>(a), SIMD3<Float>(h.worldCoordinates)))
        }
        let k = CGFloat(max(0.04, best / worldLen))
        if abs(beam.scale.y - k) > 0.01 { beam.scale = SCNVector3(1, k, 1) }
    }

    nonisolated private static func sceneRoot(of n: SCNNode) -> SCNNode? {
        var p = n; while let q = p.parent { p = q }
        return p === n ? nil : p
    }

    nonisolated private static func isGuard(_ n: SCNNode) -> Bool {
        var p: SCNNode? = n
        while let q = p { if q.name == "guard-man" { return true }; p = q.parent }
        return false
    }

    // MARK: 樓層看板（大樓左外側、電梯外；只在鏡頭近時顯示）

    static func boardKey(_ i: Island) -> String {
        i.people.prefix(maxPeople).map { p in
            let c = p.card
            return "\(c.title)|\(p.mood.rawValue)|\(c.report?.progress ?? c.review?.progress ?? -1)|\(c.report?.confidence ?? c.review?.confidence ?? -1)|\(Int(c.ctx?.percent ?? -1))|\(officeLine(c))|\(c.tokens.map { tokenShort($0.total) } ?? "")"
        }.joined(separator: "\n") + "|\(i.queued)|\(i.people.count)"
    }

    /// 10-21 CPU 突波：看板貼圖（每次重畫 ≈ 一張 1400×600 點陣圖＋SceneKit 重新上傳）原本只要卡片內容一變就重畫——
    /// token 數、ctx% 在 AI 工作時幾秒就變一次，但看板只在鏡頭 30 公尺內才看得到（預設鏡頭全部藏著）。
    /// ⇒ 看不到的看板只記下「內容過期」，等鏡頭停在附近（updateLOD）要顯示時才畫；內容沒變永遠不重畫
    private var boardStale: [String: Island] = [:]
    private var boardsDrawn = 0
    private func boardWorld(_ fid: String) -> SCNVector3? {
        guard let m = modules[fid] else { return nil }
        let p = m.parts.node.position
        return SCNVector3(CGFloat(TD.boardX), p.y + CGFloat(TD.room + 0.2), CGFloat(TD.boardZ))
    }
    private func boardNear(_ fid: String) -> Bool {
        guard let q = boardWorld(fid) else { return false }
        return hypot(hypot(lodAt.x - q.x, lodAt.y - q.y), lodAt.z - q.z) <= Self.boardDistance
    }

    private func updateBoards(_ byKey: [String: Island]) {
        func has(_ k: String) -> Bool { tower.floor(id: k).flatMap { f in byKey[(f.project ?? "").lowercased()].map { !$0.people.isEmpty } } ?? false }
        for (k, b) in boards where !has(k) { b.node.removeFromParentNode(); boards[k] = nil }
        for k in boardStale.keys where !has(k) { boardStale[k] = nil }
        for f in tower.projectFloors {
            guard let i = byKey[(f.project ?? "").lowercased()], !i.people.isEmpty, modules[f.id] != nil else { continue }
            let key = Self.boardKey(i)
            if boards[f.id]?.key == key, boards[f.id]?.node.parent != nil { boardStale[f.id] = nil; continue }
            if !boardNear(f.id) { boardStale[f.id] = i; boards[f.id]?.node.isHidden = true; continue }
            drawBoard(f.id, i, key: key)
        }
        lodDirty = true
    }

    private func drawBoard(_ fid: String, _ i: Island, key: String) {
        guard let f = tower.floor(id: fid), let mod = modules[fid] else { return }
        boards[fid]?.node.removeFromParentNode()
        boardStale[fid] = nil
        let d = decor[(f.project ?? "").lowercased()]
        let accent = d.flatMap { TP.hex($0.accentColor) }.map(VoxMat.color) ?? VoxMat.color(TP.FN4)
        let n = makeBoard(i, color: accent)
        n.simdPosition = SIMD3(TD.boardX, TD.room + 0.2, TD.boardZ)
        n.isHidden = false
        mod.parts.node.addChildNode(n)
        boards[fid] = (n, key)
        boardsDrawn += 1
        if Self.trace { print("office redraw board", fid, "total", boardsDrawn); fflush(stdout) }
    }

    private func makeBoard(_ i: Island, color: NSColor) -> SCNNode {
        let img = Self.boardImage(i, color: color)
        var w: CGFloat = 4.4
        var h = w * img.size.height / img.size.width
        if h > 3.2 { w *= 3.2 / h; h = 3.2 }          // 不高過一層樓
        let plane = SCNPlane(width: w, height: h)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = Self.raster(img, scale: 2.5)
        m.diffuse.mipFilter = .linear; m.diffuse.minificationFilter = .linear
        m.isDoubleSided = true
        plane.firstMaterial = m
        let n = SCNNode(geometry: plane)
        n.pivot = SCNMatrix4MakeTranslation(0, -h / 2, -0.14)  // 底邊對齊位置；往鏡頭那側讓出 0.14（立柱在看板後面）
        let bb = SCNBillboardConstraint(); bb.freeAxes = .Y
        n.constraints = [bb]
        n.name = "board"
        return n
    }

    // MARK: 鏡頭停下來時算一次：看板遠近、cutaway、門牌換牆、夜晚 omni 指派

    private var lodDirty = true, lodAt = SCNVector3Zero
    private var cutSig = ""
    private var omniDirty = true
    private var focusY: CGFloat = 0

    /// 回傳有沒有改到畫面（有的話要補畫一下）
    @discardableResult
    func updateLOD(camera p: SCNVector3, target: SCNVector3) -> Bool {
        let ug = setUnderground(p.y < 0)
        guard lodDirty || hypot(hypot(p.x - lodAt.x, p.y - lodAt.y), p.z - lodAt.z) > 0.5 else { return ug }
        lodDirty = false; lodAt = p
        for (fid, b) in boards {
            let h = !boardNear(fid) || boardStale[fid] != nil
            if b.node.isHidden != h { b.node.isHidden = h }
        }
        // 內容過期、現在走近了：這時才重畫
        for (fid, i) in boardStale where boardNear(fid) { drawBoard(fid, i, key: Self.boardKey(i)) }
        if let mast = core.childNode(withName: "board-mast", recursively: false) {
            let h = !boards.values.contains { !$0.node.isHidden }
            if mast.isHidden != h { mast.isHidden = h }
        }
        if abs(focusY - target.y) > 0.5 { focusY = target.y; omniDirty = true }
        weatherFX.aim()
        // 鏡頭到大樓外框最近的距離（10-22 Kang：拉近到樓頂時樓板被 zNear 切成三角形）
        // 下緣到地下室土層底（鏡頭在地上時算出來一樣；平移到地下時 B1 才不會被 zNear 切掉）
        let lo = SIMD3<Float>(-TD.W / 2 - 1, OfficeBasement.bottomY, TD.zB - 2), hi = SIMD3<Float>(TD.W / 2 + 1, Float(tower.totalHeight) + 3, TD.zF + 1)
        let cp = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        let near = simd_length(cp - simd_clamp(cp, lo, hi))
        weatherFX.setInside(near == 0)   // 鏡頭鑽進大樓：擋雨盒從裡面看不到 ⇒ 雨直接藏起來
        updateFog(dist: Float(hypot(hypot(p.x - target.x, p.y - target.y), p.z - target.z)), near: near)
        assignOmni()
        return applyCutaway(camera: p) || ug
    }

    // MARK: 地下室 B1（10-22）

    /// 換神經網路的資料（GraphSource 讀到新的 Graphify 圖譜時呼叫）
    func setNeuralGraph(_ g: NeuralGraph) {
        basement.setGraph(g)
        bump(0.2)
    }
    /// 圖譜正在自轉（鏡頭在地下室）：OfficeSCNView 依這個持續渲染；地上時 false ⇒ 不吃 CPU
    var basementSpinning: Bool { basement.spinning }

    /// 鏡頭進出地下室：地下 ⇒ 大地面、城市（含地坪）淡出藏起來、雨停在地上、B1 出現並開始轉；回到地上全部恢復。回傳有沒有變
    @discardableResult
    func setUnderground(_ u: Bool) -> Bool {
        guard u != underground else { return false }
        underground = u
        basement.setLive(u, spin: !Look.reduceMotion)
        weatherFX.setHidden(u)
        let ground = [env, city.root]
        SCNTransaction.begin(); SCNTransaction.animationDuration = BoardWindow.testMode ? 0 : Self.cutFade
        for n in ground {
            if u { n.opacity = 0 } else { n.isHidden = false; n.opacity = 1 }
        }
        SCNTransaction.completionBlock = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.underground else { return }
                    for n in ground where n.opacity == 0 { n.isHidden = true }
                }
            }
        }
        SCNTransaction.commit()
        cutSig = ""; lodDirty = true      // B1 的牆、玻璃馬上套 cutaway
        applyLights()          // HDR／泛光跟著切
        if Self.trace { print("office underground", u); fflush(stdout) }
        return true
    }

    /// 霧距＝鏡頭到轉軸距離 ×1.3 → ×2.6（至少 60 → 230）：大樓、城市本體清楚，大地坪邊緣淡進地平線。
    /// zFar 跟著霧走（霧還沒蓋滿就被切掉會露出一條硬邊）；zNear 鏡頭遠時拉大（深度精度，地坪疊層不閃）。只在鏡頭停下時算
    private var fogDist: Float = -1
    private func updateFog(dist d: Float, near: Float) {
        camera.camera!.zNear = Double(min(max(d * 0.02, 1), 4, max(near * 0.5, 0.15)))   // 大樓比 zNear 近就會被切掉：最近距離的一半為上限
        guard abs(d - fogDist) > max(1, fogDist * 0.04) else { return }
        fogDist = d
        weatherFX.size(dist: d)
        let start = max(d * 1.3, 60), end = max(d * 2.6, 230)
        scene.fogStartDistance = CGFloat(start); scene.fogEndDistance = CGFloat(end)
        camera.camera!.zFar = Double(max(500, end * 1.15))
    }

    /// 面向鏡頭的實心牆淡掉不畫（玻璃不藏：10-25 Kang「玻璃不遮擋，不用跟著鏡頭角度消失」），其他照常；門牌搬到離鏡頭最遠的那面牆（規範 §3.6）
    private func applyCutaway(camera p: SCNVector3) -> Bool {
        var v = SIMD2<Float>(Float(p.x), Float(p.z))
        let len = simd_length(v)
        v = len < 0.1 ? SIMD2(0, 1) : v / len
        let facing = TowerModules.normals.map { simd_dot($0, v) > Self.cutDot } + coreFacades.map { simd_dot($0.n, v) > $0.cut }
        let far = TowerModules.normals.indices.min { simd_dot(TowerModules.normals[$0], v) < simd_dot(TowerModules.normals[$1], v) } ?? 0
        let sig = facing.map { $0 ? "1" : "0" }.joined() + "|\(far)"
        guard sig != cutSig else { return false }
        cutSig = sig; cutV = v; cutFar = far
        // 10-20 第 4 棒：原本牆淡到 0.06 還是每面都畫（透明排序、多 draw call，近看像一層霧）⇒ 照規範整面不畫：
        // 0.25 秒淡到 0，淡完設 isHidden（真的不送進渲染）；要顯示的先取消 isHidden 再淡回 1
        SCNTransaction.begin(); SCNTransaction.animationDuration = BoardWindow.testMode ? 0 : Self.cutFade
        var all: [SCNNode] = []
        func set(_ f: Facade) {
            let on = !f.glass && simd_dot(f.n, v) > f.cut      // 10-25 Kang：玻璃不擋視線，不跟著鏡頭藏
            if on { if !f.node.isHidden { f.node.opacity = 0 } } else { f.node.isHidden = false; f.node.opacity = 1 }
            all.append(f.node)
        }
        for m in modules.values {
            m.parts.facades.forEach(set)
            placePlate(m.parts, far: far)
        }
        coreFacades.forEach(set)
        basement.facades.forEach(set)
        let sigNow = sig
        SCNTransaction.completionBlock = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.cutSig == sigNow else { return }
                    for n in all where n.opacity == 0 && !n.isHidden { n.isHidden = true }
                }
            }
        }
        SCNTransaction.commit()
        return true
    }

    /// 新建（重建）的樓層／核心：直接套用目前的 cutaway（不淡出；10-20 第 4 棒：原本新樓層先整面玻璃、等下次鏡頭停下才藏，重建時會閃一下）
    private var cutV: SIMD2<Float>?, cutFar = 0
    private func cutNow(_ p: ModuleParts) {
        cutNow(facades: p.facades)
        if cutV != nil { placePlate(p, far: cutFar) }
    }
    private func cutNow(facades: [Facade]) {
        guard let v = cutV else { return }
        for f in facades { let on = !f.glass && simd_dot(f.n, v) > f.cut; f.node.opacity = on ? 0 : 1; f.node.isHidden = on }
    }

    /// 門牌貼在哪面牆：0 後、1 前（內側）、2 左、3 右；不能貼的牆就留在後牆
    private func placePlate(_ p: ModuleParts, far: Int) {
        guard let plate = p.plate else { return }
        let w = Float(p.plateW), y = Float(p.plateY), inset: Float = 0.17
        if p.outsidePlate {
            // 閒置薄層只有 0.9 高：後牆會被上一層樓板擋住 ⇒ 門牌貼在靠鏡頭那一面、朝外
            if far == 1 { plate.simdPosition = SIMD3(w / 2, y, TD.zB - 0.02); plate.eulerAngles.y = .pi }
            else { plate.simdPosition = SIMD3(-w / 2, y, TD.zF + 0.02); plate.eulerAngles.y = 0 }
            return
        }
        let wall = p.plateWalls.contains(far) ? far : 0
        switch wall {
        case 1: plate.simdPosition = SIMD3(TD.W / 2 - 0.3, y, TD.zF - inset); plate.eulerAngles.y = .pi
        case 2: plate.simdPosition = SIMD3(-TD.W / 2 + inset, y, min(TD.zF - 0.3, w / 2)); plate.eulerAngles.y = .pi / 2
        case 3: plate.simdPosition = SIMD3(TD.W / 2 - inset, y, -min(TD.zF - 0.3, w / 2)); plate.eulerAngles.y = -.pi / 2
        default: plate.simdPosition = SIMD3(-TD.W / 2 + 0.3, y, TD.backZ + 0.02); plate.eulerAngles.y = 0
        }
    }

    /// 夜晚 omni：大廳 1、頂樓 1、每個專案樓層 1（只改位置；不夠才新增，多的藏起來）；白天全關。
    /// 10-25 Kang：原本只有離鏡頭焦點最近的 4 層有燈 ⇒ 整棟看起來只有中間一段開燈；改材質自發光又太亮、牆地同色、外牆也亮
    /// ⇒ 每層一盞真的燈：天花板下、樓層中央，衰減 1→7.5 公尺（遠角落、上下層只吃到一點），只照大樓（第 0 位元：城市、B1 不受影響）。
    /// 外牆的外側面背對燈 ⇒ 不會亮；牆、地坪受光角度不同 ⇒ 自然有深淺
    private func assignOmni() {
        guard omniDirty else { return }
        omniDirty = false
        guard VoxMat.lamps > 0.001 else { omni.forEach { $0.isHidden = true }; return }
        var spots: [(SCNVector3, Double, CGFloat)] = []     // 位置、強度倍數、衰減終點
        if let l = modules["lobby"] { spots.append((SCNVector3(0.3, l.parts.node.position.y + 3.0, 0.5), Self.lobbyOmni / 700, 11)) }
        if let r = modules["roof"] { spots.append((SCNVector3(-0.5, r.parts.node.position.y + 2.0, 0.7), 1, 11)) }
        var masks: [Int] = spots.map { _ in 1 }          // 大廳、頂樓的燈照第 0 位元（照舊）
        if Self.legacyNight {                             // 測試：舊版夜晚（離鏡頭焦點最近 4 層各一盞、不分層）＝量測的「修前」
            let ys: [CGFloat] = tower.projectFloors.compactMap { f in modules[f.id].map { $0.parts.node.position.y } }
            for y in ys.sorted(by: { abs($0 + 1.4 - focusY) < abs($1 + 1.4 - focusY) }).prefix(4) {
                spots.append((SCNVector3(0.1, y + CGFloat(TD.room + TD.clear) - 0.35, 0.5), 1, 11)); masks.append(~OfficeBasement.mask)
            }
        }
        for (i, f) in (Self.legacyNight ? [] : tower.projectFloors).enumerated() {
            guard let m = modules[f.id] else { continue }
            let bit = Self.floorLightBit(i)
            m.parts.node.enumerateHierarchy { n, _ in
                if n.geometry != nil { n.categoryBitMask = (n.categoryBitMask & ~Self.floorLightBits) | bit }
            }
            for g in m.parts.facades where g.glass {      // 玻璃不吃室內燈（不然整片玻璃被從裡面照亮）
                g.node.enumerateHierarchy { n, _ in n.categoryBitMask &= ~Self.floorLightBits }
            }
            spots.append((SCNVector3(0.1, m.parts.node.position.y + CGFloat(TD.room + TD.clear) - 0.35, CGFloat(TD.zC) + 0.4), Self.floorOmni / 700, Self.floorRange))
            masks.append(bit)
        }
        while omni.count < spots.count {
            let l = SCNNode(); l.light = SCNLight(); l.light!.type = .omni
            l.light!.color = VoxMat.color(TP.LT1)
            l.light!.attenuationStartDistance = 1
            l.light!.categoryBitMask = 1                         // 只照大樓室內（B1、城市不受影響）
            l.isHidden = true
            world.addChildNode(l); omni.append(l)
        }
        for (i, o) in omni.enumerated() {
            guard i < spots.count else { o.isHidden = true; continue }
            o.position = spots[i].0; o.isHidden = false
            o.light!.intensity = omniBase * spots[i].1
            o.light!.attenuationEndDistance = spots[i].2
            o.light!.categoryBitMask = masks[i]
        }
        if Self.trace { print("office omni", spots.count, "盞 base=\(Int(omniBase)) floors=\(tower.projectFloors.count) modules=\(modules.count)"); fflush(stdout) }
    }

    // MARK: 取景

    private var framedOnce = false
    /// 測試：SHOWORK_OFFICE_AZIMUTH／SHOWORK_OFFICE_ELEVATION（度）換預設取景角度（轉到側面看透明牆）
    /// 畫面風格（10-22）：微縮模型改用等角視角（方位 40°、俯角 30°）
    static var style: OfficeStyle = .voxel
    static var azimuth: CGFloat { style == .diorama ? 35 : baseAzimuth }
    static var elevation: CGFloat { style == .diorama ? 15 : baseElevation }   // 30° 時上一層樓板會蓋住下一層的人（10-22 實測）
    static let baseAzimuth: CGFloat = (BoardWindow.testMode ? ProcessInfo.processInfo.environment["SHOWORK_OFFICE_AZIMUTH"].flatMap { Double($0) } : nil).map { CGFloat($0) } ?? 16
    static let baseElevation: CGFloat = (BoardWindow.testMode ? ProcessInfo.processInfo.environment["SHOWORK_OFFICE_ELEVATION"].flatMap { Double($0) } : nil).map { CGFloat($0) } ?? 12

    /// 保全等級（取景要不要把大廳框進來：注意以上才框）
    var guardLevel: GuardLevel = .normal

    /// 預設取景的上下範圍（10-20 UI/UX 優化 §2.2 D）：有人的專案樓層（最低那層樓板到最高那層天花）上下各多 0.4 層；
    /// 大廳只在保全「注意」以上才框進來；頂樓只露 0.5 層（看得到樹）；閒置薄層一律在框外。都沒人 ⇒ 整棟
    func frameRange() -> (lo: Double, hi: Double) {
        let occupied = tower.projectFloors.filter { $0.seats > 0 }
        let floors = occupied.isEmpty ? tower.projectFloors : occupied
        guard let first = floors.first, let last = floors.last else { return (-0.2, tower.totalHeight + 0.8) }
        let pad = 0.4 * TowerSpec.floorHeight
        var lo = first.y - pad, hi = last.y + last.height + pad
        // 頂樓：10-20 第 4 棒評審「RF 被切一半」⇒ 預設鏡頭只露頂樓樓板（一條線），不露半截樹；要看頂樓點索引列的 RF
        if let roof = tower.floor(id: "roof"), abs(roof.y - (last.y + last.height)) < 0.01 { hi = roof.y + TowerSpec.slab + 0.15 }
        if guardLevel != .normal, let lobby = tower.floor(id: "lobby") { lo = min(lo, lobby.y + 0.4 * lobby.height) }   // 只框到保全頭頂＋名牌（10-20 第 4 棒：0.3 → 0.4，專案樓層每層多 6 pt）
        // 閒置薄層緊貼在最低那層專案樓層下面：多框的 0.4 層不要讓它露出太多（≤ 薄層一半）
        //（保全「注意」以上要框大廳時不套用：10-20 第 4 棒發現這條會把大廳整個推出畫面，保全的名牌就沒地方畫）
        if guardLevel == .normal, let idle = tower.floors.first(where: { $0.kind == .idle }), idle.y + idle.height <= first.y + 0.01 {
            lo = max(lo, idle.y + idle.height * 0.5)
        }
        return (lo, hi)
    }

    /// 從右前方、略高一點看「有人的樓層」（方位 16°、仰角 12°；10-20 UI/UX 優化 §2.2 D）
    func frameCamera(_ v: SCNView) {
        let aspect = Double(max(0.4, v.bounds.width / max(1, v.bounds.height)))
        let (lo, hi) = frameRange()
        // 寬度是瓶頸（樓層 12 公尺寬、從右前方 16° 看）：框「正面＋後牆前 0.8 公尺」就好，右後角那一點點後牆被切掉沒關係（每層多 8% 高）
        // 10-22 大樓加深後仍框「前緣往後 4.8 公尺」（＝加深前的範圍）：預設視角、旋轉中心都跟原本一樣（Kang：視角變得很誇張）
        let (dist, t) = Self.fit(lo: SIMD3(-TD.Wd / 2, lo, TD.zFd - 4.8), hi: SIMD3(TD.Wd / 2, hi, TD.zFd), aspect: aspect,
                                 az: Double(Self.azimuth) * .pi / 180, el: Double(Self.elevation) * .pi / 180, margin: 1.02)
        place(v, target: t, dist: dist, az: Double(Self.azimuth), el: Double(Self.elevation))
    }

    /// 點左側索引列的樓層：鏡頭拉近到這層（10-20 第 4 棒：原本框整層 12 公尺寬，直式視窗等於沒拉近）。
    /// 框「這層的人＋左右各一段」：直式視窗（960）約 4–5 公尺寬、橫式（1600）約 8 公尺寬，讓這層高度佔畫面 ≥ 45%
    @discardableResult
    func frameFloor(_ id: String, _ v: SCNView) -> Bool {
        guard let f = tower.floor(id: id), let m = modules[id] else { return false }
        let y = Double(m.parts.node.position.y)
        let aspect = Double(max(0.4, v.bounds.width / max(1, v.bounds.height)))
        let h = max(f.height, 1.2)
        let xs = persons.values.filter { $0.floor == id }.map { Double($0.node.position.x) }
        let cx = xs.isEmpty ? 0.1 : (xs.min()! + xs.max()!) / 2
        // 可看的寬度：高度佔 50% 時，畫面寬對應幾公尺；至少把這層的人都框進來
        // 閒置薄層只有 0.9 公尺高：照高度算會拉到只剩 1.5 公尺寬 ⇒ 一律框整層寬（名字整排看得到）
        let half = f.kind == .idle ? TD.Wd / 2 : min(TD.Wd / 2, max(h / 0.5 * aspect * 0.42, xs.isEmpty ? 0 : (xs.max()! - xs.min()!) / 2 + 1.2))
        let c = min(max(cx, -TD.Wd / 2 + half), TD.Wd / 2 - half)
        let (dist, t) = Self.fit(lo: SIMD3(c - half, y + Double(TD.room) - 0.05, -0.4), hi: SIMD3(c + half, y + h, TD.zFd), aspect: aspect,
                                 az: Double(Self.azimuth) * .pi / 180, el: Double(Self.elevation) * .pi / 180, margin: 0.98)
        place(v, target: t, dist: dist, az: Double(Self.azimuth), el: Double(Self.elevation))
        return true
    }

    /// 測試：SHOWORK_OFFICE_CAM 定鏡頭
    func placeTest(_ v: SCNView, target t: SIMD3<Double>, dist: Double, az: Double, el: Double) { place(v, target: t, dist: dist, az: az, el: el) }

    private func place(_ v: SCNView, target t: SIMD3<Double>, dist: Double, az: Double, el: Double) {
        let target = SCNVector3(t.x, t.y, t.z)
        let d = Self.dir(az: az * .pi / 180, el: el * .pi / 180)
        // 第一次取景直接定位（不從原點飛過來）；測試視窗在螢幕外不會推進動畫，也一律直接定位
        let first = !framedOnce; framedOnce = true
        // 10-23：滑鼠拖過之後 SceneKit 改用自己的 kSCNFreeViewCameraName 鏡頭 ⇒ 這裡移 builder.camera 畫面不會動。取景前先切回來（雨一起搬回）
        if let pov = v.pointOfView, pov !== camera { camera.transform = pov.presentation.transform; v.pointOfView = camera; weatherFX.follow(camera) }   // 先對齊目前視角，不跳
        SCNTransaction.begin(); SCNTransaction.animationDuration = first || BoardWindow.testMode ? 0 : 0.5
        camera.position = SCNVector3(target.x + d.x * dist, target.y + d.y * dist, target.z + d.z * dist)
        camera.look(at: target, up: SCNVector3(0, 1, 0), localFront: SCNNode.localFront)   // 10-21 稽核：look(at:) 沿用節點舊的 up，從側面取景會歪一邊
        SCNTransaction.commit()
        v.defaultCameraController.target = target
        if let c = camera.camera, c.usesOrthographicProjection { c.orthographicScale = OfficeStyleFX.orthoScale(dist: dist) }
        lodDirty = true; focusY = target.y; omniDirty = true
    }

    /// 樓層在畫面上的高度（點）與樓板寬佔畫面寬的比例（PROBE 量驗收用）
    func floorPixels(_ v: SCNView) -> [(String, Double, Double)] {
        tower.floors.compactMap { f in
            guard let m = modules[f.id] else { return nil }
            let y = m.parts.node.position.y
            let a = v.projectPoint(SCNVector3(0, y, CGFloat(TD.zF))), b = v.projectPoint(SCNVector3(0, y + CGFloat(f.height), CGFloat(TD.zF)))
            let l = v.projectPoint(SCNVector3(CGFloat(-TD.W / 2), y, CGFloat(TD.zF))), r = v.projectPoint(SCNVector3(CGFloat(TD.W / 2), y, CGFloat(TD.zF)))
            return (f.floorNo.isEmpty ? f.id : f.floorNo, Double(abs(b.y - a.y)), Double(abs(r.x - l.x) / max(1, v.bounds.width)))
        }
    }

    static func dir(az: Double, el: Double) -> SIMD3<Double> { SIMD3(cos(el) * sin(az), sin(el), cos(el) * cos(az)) }

    /// 取景：鏡頭從方位 az、仰角 el 看向 target，找最近的距離讓整個外框（8 個角）都進畫面，並把投影置中。
    static func fit(lo: SIMD3<Double>, hi: SIMD3<Double>, aspect: Double, az: Double, el: Double, fov: Double = 34, margin: Double = 0.92) -> (Double, SIMD3<Double>) {
        let ty = tan(fov / 2 * .pi / 180) * margin, tx = ty * aspect
        let d = dir(az: az, el: el), f = -d
        let r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0))), u = simd_cross(r, f)
        var pts: [SIMD3<Double>] = []
        for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] { pts.append(SIMD3(x, y, z)) } } }
        func extent(_ D: Double, _ T: SIMD3<Double>) -> (ok: Bool, x0: Double, x1: Double, y0: Double, y1: Double) {
            let C = T + d * D
            var ok = true, x0 = Double.infinity, x1 = -Double.infinity, y0 = Double.infinity, y1 = -Double.infinity
            for p in pts {
                let v = p - C, depth = simd_dot(v, f)
                guard depth > 0.1 else { ok = false; continue }
                let px = simd_dot(v, r) / depth, py = simd_dot(v, u) / depth
                x0 = min(x0, px); x1 = max(x1, px); y0 = min(y0, py); y1 = max(y1, py)
            }
            return (ok && x0 >= -tx && x1 <= tx && y0 >= -ty && y1 <= ty, x0, x1, y0, y1)
        }
        func search(_ T: SIMD3<Double>) -> Double {
            var a = 4.0, b = 900.0
            for _ in 0..<40 { let m = (a + b) / 2; if extent(m, T).ok { b = m } else { a = m } }
            return b
        }
        var T = (lo + hi) / 2, D = search(T)
        for _ in 0..<4 {
            let e = extent(D, T)
            T += r * ((e.x0 + e.x1) / 2 * D) + u * ((e.y0 + e.y1) / 2 * D)
            D = search(T)
        }
        return (max(D, 8), T)
    }

    // MARK: 量測

    /// 大樓由下往上（PROBE 印出來比）
    func towerLayout() -> String {
        tower.floors.map { f in String(format: "%@%@@%.1f", f.floorNo.isEmpty ? "" : f.floorNo + ":", f.project ?? f.id, f.y) }.joined(separator: " ")
    }

    /// SHOWORK_OFFICE_TRACE=1 ⇒ 印出每次重建（看資料變動時的重建頻率）
    static let trace = ProcessInfo.processInfo.environment["SHOWORK_OFFICE_TRACE"] != nil

    /// 節點數、估計的 draw call（看得到的 geometry element 數；opacity 0 的算看不到）、燈數、材質快取數；另附每層的 draw call
    func stats() -> String {
        var nodes = 0, calls = 0, lights = 0
        func walk(_ n: SCNNode, hidden: Bool) -> Int {
            nodes += 1
            let h = hidden || n.isHidden || n.opacity == 0
            var c = 0
            if !h, let g = n.geometry { c += g.elements.count }
            if !h, n.light != nil { lights += 1 }
            for ch in n.childNodes { c += walk(ch, hidden: h) }
            return c
        }
        calls = walk(scene.rootNode, hidden: false)
        var per: [String] = []
        var items: [String] = []
        for f in tower.floors {
            guard let m = modules[f.id] else { continue }
            let tag = f.floorNo.isEmpty ? f.id : f.floorNo
            per.append("\(tag)=\(walkCount(m.parts.node))")
            if f.kind == .project { items.append("\(tag)=\(m.parts.items)件/前帶\(m.parts.front)/桌面\(m.parts.deskItems)/\(decor[(f.project ?? "").lowercased()]?.theme.rawValue ?? "general")") }
        }
        return "nodes=\(nodes) drawcalls≈\(calls) city=\(walkCount(city.root)) lights=\(lights) materials=\(VoxMat.count) people=\(persons.count) boards=\(boards.count)/visible \(boards.values.filter { !$0.node.isHidden }.count)/drawn \(boardsDrawn)/stale \(boardStale.count) floors[\(per.joined(separator: " "))] items[\(items.joined(separator: " "))]"
    }
    private func walkCount(_ n: SCNNode) -> Int {
        if n.isHidden || n.opacity == 0 { return 0 }
        return (n.geometry?.elements.count ?? 0) + n.childNodes.reduce(0) { $0 + walkCount($1) }
    }

    /// 看板內容沿用第二版（每人📈🎯🧠🔤＋一句回報），外框換成像素木框
    static func boardImage(_ i: Island, color: NSColor) -> NSImage {
        let people = Array(i.people.prefix(maxPeople))
        let W: CGFloat = 560, rowH: CGFloat = 70, headH: CGFloat = 64, fr: CGFloat = 14
        let H = headH + CGFloat(max(people.count, 1)) * rowH + (i.queued > 0 ? 34 : 0) + 14 + fr
        let accent = color
        return NSImage(size: NSSize(width: W, height: H), flipped: true) { r in
            // 木框：一格 7 點的深淺木頭
            var rng = PixelTex.RNG(s: 99)
            let cell: CGFloat = 7
            for y in stride(from: CGFloat(0), to: H, by: cell) {
                for x in stride(from: CGFloat(0), to: W, by: cell) where x < fr || x >= W - fr || y < fr || y >= H - fr {
                    let k = 0.78 + rng.next() * 0.3
                    NSColor(srgbRed: 0x7a / 255 * k, green: 0x4e / 255 * k, blue: 0x2d / 255 * k, alpha: 1).setFill()
                    NSRect(x: x, y: y, width: cell, height: cell).fill()
                }
            }
            NSColor(srgbRed: 0.09, green: 0.075, blue: 0.065, alpha: 0.96).setFill()
            NSRect(x: fr, y: fr, width: W - fr * 2, height: H - fr * 2).fill()
            // 標題列（部門色）
            accent.blended(withFraction: 0.25, of: .black)?.setFill()
            NSRect(x: fr, y: fr, width: W - fr * 2, height: headH - fr - 4).fill()
            draw(i.project, at: NSPoint(x: fr + 12, y: fr + 8), size: 28, weight: .heavy, color: .white, width: W * 0.58)
            let counts = [(Mood.waiting, "等你"), (.stuck, "卡住"), (.finished, "做完"), (.working, "進行"), (.idle, "休息")]
                .filter { i.count($0.0) > 0 }.map { "\(i.count($0.0)) \($0.1)" }.joined(separator: "  ")
            draw(counts.isEmpty ? "全員休息" : counts, at: NSPoint(x: W * 0.6, y: fr + 14), size: 19, weight: .bold, color: .white, width: W * 0.4 - fr - 6)
            for (n, p) in people.enumerated() {
                let y = headH + CGFloat(n) * rowH
                let c = p.card, tint = KuboArt.tint(p.mood)
                tint.setFill(); NSRect(x: fr + 10, y: y + 12, width: 14, height: 14).fill()       // 方塊點（像素風）
                draw(c.title, at: NSPoint(x: fr + 32, y: y + 4), size: 22, weight: .bold, color: .white, width: W * 0.44 - fr - 36)
                let prog = c.report?.progress ?? c.review?.progress, conf = c.report?.confidence ?? c.review?.confidence
                let ctx = c.ctx.map { Int($0.percent) }
                let tok = c.tokens.map { "  🔤\(tokenShort($0.total))" } ?? ""
                let g = "📈\(prog.map { "\($0)%" } ?? "—")  🎯\(conf.map { "\($0)%" } ?? "—")  🧠\(ctx.map { "\($0)%" } ?? "—")" + tok
                let ctxHot = (c.ctx?.percent ?? 0) >= ContextGuard.threshold
                draw(g, at: NSPoint(x: W * 0.44, y: y + 7), size: 17, weight: .semibold,
                     color: ctxHot ? NSColor.systemRed : NSColor(white: 0.92, alpha: 1), width: W * 0.56 - fr - 6)
                if let prog {
                    NSColor(white: 1, alpha: 0.12).setFill()
                    NSRect(x: fr + 32, y: y + 56, width: W - fr * 2 - 44, height: 4).fill()
                    tint.setFill()
                    NSRect(x: fr + 32, y: y + 56, width: (W - fr * 2 - 44) * CGFloat(min(100, max(0, prog))) / 100, height: 4).fill()
                }
                draw(officeLine(c), at: NSPoint(x: fr + 32, y: y + 32), size: 17, weight: .regular,
                     color: p.mood == .waiting ? NSColor(srgbRed: 1, green: 0.6, blue: 0.6, alpha: 1)
                        : c.blockedReason != nil ? NSColor(srgbRed: 1, green: 0.75, blue: 0.45, alpha: 1) : NSColor(white: 0.75, alpha: 1), width: W - fr * 2 - 44)
            }
            if people.isEmpty {
                draw("沒有人在這裡", at: NSPoint(x: fr + 12, y: headH + 18), size: 20, weight: .regular, color: NSColor(white: 0.6, alpha: 1), width: W - fr * 2 - 24)
            }
            if i.queued > 0 {
                draw("📥 排隊中 \(i.queued) 則", at: NSPoint(x: fr + 12, y: H - fr - 40), size: 18, weight: .medium, color: NSColor(white: 0.78, alpha: 1), width: W - fr * 2 - 24)
            }
            return true
        }
    }

    // MARK: 共用的小東西

    /// NSImage → 高解析度 CGImage（直接給 SceneKit 會用 1x，字糊掉）
    static func raster(_ img: NSImage, scale: CGFloat) -> CGImage? {
        let W = Int(img.size.width * scale), H = Int(img.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: img.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// 單行、超出寬度用「…」截掉
    static func draw(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, width: CGFloat) {
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: ps]
        (s.replacingOccurrences(of: "\n", with: " ") as NSString).draw(in: NSRect(x: p.x, y: p.y, width: width, height: size * 1.35), withAttributes: a)
    }

    /// 頭上的小字牌／符號：方角底（像素風）、永遠面向你
    static func label(_ s: String, size: CGFloat, color: NSColor, bg: NSColor, bold: Bool = false) -> SCNNode {
        let f = NSFont.systemFont(ofSize: size, weight: bold ? .heavy : .semibold)
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
        let ts = (s as NSString).size(withAttributes: a)
        let W = ceil(ts.width + size * 0.9), H = ceil(ts.height + size * 0.35)
        let img = NSImage(size: NSSize(width: W, height: H), flipped: true) { r in
            bg.setFill(); NSBezierPath(roundedRect: r, xRadius: H * 0.12, yRadius: H * 0.12).fill()
            (s as NSString).draw(at: NSPoint(x: (W - ts.width) / 2, y: (H - ts.height) / 2), withAttributes: a)
            return true
        }
        let scale: CGFloat = 0.0085     // 每點幾公尺
        let plane = SCNPlane(width: W * scale * (26 / size).squareRoot(), height: H * scale * (26 / size).squareRoot())
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = raster(img, scale: 2.5); m.isDoubleSided = true
        m.writesToDepthBuffer = false; m.readsFromDepthBuffer = true
        plane.firstMaterial = m
        let n = SCNNode(geometry: plane); n.renderingOrder = 10
        n.constraints = [SCNBillboardConstraint()]
        return n
    }
}

func + (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z) }
