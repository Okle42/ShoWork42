import AppKit
import Combine
import SceneKit
import simd
import ShoWorkCore

// 小島村莊（11-12）：3D 戰情中心的預設場景（大樓留著，右上角選單「場景」可切回）。
//   原創的溫馨小島，沿用方塊（voxel）風：鎮公所（隊長）、自家店屋（奶油／橄欖／金、門口一台休旅車，招牌＝本機設定的店名）、
//   公司小屋（Okle42，黑底金色 42，沿用大樓招牌材質）、個人小攤、廣場噴水池、一圈小家（離線的人回家：門關燈暗）。
//   系統狀態換成島上的東西：風車＝這台 Mac 的溫度、水井＝AI 額度（水位）、熱氣球＝iCloud、倉庫小屋＝內建碟；平常不寫數字，到門檻才冒警告牌。
//   主人＝一隻小狗：有人等你回答就跑過去站在旁邊（點牠或那位島民＝打開原本的回答卡）；點地面牠走過去；沒事在廣場附近晃。
// 歸屬規則、座標、找路都在 ShoWorkCore/Village.swift（有測試）；角色沿用大樓的 Kubo（OfficeBuilder.makePerson）。
// 省電：靜態東西合併成幾個 mesh；只有走路、跳一下時才渲染（跟大樓同一套 playFor），閒晃每 10–16 秒才排一次、視窗看不到或機器熱就不排。

/// 島民記憶（離線的人還有家）＋本機設定快取。示範資料、測試視窗不寫回你的設定
@MainActor
enum VillageStore {
    static let key = "office.village"
    static var persist: Bool { OfficeDemo.mode == nil && !BoardWindow.testMode }
    private(set) static var memory: VillageMemory = persist ? VillageMemory.decode(OfficePrefs().store.data(forKey: key)) : VillageMemory()
    private static var savedAt = Date.distantPast
    private static var cfg: (VillageConfig?, Date) = (nil, .distantPast)

    /// local.json 的 village（30 秒讀一次；檔很小）
    static var config: VillageConfig? {
        if Date().timeIntervalSince(cfg.1) > 30 { cfg = (LocalConfig.current.village, Date()) }
        return cfg.0
    }

    /// 點車時的字（車主寫在本機設定）
    static func carText(_ id: String) -> String? {
        let cars = VillageCars.list(config)
        guard id.hasPrefix("car:"), let i = Int(id.dropFirst(4)), i < cars.count else { return nil }
        let c = cars[i]
        return c.owner.map { "🚗 \($0) 的車（\(c.model.title)）" } ?? "🚗 \(c.model.title)"
    }

    static func plan(_ cards: [BoardCard], now: Date = Date()) -> VillagePlan {
        Village.plan(cards: cards, memory: memory, config: config, now: now)
    }

    /// 記下活著的人；名單或專案變了就存，沒變最多 10 分鐘存一次（更新最後看到的時間）
    static func remember(_ cards: [BoardCard], now: Date = Date()) {
        let m = Village.remember(memory, cards: cards, now: now)
        let changed = m.people.mapValues(\.project) != memory.people.mapValues(\.project)
        memory = m
        guard persist, changed || now.timeIntervalSince(savedAt) > 600 else { return }
        savedAt = now
        if let d = m.encoded() { OfficePrefs().store.set(d, forKey: key) }
    }
}

/// 學校資料（研究資料夾；只讀）：每 60 秒在背景數一次 .md，變了才發布（11-12 第三輪）
@MainActor
final class SchoolStore: ObservableObject {
    static let shared = SchoolStore()
    @Published private(set) var state = SchoolState()
    private var timer: Timer?
    private var busy = false

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { SchoolStore.shared.refresh() } }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let cfg = VillageStore.config?.school
        DispatchQueue.global(qos: .utility).async {
            let s = SchoolScan.scan(cfg)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    if s != self.state { self.state = s }
                }
            }
        }
    }
}

/// 場景設定：小島（預設）／大樓
enum OfficeScene3D: String, CaseIterable {
    case island, tower
    static let key = "office.scene"
    var title: String { self == .island ? "小島村莊" : "大樓" }
}

@MainActor
final class VillageBuilder {
    let root = SCNNode()
    weak var owner: OfficeBuilder?
    /// 走路、跳一下這種會自己停的動畫：請 SCNView 播幾秒
    var onPlay: ((TimeInterval) -> Void)?
    /// 現在可以播動畫嗎（視窗看得到、不是測試視窗、沒開減少動態、機器不熱）
    var canAnimate: () -> Bool = { false }

    private(set) var plan = VillagePlan()
    private var built = false
    private var lamps: [SCNNode] = []

    struct Person { var node: SCNNode; var look: String; var goal: VPoint; var face: Double; var spot: VillageSpot; var resident: VillageResident
        var seated = false; var isl: Islander }
    private var seatOf: [String: Int] = [:]
    private var persons: [String: Person] = [:]
    private var homeNodes: [SCNNode] = []
    private var homeSig = ""
    private var stallNode: SCNNode?
    private var stallSig = ""
    private var wellNode: SCNNode?
    private var schoolNode: SCNNode?
    private var schoolSub: AnyCancellable?
    private var schoolTotal: Int?
    private var seaNode: SCNNode?
    private var seaTide = 0.6
    private var wellSig = ""
    private var facilityIds: [String: String] = [:]      // 設施種類 → 城市 id（點了開哪張細節卡）
    private var signs: [VillageSign] = []
    private var signAnchors: [String: SCNNode] = [:]
    private var facilityNodes: [String: SCNNode] = [:]   // windmill／well／balloon／warehouse
    private var obstacles = VillageLayout.obstacles(stallCount: 0)

    // 小狗
    private(set) var dog = SCNNode()
    private var dogPos = VillageLayout.plaza
    private var dogGoalId: String?
    private var dogGoal = VillageLayout.plaza
    private var manualUntil = Date.distantPast
    private var ambientStarted = false
    private var transient: TimeInterval = 0
    private func bump(_ s: TimeInterval) { transient = max(transient, s) }

    static let walkSpeed = 2.0, dogSpeed = 3.2
    static let personScale = 1.3
    static let dogRest = VPoint(VillageLayout.plaza.x + 3.4, VillageLayout.plaza.z + 2.2)

    init() {
        root.name = "village"
    }

    // MARK: 靜態場景（第一次切到小島才蓋）

    func buildIfNeeded() {
        guard !built else { return }
        built = true
        let mask = 1 | OfficeBuilder.outdoorMask
        func add(_ n: SCNNode, pick: Bool = false) {
            n.enumerateHierarchy { c, _ in c.categoryBitMask |= mask }
            if pick { OfficeBuilder.pickable(n) }
            root.addChildNode(n)
        }
        let sea = VillageArt.sea()
        sea.position.y = CGFloat(VillageArt.seaOffset(seaTide))
        seaNode = sea
        add(sea, pick: true)
        add(VillageArt.terrain())
        add(VillageArt.company(), pick: true)
        for (k, n) in [("windmill", VillageArt.windmill()), ("balloon", VillageArt.balloon()), ("warehouse", VillageArt.diskShed())] {
            facilityNodes[k] = n; add(n, pick: true)
        }
        // 學校（11-12 第三輪：原本倉庫那間）：研究資料夾一變就更新；有新筆記冒一顆星星
        let school = VillageArt.school()
        add(school, pick: true)
        schoolNode = school
        SchoolStore.shared.start()
        schoolSub = SchoolStore.shared.$state.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] st in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let old = self.schoolTotal, st.total > old { self.onPlay?(self.flashSchool()) }
                self.schoolTotal = st.total
            }
        }
        // 夜晚：廣場、店屋、公司小屋三盞暖燈（強度跟著天色／停電，setLamps）
        for p in [SCNVector3(0, 4.5, 3), SCNVector3(-5, 4.2, -5), SCNVector3(12, 4.2, 1), SCNVector3(0, 4.5, -5.5)] {
            let l = SCNNode(); l.light = SCNLight(); l.light!.type = .omni
            l.light!.color = VoxMat.color(0xFFD9A0); l.light!.attenuationStartDistance = 2; l.light!.attenuationEndDistance = 15
            l.position = p; l.isHidden = true
            root.addChildNode(l); lamps.append(l)
        }
        dog = VillageArt.boss()
        dogPos = Self.dogRest
        dog.simdPosition = SIMD3(Float(dogPos.x), 0, Float(dogPos.z))
        root.addChildNode(dog)
    }

    /// 店屋要等知道店名才蓋（本機設定可能改）
    private var shopNode: SCNNode?
    private var shopSig = ""
    private func updateShop(_ name: String) {
        guard name != shopSig else { return }
        shopSig = name
        shopNode?.removeFromParentNode()
        let n = VillageArt.shop(name)
        n.enumerateHierarchy { c, _ in c.categoryBitMask |= 1 | OfficeBuilder.outdoorMask }
        OfficeBuilder.pickable(n)
        root.addChildNode(n); shopNode = n
    }

    /// 夜晚燈（0＝白天、1＝夜晚全亮；已乘停電）
    func setLamps(_ k: CGFloat) {
        for l in lamps { l.isHidden = k < 0.01; l.light!.intensity = 520 * k }
        lampK = k
        setFireLight()
    }

    // MARK: 更新（看板刷新時）

    /// 回傳要播幾秒（走路、跳一下）
    func update(_ islanders: [Islander], animate: Bool, raining: Bool = false, now: Date = Date()) -> TimeInterval {
        buildIfNeeded()
        let cards = islanders.map(\.card)
        VillageStore.remember(cards, now: now)
        let p = VillageStore.plan(cards, now: now)
        let first = persons.isEmpty && plan.residents.isEmpty
        plan = p
        updateShop(p.shopName)
        updateCars(VillageCars.list(VillageStore.config))
        updateStalls(p.stalls)
        updateHomes(p.homes)
        obstacles = VillageLayout.obstacles(stallCount: p.stalls.count)
        let acc = Dictionary(islanders.map { ($0.id, $0.accessory) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        // 營火座位：坐著的人留在原位，新來的坐最小的空位（不要每次有人進出就全部起來換位子）
        let campers = Set(p.residents.filter { $0.spot == .plaza && $0.online }.map(\.id))
        seatOf = seatOf.filter { campers.contains($0.key) }
        for id in campers.sorted() where seatOf[id] == nil {
            let used = Set(seatOf.values)
            seatOf[id] = (0...).first { !used.contains($0) }!
        }
        for r in p.residents where r.spot != .home {
            guard let c = r.card else { continue }
            seen.insert(r.id)
            let wantSeat = r.spot == .plaza
            let canSit = wantSeat && !r.pet          // 小狗不坐坐墩，站在旁邊
            let (goal, face) = wantSeat ? VillageLayout.plazaSpot(seatOf[r.id] ?? 0) : VillageLayout.workSpot(zone: r.zone, stall: r.stall, slot: r.slot)
            let isl = Islander(card: c, mood: r.mood ?? .idle, accessory: acc[r.id] ?? nil)
            let look = "\(isl.mood.rawValue)|\(isl.accessory?.rawValue ?? "")|\(c.activity.rawValue)|\(r.needsAnswer)|\(c.subagents.count)"
            if var old = persons[r.id] {
                let moved = old.spot != r.spot || old.goal.dist(goal) > 0.05
                // 走路時一定站著；到了營火才坐下（走完再換成坐姿）。還在路上的人刷新時不能就地坐下（11-12 實機：走到一半坐在草地上）
                let walking = old.node.action(forKey: "walk") != nil
                let seatNow = canSit && !(moved && animate) && !walking
                if old.look != look || old.seated != seatNow {
                    old.node = replaceNode(old.node, isl, r, seated: seatNow, intro: old.resident.mood != r.mood)
                    old.look = look; old.seated = seatNow
                    // 換外觀會停掉走路：還沒到就接著走
                    if walking && !moved {
                        let t = walk(old.node, to: goal, face: face, speed: Self.walkSpeed, animate: animate)
                        bump(t)
                        if canSit { sitLater(r.id, after: t) }
                    }
                }
                if moved {
                    let t = walk(old.node, to: goal, face: face, speed: Self.walkSpeed, animate: animate)
                    bump(t)
                    if canSit && !seatNow { sitLater(r.id, after: t) }
                    old.goal = goal; old.face = face; old.spot = r.spot
                }
                old.resident = r; old.isl = isl
                persons[r.id] = old
            } else {
                // 剛上線：從自己家門口走出來（第一次載入直接到位）
                let start = !first && animate ? r.home.map(VillageLayout.homeDoor) ?? goal : goal
                let seatNow = canSit && start == goal
                let n = makeNode(isl, r, seated: seatNow, intro: !first)
                root.addChildNode(n)
                n.simdPosition = SIMD3(Float(start.x), 0, Float(start.z)); n.eulerAngles.y = CGFloat(face)
                if start != goal {
                    let t = walk(n, to: goal, face: face, speed: Self.walkSpeed, animate: animate)
                    bump(t)
                    if canSit { sitLater(r.id, after: t) }
                }
                persons[r.id] = Person(node: n, look: look, goal: goal, face: face, spot: r.spot, resident: r, seated: seatNow, isl: isl)
            }
        }
        // 下線的人：走回家門口再消失（不能播就直接拿掉）
        for (id, old) in persons where !seen.contains(id) {
            persons[id] = nil
            let n = old.node
            n.name = "leaving"
            if animate, let h = p.residents.first(where: { $0.name == old.resident.name })?.home ?? old.resident.home {
                let t = walk(n, to: VillageLayout.homeDoor(h), face: VillageLayout.homeFacing(h) + .pi, speed: Self.walkSpeed, animate: true)
                n.runAction(.sequence([.wait(duration: t), .fadeOut(duration: 0.3), .removeFromParentNode()]))
                bump(t + 0.4)
            } else { n.removeFromParentNode() }
        }
        updateDog(animate: animate)
        updateCampfire(stools: max(8, min(20, seatOf.values.max().map { $0 + 1 } ?? 0)), raining: raining)
        if bongHolder.map({ persons[$0]?.spot != .plaza }) ?? true { passBong(puff: false) }
        if !ambientStarted { ambientStarted = true; scheduleAmbient() }
        defer { transient = 0 }
        return transient
    }

    var looping: Bool { persons.values.contains { $0.resident.mood == .working && $0.resident.card?.activity == .editing } }

    /// 畫成小狗的島民（本機設定 petName）：狀態照一般島民，等你回答一樣冒「！」
    private func makePet(_ isl: Islander, _ r: VillageResident) -> SCNNode {
        let n = VillageArt.dog()
        n.name = "p:\(r.id)"
        if r.needsAnswer {
            let bang = VillageArt.bang(); bang.name = "bang"
            bang.position = SCNVector3(0, 2.1, 0); bang.scale = SCNVector3(1.2, 1.2, 1.2)
            n.addChildNode(bang)
            n.childNode(withName: "anchor", recursively: false)?.position.y = 3.3
        }
        if isl.mood == .waiting, !Look.reduceMotion, let b = n.childNode(withName: "body", recursively: false) { b.runAction(OfficeBuilder.hop(0.18, times: 3)); bump(2.0) }
        OfficeBuilder.pickable(n)
        return n
    }

    /// 換外觀（狀態變了、坐下／站起來）：同位置同方向、滑鼠停著的光圈照舊
    private func replaceNode(_ old: SCNNode, _ isl: Islander, _ r: VillageResident, seated: Bool, intro: Bool) -> SCNNode {
        let n = makeNode(isl, r, seated: seated, intro: intro)
        n.position = old.position; n.eulerAngles = old.eulerAngles
        let halo = old.childNode(withName: "halo", recursively: false)?.isHidden ?? true
        n.childNode(withName: "halo", recursively: false)?.isHidden = halo
        if let b = old.childNode(withName: "bong", recursively: true) { b.removeFromParentNode() }
        old.removeAllActions(); old.removeFromParentNode(); root.addChildNode(n)
        if bongHolder == r.id { bongHolder = nil }
        return n
    }

    /// 走到營火後坐下（那時還在營火才坐）
    private func sitLater(_ id: String, after t: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, var p = self.persons[id], p.spot == .plaza, !p.seated, p.node.action(forKey: "walk") == nil else { return }
                p.node = self.replaceNode(p.node, p.isl, p.resident, seated: true, intro: false)
                p.node.simdPosition = SIMD3(Float(p.goal.x), 0, Float(p.goal.z)); p.node.eulerAngles.y = CGFloat(p.face)
                p.seated = true
                self.persons[id] = p
                // 坐下的人是第一位（還沒人拿水煙壺）⇒ 馬上交給他、吸一口（不用等下一次閒晃）
                let t = self.bongHolder == nil && self.canAnimate() ? self.passBong(puff: true) : 0
                self.onPlay?(max(0.2, t))
            }
        }
    }

    private func makeNode(_ isl: Islander, _ r: VillageResident, seated: Bool = false, intro: Bool) -> SCNNode {
        guard let o = owner else { return SCNNode() }
        if r.pet { return makePet(isl, r) }
        let n = o.makePerson(isl, seated: seated, atDesk: false, intro: intro)
        // 島比樓層大很多：島民放大一點，遠看也認得出來（錨點、點擊盒跟著放大）
        let k = CGFloat(Self.personScale)
        for c in n.childNodes where c.name != "anchor" { c.scale = SCNVector3(c.scale.x * k, c.scale.y * k, c.scale.z * k); c.position = SCNVector3(c.position.x * k, c.position.y * k, c.position.z * k) }
        if let a = n.childNode(withName: "anchor", recursively: false) { a.position.y *= k }
        if r.needsAnswer {
            // 頭上冒「！」（紅底白字的方塊驚嘆號）；名牌錨點往上移，名牌不蓋住它
            let top = 0.92 * OfficeBuilder.kuboScale
            let bang = VillageArt.bang()
            let k = CGFloat(Self.personScale)
            bang.position = SCNVector3(0, (top + 0.35) * k, 0)
            bang.scale = SCNVector3(k, k, k)
            bang.name = "bang"
            n.addChildNode(bang)
            n.childNode(withName: "anchor", recursively: false)?.position.y = (top + 1.25) * k
            OfficeBuilder.pickable(n)
        }
        return n
    }

    // MARK: 走路

    /// 沿著找到的路走過去（腳前後擺）、最後轉向 face；回傳要幾秒。不能播＝直接到位
    @discardableResult
    private func walk(_ n: SCNNode, to goal: VPoint, face: Double, speed: Double, animate: Bool) -> TimeInterval {
        n.removeAction(forKey: "walk")
        let legs = ["legL", "legR", "legFL", "legFR", "legBL", "legBR"].compactMap { n.childNode(withName: $0, recursively: true) }
        for l in legs { l.removeAction(forKey: "swing"); l.eulerAngles.x = 0 }
        let from = VPoint(Double(n.position.x), Double(n.position.z))
        guard animate, from.dist(goal) > 0.05 else {
            n.simdPosition = SIMD3(Float(goal.x), 0, Float(goal.z)); n.eulerAngles.y = CGFloat(face)
            return 0
        }
        let pts = VillagePath.route(from: from, to: goal, obstacles: obstacles)
        var acts: [SCNAction] = []
        var total = 0.0
        for (a, b) in zip(pts, pts.dropFirst()) {
            let d = a.dist(b)
            guard d > 0.01 else { continue }
            let t = d / speed
            let head = atan2(b.x - a.x, b.z - a.z)
            acts.append(.rotateTo(x: 0, y: CGFloat(head), z: 0, duration: 0.12, usesShortestUnitArc: true))
            acts.append(.move(to: SCNVector3(b.x, 0, b.z), duration: t))
            total += t + 0.12
        }
        acts.append(.rotateTo(x: 0, y: CGFloat(face), z: 0, duration: 0.25, usesShortestUnitArc: true))
        total += 0.25
        n.runAction(.sequence(acts), forKey: "walk")
        for (i, l) in legs.enumerated() {
            let s = i % 2 == 0 ? CGFloat(0.55) : -0.55
            let swing = SCNAction.sequence([.rotateTo(x: s, y: 0, z: 0, duration: 0.16), .rotateTo(x: -s, y: 0, z: 0, duration: 0.16)])
            l.runAction(.sequence([.repeat(swing, count: max(1, Int((total - 0.25) / 0.32))), .rotateTo(x: 0, y: 0, z: 0, duration: 0.1)]), forKey: "swing")
        }
        return total + 0.2
    }

    // MARK: 小狗

    /// 小狗站在誰旁邊（在等你回答、而且牠已經跑到那個人身邊）
    var dogBeside: String? {
        guard let id = dogGoalId, let p = persons[id] else { return nil }
        return p.goal.dist(VPoint(Double(dog.position.x), Double(dog.position.z))) < 2.2 ? id : nil
    }
    var dogTarget: String? { plan.dogTarget }

    /// 等你回答的人旁邊的一個空位（他右手邊，站不下換左邊、前面）
    private func besidePoint(_ p: Person) -> (VPoint, Double) {
        let f = p.face
        let fwd = VPoint(sin(f), cos(f)), right = VPoint(cos(f), -sin(f))
        for (k, s) in [(1.0, 0.45), (-1.0, 0.45), (0.0, 1.6)] {
            let q = VPoint(p.goal.x + right.x * k * 1.45 + fwd.x * s, p.goal.z + right.z * k * 1.45 + fwd.z * s)
            if VillageLayout.walkable(q, obstacles: obstacles, pad: 0.1) {
                return (q, atan2(p.goal.x - q.x, p.goal.z - q.z))
            }
        }
        return (VPoint(p.goal.x + fwd.x * 1.2, p.goal.z + fwd.z * 1.2), f + .pi)
    }

    private func updateDog(animate: Bool) {
        let target = plan.dogTarget
        if let t = target, let p = persons[t] {
            let (q, face) = besidePoint(p)
            // 新的人在等、或那個人換了位置 ⇒ 跑過去（你手動帶牠走開也會被新的「等你」叫回來）
            if t != dogGoalId || q.dist(dogGoal) > 0.3 {
                dogGoalId = t; dogGoal = q; manualUntil = .distantPast
                bump(walk(dog, to: q, face: face, speed: Self.dogSpeed, animate: animate))
            }
        } else if dogGoalId != nil {
            dogGoalId = nil; dogGoal = Self.dogRest
            if Date() > manualUntil { bump(walk(dog, to: Self.dogRest, face: 0.4, speed: Self.dogSpeed, animate: animate)) }
        }
    }

    /// 點地面：小狗走過去（30 秒內不自己亂跑；有新的人等你回答時照樣會跑過去）
    func walkDog(to p: VPoint) -> TimeInterval {
        let r = hypot(p.x, p.z), lim = VillageLayout.walkRadius
        let q = r > lim ? VPoint(p.x / r * lim, p.z / r * lim) : p
        manualUntil = Date().addingTimeInterval(30)
        let from = VPoint(Double(dog.position.x), Double(dog.position.z))
        return walk(dog, to: q, face: atan2(q.x - from.x, q.z - from.z), speed: Self.dogSpeed, animate: canAnimate() || !BoardWindow.testMode)
    }

    /// 閒晃（每 10–16 秒一次）：小狗沒事時在廣場附近走走；廣場上的人挑一位換個位置
    private func scheduleAmbient() {
        guard !Look.reduceMotion, !BoardWindow.testMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 10...16)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.root.isHidden && self.canAnimate() { self.ambient() }
                self.scheduleAmbient()
            }
        }
    }

    private func ambient() {
        var t = 0.0
        let busy = dog.action(forKey: "walk") != nil
        if !busy && Date() > manualUntil {
            if let id = plan.dogTarget, let p = persons[id] {
                let (q, face) = besidePoint(p)
                if q.dist(VPoint(Double(dog.position.x), Double(dog.position.z))) > 0.5 {
                    t = max(t, walk(dog, to: q, face: face, speed: Self.dogSpeed, animate: true))
                }
            } else {
                // 沒事：廣場附近晃，或去營火旁邊站一下
                let fire = Bool.random()
                let c = fire ? VillageLayout.campfire : VillageLayout.plaza
                let a = Double.random(in: 0..<(2 * .pi)), r = fire ? Double.random(in: 4.6...5.6) : Double.random(in: 3.0...6.5)
                let q = VPoint(c.x + sin(a) * r, c.z + cos(a) * r)
                if VillageLayout.walkable(q, obstacles: obstacles) {
                    t = max(t, walk(dog, to: q, face: Double.random(in: -1.5...1.5), speed: Self.dogSpeed * 0.6, animate: true))
                }
            }
        }
        // 營火：水煙壺傳給下一位，吸一口冒一點煙（只有這幾秒在畫，平常不重畫）
        t = max(t, passBong(puff: true))
        if t > 0 { onPlay?(t) }
    }

    // MARK: 營火、水煙壺（11-12 第二輪：沒事的島民圍著營火坐，輪流拿水煙壺）

    private var fireNode: SCNNode?, fireLight: SCNNode?
    private var fireSig = ""
    private var stoolNode: SCNNode?
    private var stoolCount = 0
    private var lampK: CGFloat = 0
    private var raining = false
    private(set) var bongHolder: String?

    private func updateCampfire(stools: Int, raining rain: Bool) {
        if stools != stoolCount {
            stoolCount = stools
            stoolNode?.removeFromParentNode()
            let n = VillageArt.stools(stools)
            n.enumerateHierarchy { c, _ in c.categoryBitMask |= 1 | OfficeBuilder.outdoorMask }
            root.addChildNode(n); stoolNode = n
        }
        let sig = "\(rain)"
        if sig != fireSig {
            fireSig = sig; raining = rain
            fireNode?.removeFromParentNode()
            let n = VillageArt.campfire(small: rain)
            n.enumerateHierarchy { c, _ in c.categoryBitMask |= 1 | OfficeBuilder.outdoorMask }
            root.addChildNode(n); fireNode = n
            if fireLight == nil {
                let l = SCNNode(); l.light = SCNLight(); l.light!.type = .omni
                l.light!.color = VoxMat.color(0xFF9A3C); l.light!.attenuationStartDistance = 1; l.light!.attenuationEndDistance = 9
                l.position = SCNVector3(VillageLayout.campfire.x, 1.6, VillageLayout.campfire.z)
                root.addChildNode(l); fireLight = l
            }
            setFireLight()
        }
    }
    /// 火光：白天一點點、晚上照亮周圍；下雨變小
    private func setFireLight() {
        guard let l = fireLight?.light else { return }
        l.intensity = (90 * VoxMat.power + 700 * lampK) * (raining ? 0.35 : 1)
    }

    /// 營火旁坐著的人（座位順序）
    private var campers: [String] {
        seatOf.filter { persons[$0.key]?.seated == true }.sorted { $0.value < $1.value }.map(\.key)
    }

    /// 把水煙壺交給下一位（puff＝吸一口冒煙）；回傳要播幾秒
    @discardableResult
    private func passBong(puff: Bool) -> TimeInterval {
        let list = campers
        let next: String? = list.isEmpty ? nil : bongHolder.flatMap { h in list.firstIndex(of: h).map { list[($0 + 1) % list.count] } } ?? list.first
        for p in persons.values { p.node.childNode(withName: "bong", recursively: false)?.removeFromParentNode() }
        bongHolder = next
        guard let id = next, let p = persons[id] else { return 0 }
        let k = CGFloat(Self.personScale)
        let b = VillageArt.bong()
        b.name = "bong"
        // 11-12 實機：原本放在 x 0.65，坐著的 Kubo 身體半寬約 0.69 ⇒ 整支藏在身體裡看不到（他說「沒有在傳」）。
        // 改放在右手外側（手在 x≈0.83）、坐墩高度、放大：不管從哪個方向看都在身體外面
        let kb = k * 1.6
        b.scale = SCNVector3(kb, kb, kb)
        b.position = SCNVector3(0.98, CGFloat(TowerSpec.seatTop) * k - 0.05, 0.15)
        p.node.addChildNode(b)
        guard puff, !Look.reduceMotion else { return 0.2 }
        // 吸一口：頭往後仰一下，頭頂冒三團煙往上飄、變淡、消失
        if let body = p.node.childNode(withName: "body", recursively: true), !body.hasActions {
            body.runAction(.sequence([.rotateBy(x: -0.12, y: 0, z: 0, duration: 0.4), .wait(duration: 0.5), .rotateBy(x: 0.12, y: 0, z: 0, duration: 0.4)]))
        }
        let head = p.node.childNode(withName: "anchor", recursively: false)?.position.y ?? 1.6
        for i in 0..<3 {
            let c = SCNNode(geometry: SCNBox(width: 0.32, height: 0.32, length: 0.32, chamferRadius: 0.04))
            c.geometry!.firstMaterial = VillageArt.smoke
            c.position = SCNVector3(p.node.position.x, head - 0.3, p.node.position.z)
            c.opacity = 0; c.categoryBitMask |= 1 | OfficeBuilder.outdoorMask
            root.addChildNode(c)
            let dx = CGFloat.random(in: -0.4...0.4), dz = CGFloat.random(in: -0.4...0.4)
            c.runAction(.sequence([.wait(duration: 0.8 + Double(i) * 0.35),
                                   .group([.fadeOpacity(to: 0.85, duration: 0.25), .scale(to: 1.3, duration: 0.25)]),
                                   .group([.moveBy(x: dx, y: 1.6, z: dz, duration: 1.8), .fadeOut(duration: 1.8), .scale(to: 2.2, duration: 1.8)]),
                                   .removeFromParentNode()]))
        }
        return 3.4
    }

    /// 有新筆記：學校屋頂冒一顆星星（跳上去、轉一圈、淡掉）；回傳要播幾秒
    func flashSchool() -> TimeInterval {
        guard !Look.reduceMotion else { return 0 }
        let star = VillageArt.star()
        star.position = SCNVector3(VillageLayout.school.cx, 4.2, VillageLayout.school.cz + 1.0)
        star.enumerateHierarchy { c, _ in c.categoryBitMask |= 1 | OfficeBuilder.outdoorMask }
        root.addChildNode(star)
        star.runAction(.sequence([.group([.moveBy(x: 0, y: 1.6, z: 0, duration: 0.8), .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 1.6)]),
                                  .wait(duration: 0.6), .fadeOut(duration: 0.6), .removeFromParentNode()]))
        return 3.1
    }

    // MARK: 車（11-12 第二輪：車型、顏色、停哪寫在本機設定；車主點了才看到）

    private var carNodes: [SCNNode] = []
    private var carSig = ""
    private(set) var cars: [VillageCar] = []
    private func updateCars(_ list: [VillageCar]) {
        let sig = list.map { "\($0.model.rawValue)|\($0.color)|\($0.zone.rawValue)|\($0.slot)" }.joined(separator: ",")
        cars = list
        guard sig != carSig else { return }
        carSig = sig
        carNodes.forEach { $0.removeFromParentNode() }
        carNodes = list.enumerated().compactMap { i, c in
            guard let at = VillageLayout.carSpots[c.zone]?[c.slot] else { return nil }
            let n = VillageArt.car(c.model, color: c.color, at: at)
            n.name = "car:\(i)"
            n.enumerateHierarchy { x, _ in x.categoryBitMask |= 1 | OfficeBuilder.outdoorMask }
            OfficeBuilder.pickable(n)
            root.addChildNode(n)
            return n
        }
    }
    // MARK: 小攤、家、設施

    private func updateStalls(_ list: [String]) {
        let sig = list.joined(separator: "|")
        guard sig != stallSig else { return }
        stallSig = sig
        stallNode?.removeFromParentNode()
        let n = SCNNode(); n.name = "stalls"
        for (i, name) in list.enumerated() { n.addChildNode(VillageArt.stall(i, name)) }
        n.enumerateHierarchy { c, _ in c.categoryBitMask |= 1 | OfficeBuilder.outdoorMask }
        OfficeBuilder.pickable(n)
        root.addChildNode(n); stallNode = n
    }

    private func updateHomes(_ homes: [VillageHome]) {
        let sig = homes.map { "\($0.index):\($0.name):\($0.zone.rawValue):\($0.online)" }.joined(separator: ",")
        guard sig != homeSig else { return }
        homeSig = sig
        homeNodes.forEach { $0.removeFromParentNode() }
        homeNodes = homes.map { h in
            let n = VillageArt.home(h)
            n.enumerateHierarchy { c, _ in c.categoryBitMask |= 1 | OfficeBuilder.outdoorMask }
            OfficeBuilder.pickable(n)
            root.addChildNode(n)
            return n
        }
    }

    /// 城市資料（溫度、額度、iCloud、內建碟）→ 島上設施的名字（點了開哪張卡）、水井水位、警告牌
    func updateCity(_ s: CityState) {
        buildIfNeeded()
        facilityIds["windmill"] = "city:cooler"
        facilityIds["well"] = "city:power"
        facilityIds["balloon"] = s.clouds.first(where: \.isICloud)?.id ?? "city:cloud:iCloud"
        facilityIds["warehouse"] = s.disks.first(where: \.isInternal)?.id ?? "city:disk:內建碟"
        for (k, n) in facilityNodes { n.name = facilityIds[k] }
        // 海的潮位＝7 天額度剩多少（剩越多潮越高；快用完退潮、外圈沙灘露出來）
        let tide = VillageSigns.tide(s.grid)
        if let sea = seaNode, abs(tide - seaTide) > 0.02 {
            seaTide = tide
            let y = CGFloat(VillageArt.seaOffset(tide))
            if canAnimate() && abs(sea.position.y - y) > 0.01 {
                sea.runAction(.move(to: SCNVector3(0, y, 0), duration: 2.0)); onPlay?(2.1)
            } else { sea.position.y = y }
        }
        let lv = Int((VillageSigns.water(s.grid) * 10).rounded())
        let sig = "\(lv)"
        if sig != wellSig {
            wellSig = sig
            wellNode?.removeFromParentNode()
            let w = VillageArt.waterTower(level: Float(lv) / 10)
            w.name = "city:power"
            w.enumerateHierarchy { c, _ in c.categoryBitMask |= 1 | OfficeBuilder.outdoorMask }
            OfficeBuilder.pickable(w)
            root.addChildNode(w); wellNode = w
            facilityNodes["well"] = w
        }
        signs = VillageSigns.alerts(s)
        for sg in signs where signAnchors[sg.id] == nil {
            let a = SCNNode(); a.name = "sign-anchor"
            root.addChildNode(a); signAnchors[sg.id] = a
        }
        for (id, a) in signAnchors { if let p = point(id) { a.position = p } }
    }

    /// 島上設施的警告牌（平常空的）
    func signLabels() -> [(id: String, anchor: SCNNode, text: String, alert: Bool)] {
        signs.compactMap { s in signAnchors[s.id].map { (s.id, $0, s.text, true) } }
    }

    // MARK: 給 SCNView 用的

    func labelPeople() -> [OfficeBuilder.LabelPerson] {
        var out = persons.compactMap { id, p -> OfficeBuilder.LabelPerson? in
            guard let a = p.node.childNode(withName: "anchor", recursively: true) else { return nil }
            var card = p.resident.card
            if p.resident.pet, let cfg = VillageStore.config, let t = card?.title {
                let rest = t.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                card?.title = cfg.petTitle(p.resident.name) + "-" + rest
            }
            return OfficeBuilder.LabelPerson(id: id, anchor: a, card: card, mood: p.resident.mood ?? .idle, floor: "village")
        }
        if let a = dog.childNode(withName: "anchor", recursively: true) {
            out.append(OfficeBuilder.LabelPerson(id: "boss", anchor: a, card: nil, mood: .idle, floor: "village"))
        }
        return out
    }

    func peopleNodes() -> [(String, SCNNode)] { persons.map { ($0.key, $0.value.node) } + [("boss", dog)] }
    func personNode(_ id: String) -> SCNNode? { id == "boss" ? dog : persons[id]?.node }

    func highlight(_ id: String?) {
        func set(_ n: SCNNode?, _ h: Bool) { if let n, n.isHidden != h { n.isHidden = h } }
        for (pid, p) in persons { set(p.node.childNode(withName: "halo", recursively: false), pid != id) }
        set(dog.childNode(withName: "halo", recursively: false), id != "boss")
    }

    /// 城市 id／地點 → 島上的點（鏡頭飛過去、警告牌錨點）
    func point(_ id: String) -> SCNVector3? {
        func v(_ p: VPoint, _ y: Double) -> SCNVector3 { SCNVector3(p.x, y, p.z) }
        if id == "city:cooler" || id == facilityIds["windmill"] { return v(VillageLayout.windmill, 7.2) }
        if id == "city:power" { return v(VillageLayout.well, 5.4) }
        if id == "city:fuel" { return SCNVector3(0, 0, VillageLayout.radius + 4.5) }
        if id.hasPrefix("city:cloud:") { return SCNVector3(VillageLayout.balloonTether.x + 1.5, 9.5, VillageLayout.balloonTether.z + 2.5) }
        if id.hasPrefix("city:disk:") { return v(VPoint(VillageLayout.diskShed.cx, VillageLayout.diskShed.cz), 2.6) }
        if id == "city:school" { return v(VPoint(VillageLayout.school.cx, VillageLayout.school.cz), 5.2) }
        return nil
    }

    /// 左側清單點地點：鏡頭對準哪裡、框多大（公尺）
    func focus(_ id: String) -> (SIMD3<Double>, Double)? {
        let key = id.hasPrefix("place:") ? String(id.dropFirst(6)) : id
        func r(_ b: VRect, _ k: Double = 1.6) -> (SIMD3<Double>, Double) { (SIMD3(b.cx, 1.6, b.cz + 1.5), max(b.w, b.d) * k) }
        switch key {
        case "townhall": return r(VillageLayout.shop)
        case "shop": return r(VillageLayout.shop)
        case "company": return r(VillageLayout.company)
        case "plaza": return (SIMD3(VillageLayout.plaza.x, 1, VillageLayout.plaza.z), 11)
        case "school": return r(VillageLayout.school, 2.4)
        case "campfire": return (SIMD3(VillageLayout.campfire.x, 1, VillageLayout.campfire.z), 10)
        case "facility": return (SIMD3(0, 2, 2), 34)
        default:
            if key.hasPrefix("stall:"), let i = Int(key.dropFirst(6)), i < VillageLayout.stalls.count { return r(VillageLayout.stalls[i], 3.2) }
            if key.hasPrefix("home:"), let i = Int(key.dropFirst(5)), i < VillageLayout.homes.count {
                let h = VillageLayout.homes[i]; return (SIMD3(h.x, 1.2, h.z), 8)
            }
            return nil
        }
    }
}

// MARK: - 方塊美術

@MainActor
enum VillageArt {
    typealias M = SCNMaterial
    static func F(_ d: Double) -> Float { Float(d) }

    // 調色盤
    static let cream: UInt32 = 0xF3E9D2, olive: UInt32 = 0x6B7B3A, oliveDark: UInt32 = 0x4F5A2A, gold: UInt32 = 0xD4AF4F
    static let wood: UInt32 = 0x9C6B43, woodDark: UInt32 = 0x6E4A2E, stone: UInt32 = 0xB9B4AA, ink: UInt32 = 0x2A1D18
    static var window: M { TM.glow(0xFFD27A, 0.05, 1.5) }
    static var windowOff: M { TM.f(0x3A4048) }

    /// 招牌材質（大樓招牌的作法：畫成圖、白天微亮、夜晚亮、停電跟著熄）。同一組字與尺寸只做一次
    private static var boards: [String: M] = [:]
    static func board(_ text: String, w: CGFloat, h: CGFloat, bg: UInt32, fg: UInt32, rim: UInt32? = nil, glow: (CGFloat, CGFloat) = (0.3, 0.9)) -> M {
        let key = "\(text)|\(w)x\(h)|\(bg)|\(fg)|\(rim ?? 0)"
        if let m = boards[key] { return m }
        let px: CGFloat = 160
        let img = NSImage(size: NSSize(width: w * px, height: h * px), flipped: false) { r in
            VoxMat.color(bg).setFill(); r.fill()
            if let rim {
                VoxMat.color(rim).setFill()
                let t = max(4, r.height * 0.07)
                NSRect(x: 0, y: 0, width: r.width, height: t).fill(); NSRect(x: 0, y: r.height - t, width: r.width, height: t).fill()
                NSRect(x: 0, y: 0, width: t, height: r.height).fill(); NSRect(x: r.width - t, y: 0, width: t, height: r.height).fill()
            }
            var size = r.height * 0.68
            var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: VoxMat.color(fg)]
            var ts = (text as NSString).size(withAttributes: a)
            if ts.width > r.width * 0.9 {
                size *= r.width * 0.9 / ts.width
                a[.font] = NSFont.systemFont(ofSize: size, weight: .heavy)
                ts = (text as NSString).size(withAttributes: a)
            }
            (text as NSString).draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2), withAttributes: a)
            return true
        }
        let m = SCNMaterial()
        let cg = OfficeBuilder.raster(img, scale: 1)
        m.diffuse.contents = cg; m.emission.contents = cg
        m.diffuse.mipFilter = .linear; m.diffuse.minificationFilter = .linear
        m.lightingModel = .lambert
        VoxMat.registerGlow(m, day: glow.0, night: glow.1)
        boards[key] = m
        return m
    }

    /// 一塊招牌（中心 c、朝 +z 轉 a）：前面字面、後面同色厚板
    static func sign(_ m: M, w: CGFloat, h: CGFloat, at c: SCNVector3, a: CGFloat = 0, back: UInt32) -> SCNNode {
        let g = SCNNode(); g.position = c; g.eulerAngles.y = a
        let box = SCNNode(geometry: SCNBox(width: w + 0.06, height: h + 0.06, length: 0.08, chamferRadius: 0))
        box.geometry!.firstMaterial = TM.f(back)
        let pl = SCNPlane(width: w, height: h); pl.firstMaterial = m
        let face = SCNNode(geometry: pl); face.position.z = 0.045
        g.addChildNode(box); g.addChildNode(face)
        return g
    }

    // MARK: 海、島、廣場、路、樹

    /// 海（7 天額度＝潮位）：整片海一起升降（seaOffset）。島底下挖空（點地面不會點到海、海升起來也不會從島中間冒出來）；
    /// 近岸一圈淺灘顏色亮一階
    static let seaTop: Float = -0.58
    static func seaOffset(_ tide: Double) -> Float { (-1.05 + 0.7 * Float(tide)) - seaTop }
    static func sea() -> SCNNode {
        let m = VoxelMesh(), k = Kit(m: m)
        let deep = VoxMat.dayNight(0x4E9FC4, 0x1A3049), shallow = VoxMat.dayNight(0x7CC7DA, 0x274766)
        let R = F(VillageLayout.radius), hole = R + 1.5, near = R + 6, H: Float = 70, far: Float = 220
        func seg(_ x0: Float, _ x1: Float, _ z: Float, _ mat: SCNMaterial, top: Float) {
            guard x1 - x0 > 0.01 else { return }
            for sgn: Float in [-1, 1] { k.b(.identity, sgn * (x0 + x1) / 2, top - 1.0, z, x1 - x0, 1.0, 1.02, mat) }
        }
        var z = -H + 0.5
        while z < H {
            let inner = abs(z) < hole ? (hole * hole - z * z).squareRoot() : 0
            let outer = abs(z) < near ? (near * near - z * z).squareRoot() : 0
            if inner == 0 && outer == 0 { k.b(.identity, 0, seaTop - 1.02, z, 2 * H, 1.0, 1.02, deep) }
            else {
                if inner == 0 { k.b(.identity, 0, seaTop + 0.02 - 1.0, z, 2 * outer, 1.0, 1.02, shallow) }
                else { seg(inner, outer, z, shallow, top: seaTop + 0.02) }
                seg(max(inner, outer), H, z, deep, top: seaTop)
            }
            z += 1
        }
        k.b(.identity, 0, seaTop - 1, H + (far - H) / 2, 2 * far, 1.0, far - H, deep)
        k.b(.identity, 0, seaTop - 1, -H - (far - H) / 2, 2 * far, 1.0, far - H, deep)
        k.b(.identity, H + (far - H) / 2, seaTop - 1, 0, far - H, 1.0, 2 * H, deep)
        k.b(.identity, -H - (far - H) / 2, seaTop - 1, 0, far - H, 1.0, 2 * H, deep)
        // 小木船（碼頭東邊）：船身、座板、船槳；船底在海面下一點
        let bx: Float = 2.8, bz = F(VillageLayout.radius) + 5.5, wl = seaTop - 0.15
        let hull = TM.f(0x9C6B43), rim = TM.f(0x6E4A2E)
        k.b(.identity, bx, wl, bz, 1.2, 0.35, 2.6, hull)
        k.b(.identity, bx, wl + 0.05, bz + 1.45, 0.7, 0.3, 0.35, hull)
        k.b(.identity, bx, wl + 0.35, bz, 1.3, 0.08, 2.7, rim)
        k.b(.identity, bx, wl + 0.36, bz + 0.3, 1.1, 0.06, 0.3, TM.f(0xE2C28E))
        k.b(Xf(x: bx, y: 0, z: bz, a: 0.3), 0.7, wl + 0.3, 0, 0.08, 0.06, 1.8, rim)
        return m.node(name: "city:fuel")
    }

    /// 島（一排一排疊成圓，邊緣有一點起伏）、沙灘、廣場石板、泥土小路、樹、花、碼頭、路燈
    static func terrain() -> SCNNode {
        let m = VoxelMesh(ao: 0), k = Kit(m: m)
        let grass = VoxMat.tex("grass"), side = VoxMat.tex("dirtside"), dirt = VoxMat.tex("dirt")
        let sand = VoxMat.dayNight(0xE9D7A6, 0x6E6650)
        let R = F(VillageLayout.radius)
        func wobble(_ z: Float) -> Float { 0.6 * sin(z * 0.9) + 0.4 * sin(z * 2.3 + 1) }
        var z = -R - 2
        while z <= R + 2 {
            let rs = R + 2 + wobble(z) * 0.5
            if rs * rs - z * z > 0.25 {
                let hw = (rs * rs - z * z).squareRoot()
                k.b(.identity, 0, -1.3, z, hw * 2, 1.0, 1.0, sand)
            }
            let rg = R + wobble(z)
            if abs(z) <= R, rg * rg - z * z > 0.25 {
                let hw = (rg * rg - z * z).squareRoot()
                m.box(.identity, SIMD3(0, -0.6, z), SIMD3(hw * 2, 1.2, 1.0), side, top: grass, bottom: dirt, uv: .sideFit(1))
            }
            z += 1
        }
        // 退潮才露出來的濕沙灘（潮位低於 −0.95 才看得到）
        let flat = VoxMat.dayNight(0xCDB78A, 0x5C5442)
        var tz = -R - 5
        while tz <= R + 5 {
            let ro = R + 5, ri = R + 1.5
            if ro * ro - tz * tz > 0.25 {
                let o = (ro * ro - tz * tz).squareRoot(), i = abs(tz) < ri ? (ri * ri - tz * tz).squareRoot() : 0
                if i == 0 { k.b(.identity, 0, -1.25, tz, 2 * o, 0.3, 1.0, flat) }
                else { for sg: Float in [-1, 1] { k.b(.identity, sg * (i + o) / 2, -1.25, tz, o - i, 0.3, 1.0, flat) } }
            }
            tz += 1
        }
        // 廣場：石板圓
        let P = VillageLayout.plaza, pr = F(VillageLayout.plazaRadius)
        let cob = VoxMat.tex("cobble")
        var pz = -pr
        while pz <= pr {
            let hw = (pr * pr - pz * pz).squareRoot()
            if hw > 0.3 { k.b(.identity, F(P.x), 0, F(P.z) + pz, hw * 2, 0.04, 0.52, cob) }
            pz += 0.5
        }
        // 噴水池
        let fx = F(P.x), fz = F(P.z), st = TM.f(stone), water = TM.glow(0x6EC3E8, 0.15, 0.5)
        k.b(.identity, fx, 0, fz, 2.2, 0.5, 2.2, st)
        k.b(.identity, fx, 0.5, fz, 1.7, 0.02, 1.7, water)
        k.b(.identity, fx, 0.5, fz, 0.4, 0.9, 0.4, st)
        k.b(.identity, fx, 1.4, fz, 0.8, 0.2, 0.8, st)
        k.b(.identity, fx, 1.6, fz, 0.5, 0.25, 0.5, water)
        // 小路（廣場 → 鎮公所、店屋、公司小屋、小攤、碼頭）
        let path = VoxMat.dayNight(0xCDAE7E, 0x5E523F)
        func lane(_ a: VPoint, _ b: VPoint, w: Float = 1.3) {
            let d = Float(a.dist(b)), ang = Float(atan2(b.x - a.x, b.z - a.z))
            k.b(Xf(x: F((a.x + b.x) / 2), y: 0, z: F((a.z + b.z) / 2), a: ang), 0, 0, 0, w, 0.03, d, path)
        }
        lane(VPoint(0, -1.6), VPoint(0, -7.4))
        lane(VPoint(4.4, 2.2), VPoint(12, 0.4)); lane(VPoint(12, 0.4), VPoint(12, -1.6), w: 2.0)
        lane(VPoint(-2.4, 7.0), VPoint(-8.5, 10.2)); lane(VPoint(2.4, 7.0), VPoint(8.5, 10.2))
        lane(VPoint(-3.4, 7.2), VPoint(-7.6, 15.6), w: 1.1)
        lane(VPoint(0, 7.6), VPoint(0, 13.0)); lane(VPoint(0, 13.0), VPoint(0, 25.5), w: 1.1)
        // 樹
        let leaf = VoxMat.tex("leaf", tint: nil), trunk = VoxMat.tex("darkplank")
        for (i, t) in VillageLayout.trees.enumerated() {
            let x = F(t.x), zz = F(t.z), h: Float = i % 3 == 0 ? 2.0 : 1.6
            k.b(.identity, x, 0, zz, 0.4, h, 0.4, trunk)
            m.box(.identity, SIMD3(x, h + 0.7, zz), SIMD3(1.7, 1.4, 1.7), leaf, uv: .fit)
            m.box(.identity, SIMD3(x + 0.1, h + 1.7, zz - 0.1), SIMD3(1.0, 0.7, 1.0), leaf, uv: .fit)
        }
        // 花（固定位置的小方塊）
        var rng = PixelTex.RNG(s: 42)
        let petals: [UInt32] = [0xF2A6B8, 0xFFE07A, 0xFFFFFF, 0xC9A0F2, 0xFF9A6B]
        let obs = VillageLayout.obstacles()
        for _ in 0..<70 {
            let a = rng.next() * 2 * .pi, r = 5 + rng.next() * (VillageLayout.walkRadius - 5.5)
            let p = VPoint(sin(a) * r, cos(a) * r)
            guard VillageLayout.walkable(p, obstacles: obs, pad: 0.6), p.dist(P) > VillageLayout.plazaRadius + 0.5 else { continue }
            k.b(.identity, F(p.x), 0, F(p.z), 0.08, 0.22, 0.08, TM.f(0x3E8E3E))
            k.b(.identity, F(p.x), 0.22, F(p.z), 0.18, 0.12, 0.18, TM.f(petals[Int(rng.next() * Double(petals.count)) % petals.count]))
        }
        // 碼頭（南邊）＋小船
        let plank = VoxMat.tex("plank")
        k.b(.identity, 0, -0.35, F(VillageLayout.radius) + 3.5, 2.0, 0.25, 7, plank)
        for zz in [VillageLayout.radius + 1.5, VillageLayout.radius + 4, VillageLayout.radius + 6.6] {
            for x: Float in [-0.9, 0.9] { k.b(.identity, x, -1.5, F(zz), 0.25, 1.4, 0.25, TM.f(woodDark)) }
        }
        // 小船在海（city:fuel）那個節點裡，跟著潮位一起升降（11-12：原本固定在地形上，滿潮時只剩紅色甲板浮在海上像破圖）
        // 路燈（夜晚亮、停電跟著熄）
        let lamp = TM.glow(0xFFC95A, 0.0, 2.0), pole = TM.f(0x3B3B3B)
        for p in [VPoint(-4.2, -1.0), VPoint(4.2, -1.0), VPoint(-4.2, 7.0), VPoint(4.2, 7.0), VPoint(-8.0, 0.3), VPoint(8.0, 0.2), VPoint(-1.6, 18), VPoint(-1.4, 24.4)] {
            k.b(.identity, F(p.x), 0, F(p.z), 0.14, 2.4, 0.14, pole)
            k.b(.identity, F(p.x), 2.4, F(p.z), 0.36, 0.36, 0.36, lamp)
            k.b(.identity, F(p.x), 2.76, F(p.z), 0.44, 0.08, 0.44, pole)
        }
        // 長椅（廣場邊）
        for (x, zz, a) in [(-3.4, 6.2, 0.6), (3.4, 6.2, -0.6)] as [(Float, Float, Float)] {
            let xf = Xf(x: x, y: 0, z: zz, a: a)
            k.b(xf, 0, 0.35, 0, 1.6, 0.1, 0.5, plank); k.b(xf, 0, 0.45, -0.22, 1.6, 0.45, 0.08, plank)
            for dx: Float in [-0.65, 0.65] { k.b(xf, dx, 0, 0, 0.1, 0.35, 0.4, TM.f(woodDark)) }
        }
        return m.node(name: "terrain")
    }

    /// 有斜度的屋頂：一層一層往內縮（voxel 階梯）
    static func roof(_ k: Kit, _ xf: Xf, y0: Float, w: Float, d: Float, steps: Int, rise: Float = 0.35, inset: Float = 0.45, _ m: M, ridgeAlongX: Bool = true) {
        for i in 0..<steps {
            let s = Float(i) * inset
            let ww = ridgeAlongX ? w + 0.5 : max(0.4, w + 0.5 - 2 * s), dd = ridgeAlongX ? max(0.4, d + 0.5 - 2 * s) : d + 0.5
            k.b(xf, 0, y0 + Float(i) * rise, 0, ww, rise, dd, m)
        }
    }

    // MARK: 建築

    /// 自家店屋：奶油色牆、橄欖綠屋頂、金色邊；屋上招牌＝店名；門口停一台休旅車
    static func shop(_ name: String) -> SCNNode {
        let b = VillageLayout.shop
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(b.cx), y: 0, z: F(b.cz))
        let w = F(b.w), d = F(b.d), zf = d / 2
        let wall = VoxMat.dayNight(cream, 0x8F8878), roofM = VoxMat.dayNight(olive, 0x343C1E), g = TM.f(gold)
        k.b(xf, 0, 0, 0, w + 0.4, 0.25, d + 0.4, TM.f(0xD8CDB4))
        k.b(xf, 0, 0.25, 0, w, 2.9, d, wall)
        k.b(xf, 0, 3.15, 0, w + 0.12, 0.16, d + 0.12, g)
        roof(k, xf, y0: 3.31, w: w, d: d, steps: 6, rise: 0.32, inset: 0.48, roofM)
        k.b(xf, 0, 3.31 + 6 * 0.32, 0, w + 0.5, 0.12, 0.5, g)                // 屋脊金邊
        k.b(xf, 2.2, 3.4, -0.6, 0.7, 1.6, 0.7, TM.f(0xBDA27A))                // 煙囪
        // 門（橄欖綠）、雨遮（奶油／橄欖條紋）、櫥窗
        k.b(xf, -0.4, 0.25, zf + 0.02, 1.2, 2.0, 0.08, TM.f(oliveDark))
        k.b(xf, -0.08, 1.2, zf + 0.08, 0.1, 0.1, 0.05, g)
        for i in 0..<6 { k.b(xf, -0.4 - 1.25 + 0.25 + Float(i) * 0.5, 2.35, zf + 0.45, 0.5, 0.12, 0.9, TM.f(i % 2 == 0 ? cream : olive)) }
        for x: Float in [-2.5, 1.6, 2.6] { k.b(xf, x, 0.95, zf + 0.02, 0.8, 1.1, 0.06, window); k.b(xf, x, 0.85, zf + 0.06, 0.95, 0.1, 0.1, g) }
        // 盆栽
        for x: Float in [-1.4, 0.6] { k.b(xf, x, 0.25, zf + 0.35, 0.36, 0.36, 0.36, TM.f(0xB8643C)); k.b(xf, x, 0.61, zf + 0.35, 0.44, 0.4, 0.44, VoxMat.tex("leaf")) }
        let n = m.node(name: "place:shop")
        n.addChildNode(sign(board(name, w: 3.6, h: 0.8, bg: 0x56632C, fg: 0xF0D27A, rim: gold, glow: (0.35, 1.0)), w: 3.6, h: 0.8,
                            at: SCNVector3(b.cx, 3.85, b.cz + Double(zf) + 0.5), back: 0x3F4920))
        return n
    }

    /// 車（車頭朝 +z，停在 at）：只做車型特徵，不畫品牌標誌
    static func car(_ model: VillageCarModel, color: UInt32, at: VPoint) -> SCNNode {
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(at.x), y: 0, z: F(at.z))
        let body = TM.f(color), glass = TM.f(0x1E2830), tire = TM.f(0x151515), rim = TM.f(0xB4B8BC), trim = TM.f(0x2A2C2F)
        let chrome = TM.f(0xC9CCD0), head = TM.glow(0xFFFBEA, 0.3, 1.8), tail = TM.glow(0xD7263D, 0.3, 1.2)
        func wheels(_ zf: Float, _ zb: Float, w: Float, r: Float = 0.68) {
            for (x, z) in [(-w, zf), (w, zf), (-w, zb), (w, zb)] {
                k.b(xf, x, 0, z, 0.32, r, r, tire); k.b(xf, x + (x > 0 ? 0.17 : -0.17), r * 0.28, z, 0.02, r * 0.42, r * 0.42, rim)
            }
        }
        switch model {
        case .suv:
            // 方正休旅：方的車身、黑色輪拱飾板、平車頂＋車頂架
            k.b(xf, 0, 0.34, 0, 1.9, 0.78, 4.5, body)
            for x: Float in [-0.96, 0.96] { k.b(xf, x, 0.28, 0, 0.04, 0.32, 4.3, trim) }
            k.b(xf, 0, 1.12, -0.2, 1.78, 0.66, 2.9, body)
            k.b(xf, 0, 1.18, -0.2, 1.82, 0.48, 2.6, glass); k.b(xf, 0, 1.18, 1.27, 1.66, 0.46, 0.05, glass)
            for x: Float in [-0.7, 0.7] { k.b(xf, x, 1.78, -0.2, 0.08, 0.1, 2.5, trim) }
            k.b(xf, 0, 1.88, -0.2, 1.5, 0.05, 0.08, trim); k.b(xf, 0, 1.88, -1.1, 1.5, 0.05, 0.08, trim)
            k.b(xf, 0, 0.62, 2.26, 1.1, 0.22, 0.04, trim)
            for x: Float in [-0.68, 0.68] { k.b(xf, x, 0.86, 2.26, 0.44, 0.12, 0.04, head); k.b(xf, x, 0.86, -2.26, 0.36, 0.14, 0.04, tail) }
            wheels(1.45, -1.45, w: 0.92)
        case .mpv:
            // 高大方盒 MPV：很高的車廂、整片大水箱罩、側滑門線
            k.b(xf, 0, 0.3, 0, 1.96, 0.8, 4.8, body)
            k.b(xf, 0, 1.1, -0.1, 1.92, 1.1, 4.1, body)
            k.b(xf, 0, 1.3, -0.1, 1.96, 0.62, 3.7, glass); k.b(xf, 0, 1.3, 1.96, 1.76, 0.66, 0.05, glass)
            k.b(xf, 0, 0.36, 2.41, 1.3, 0.78, 0.05, chrome)
            for i in 0..<5 { k.b(xf, 0, 0.44 + Float(i) * 0.14, 2.44, 1.2, 0.05, 0.02, trim) }
            for x: Float in [-0.99, 0.99] { k.b(xf, x, 0.5, -0.2, 0.02, 1.4, 0.03, trim) }
            for x: Float in [-0.78, 0.78] { k.b(xf, x, 0.98, 2.41, 0.32, 0.12, 0.04, head); k.b(xf, x, 1.0, -2.41, 0.12, 0.7, 0.04, tail) }
            wheels(1.55, -1.55, w: 0.95)
        case .coupe:
            // 低矮四門轎跑：低車身、車頂往後一路斜下去（斜背）
            k.b(xf, 0, 0.3, 0, 1.84, 0.56, 4.7, body)
            k.b(xf, 0, 0.86, 1.95, 1.78, 0.05, 0.8, body)
            for (i, (z, d, h)) in [(0.75, 1.0, 0.48), (-0.15, 0.8, 0.44), (-0.85, 0.6, 0.34), (-1.4, 0.5, 0.22), (-1.85, 0.4, 0.12)].enumerated() {
                k.b(xf, 0, 0.86, Float(z), 1.62 - Float(i) * 0.04, Float(h), Float(d), body)
            }
            k.b(xf, 0, 0.9, 0.5, 1.66, 0.36, 1.6, glass); k.b(xf, 0, 0.9, 1.31, 1.5, 0.34, 0.05, glass)
            k.b(xf, 0, 0.42, 2.36, 1.2, 0.16, 0.04, chrome)
            for x: Float in [-0.66, 0.66] { k.b(xf, x, 0.66, 2.36, 0.46, 0.1, 0.04, head); k.b(xf, x, 0.7, -2.36, 0.5, 0.1, 0.04, tail) }
            wheels(1.5, -1.5, w: 0.9, r: 0.62)
        }
        return m.node()
    }

    /// 公司小屋（Okle42）：黑底、金邊，招牌沿用大樓的 Okle42（42 金色）
    static func company() -> SCNNode {
        let b = VillageLayout.company
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(b.cx), y: 0, z: F(b.cz))
        let w = F(b.w), d = F(b.d), zf = d / 2
        let wall = TM.f(0x1C1E22), g = TM.f(0xE0B04A)
        k.b(xf, 0, 0, 0, w + 0.4, 0.22, d + 0.4, TM.f(0x55585E))
        k.b(xf, 0, 0.22, 0, w, 2.6, d, wall)
        k.b(xf, 0, 2.82, 0, w + 0.3, 0.2, d + 0.3, TM.f(0x2A2E35))
        k.b(xf, 0, 3.02, 0, w + 0.3, 0.06, d + 0.3, g)
        k.b(xf, 0, 3.08, 0, w - 1.2, 0.5, d - 1.2, TM.f(0x2A2E35))
        k.b(xf, 0.8, 0.22, zf + 0.02, 1.0, 2.0, 0.08, TM.f(0x0E0F11))
        k.b(xf, 0.48, 1.15, zf + 0.08, 0.08, 0.08, 0.05, g)
        for x: Float in [-1.6, -0.6] { k.b(xf, x, 1.0, zf + 0.02, 0.8, 1.0, 0.06, TM.glow(0xCFE3FF, 0.1, 1.4)) }
        k.b(xf, -w / 2 + 0.5, 0.22, zf + 0.4, 0.5, 0.9, 0.5, TM.f(0x3A3D44))      // 小郵筒
        k.b(xf, -w / 2 + 0.5, 1.12, zf + 0.4, 0.56, 0.12, 0.56, g)
        let n = m.node(name: "place:company")
        let sw: CGFloat = 3.4, sh: CGFloat = 0.7
        let s = SCNNode(); s.position = SCNVector3(b.cx, 3.6, b.cz + Double(zf) - 0.2)
        let box = SCNNode(geometry: SCNBox(width: sw, height: sh, length: 0.06, chamferRadius: 0)); box.geometry!.firstMaterial = TM.f(0x16181C)
        let pl = SCNPlane(width: sw, height: sh); pl.firstMaterial = TowerModules.signMaterial(w: sw, h: sh)
        let face = SCNNode(geometry: pl); face.position.z = 0.035
        s.addChildNode(box); s.addChildNode(face)
        n.addChildNode(s)
        return n
    }

    /// 個人小攤：木頭櫃台＋四根柱子＋條紋雨棚＋專案名木牌；櫃台上放幾樣小東西
    static let awnings: [(UInt32, UInt32)] = [(0xE85D4A, 0xFFF4E0), (0x3D8BD9, 0xFFF4E0), (0x58A55C, 0xFFF4E0), (0xE8A33D, 0xFFF4E0), (0x9B6BD6, 0xFFF4E0), (0xD95C9B, 0xFFF4E0)]
    static func stall(_ i: Int, _ name: String) -> SCNNode {
        let s = VillageLayout.stalls[i % VillageLayout.stalls.count]
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(s.cx), y: 0, z: F(s.cz))
        let w = F(s.w), d = F(s.d), plank = VoxMat.tex("plank"), (c1, c2) = awnings[i % awnings.count]
        k.b(xf, 0, 0, 0, w, 0.95, d, plank)
        k.b(xf, 0, 0.95, 0, w + 0.1, 0.06, d + 0.1, TM.f(woodDark))
        // 柱子：前面兩根在櫃台角、後面兩根在攤主後面（攤主站在櫃台和後柱中間）
        for x in [-w / 2 + 0.06, w / 2 - 0.06] { for z in [-d / 2 - 1.95, d / 2 - 0.06] { k.b(xf, x, 0, z, 0.1, 2.35, 0.1, TM.f(woodDark)) } }
        let n = Int(w / 0.4)
        for j in 0..<n { k.b(xf, -w / 2 + 0.2 + Float(j) * 0.4, 2.35, -0.98, 0.4, 0.14, d + 2.05, TM.f(j % 2 == 0 ? c1 : c2)) }
        var rng = PixelTex.RNG(s: UInt64(i * 7919 + 13))
        let goods: [UInt32] = [0xF2C230, 0xE85D4A, 0x7AC74F, 0xFFFFFF, 0x6B9BD1]
        for j in 0..<4 {
            let x = -w / 2 + 0.35 + Float(j) * 0.55, h = Float(0.12 + rng.next() * 0.2)
            k.b(xf, x, 1.01, 0.1, 0.3, h, 0.3, TM.f(goods[(i + j) % goods.count]))
        }
        let node = m.node(name: "place:stall:\(i)")
        node.addChildNode(sign(board(name, w: 2.1, h: 0.42, bg: 0xFFF6E0, fg: 0x5A3A22, rim: c1, glow: (0.2, 0.8)), w: 2.1, h: 0.42,
                               at: SCNVector3(s.cx, 2.75, s.cz + Double(d) / 2 + 0.25), back: 0x6E4A2E))
        return node
    }

    /// 一間家：牆色看住哪區；在線＝門開、窗亮；離線＝門關、窗暗、門口燈熄
    static let homeWalls: [VillageZone: [UInt32]] = [.shop: [0xF0E4C8, 0xEADBB8], .company: [0x3A3D44, 0x2E3138],
                                                     .personal: [0xE8C4B0, 0xBFD8C2, 0xC9D4E8, 0xF2DFA7], .townhall: [0xF4EEE2]]
    static func home(_ h: VillageHome) -> SCNNode {
        let c = VillageLayout.homes[h.index], a = Float(VillageLayout.homeFacing(h.index))
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(c.x), y: 0, z: F(c.z), a: a)
        let s = F(VillageLayout.homeSize), zf = s / 2
        let walls = homeWalls[h.zone] ?? [0xE8C4B0]
        let wall = TM.f(walls[h.index % walls.count])
        let roofC: UInt32 = h.zone == .company ? 0x1C1E22 : h.zone == .shop ? olive : [0xB8463A, 0x6B4A8A, 0x3D6E9C, 0x8A5A32][h.index % 4]
        k.b(xf, 0, 0, 0, s + 0.3, 0.18, s + 0.3, TM.f(stone))
        k.b(xf, 0, 0.18, 0, s, 1.9, s, wall)
        roof(k, xf, y0: 2.08, w: s, d: s, steps: 4, rise: 0.3, inset: 0.38, TM.f(roofC), ridgeAlongX: false)
        if h.zone == .company { k.b(xf, 0, 2.08, zf + 0.26, s + 0.5, 0.05, 0.02, TM.f(0xE0B04A)) }
        if h.online {
            k.b(xf, 0, 0.18, zf - 0.04, 0.8, 1.45, 0.05, TM.f(ink))                       // 門開著：門洞
            k.b(xf, 0.62, 0.18, zf + 0.3, 0.06, 1.45, 0.7, TM.f(woodDark))               // 門板往外開
            for x: Float in [-0.85, 0.85] { k.b(xf, x, 0.9, zf + 0.02, 0.5, 0.5, 0.05, window) }
            k.b(xf, -0.6, 1.75, zf + 0.12, 0.16, 0.16, 0.16, TM.glow(0xFFC95A, 0.1, 1.8))  // 門口燈
        } else {
            k.b(xf, 0, 0.18, zf + 0.02, 0.8, 1.45, 0.06, TM.f(woodDark))                // 門關著
            k.b(xf, 0.25, 0.85, zf + 0.06, 0.08, 0.08, 0.04, TM.f(0xC9A54A))
            for x: Float in [-0.85, 0.85] { k.b(xf, x, 0.9, zf + 0.02, 0.5, 0.5, 0.05, windowOff) }
            k.b(xf, -0.6, 1.75, zf + 0.12, 0.16, 0.16, 0.16, TM.f(0x55585E))
        }
        let n = m.node(name: "home:\(h.name)")
        let plate = board(h.name, w: 1.1, h: 0.28, bg: 0x7A4E2D, fg: 0xFFF3D6, glow: h.online ? (0.25, 0.9) : (0.05, 0.12))
        let p = xf.apply(SIMD3(0, 1.85, zf + 0.06))
        n.addChildNode(sign(plate, w: 1.1, h: 0.28, at: SCNVector3(p), a: CGFloat(a), back: 0x5A3A22))
        return n
    }

    /// 高架水塔（5 小時額度）：四腳木架、透明水箱、正面刻度，水位＝剩多少（滿＝還很多）
    static func waterTower(level: Float) -> SCNNode {
        let c = VillageLayout.well
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(c.x), y: 0, z: F(c.z))
        let wd = TM.f(woodDark), y0: Float = 3.2, s: Float = 1.9
        for x: Float in [-0.85, 0.85] { for z: Float in [-0.85, 0.85] { k.b(xf, x, 0, z, 0.2, y0, 0.2, wd) } }
        for y: Float in [1.1, 2.3] { k.b(xf, 0, y, 0.85, 1.9, 0.12, 0.12, wd); k.b(xf, 0, y, -0.85, 1.9, 0.12, 0.12, wd)
            k.b(xf, 0.85, y, 0, 0.12, 0.12, 1.9, wd); k.b(xf, -0.85, y, 0, 0.12, 0.12, 1.9, wd) }
        for y: Float in stride(from: 0.2, to: y0, by: 0.4) { k.b(xf, 0.6, y, 0.98, 0.5, 0.06, 0.06, TM.f(wood)) }       // 梯子
        k.b(xf, 0, y0, 0, s + 0.3, 0.14, s + 0.3, wd)
        // 水（發一點光，晚上也看得到水位）
        if level > 0.01 { k.b(xf, 0, y0 + 0.14, 0, s - 0.1, (s - 0.1) * level, s - 0.1, TM.glow(0x3E9BE0, 0.25, 0.8)) }
        // 箱框（四根角柱＋上下框）
        for x: Float in [-s / 2, s / 2] { for z: Float in [-s / 2, s / 2] { k.b(xf, x, y0 + 0.14, z, 0.1, s, 0.1, TM.f(0x5A3A22)) } }
        k.b(xf, 0, y0 + 0.14 + s, 0, s + 0.12, 0.1, s + 0.12, TM.f(0x5A3A22))
        // 刻度：正面 4 格（25% 一格），50% 那條長一點
        for i in 1...4 {
            let w: Float = i == 2 ? 0.5 : 0.28
            k.b(xf, -s / 2 + 0.06 + w / 2, y0 + 0.14 + (s - 0.1) * Float(i) / 4, s / 2 + 0.03, w, 0.05, 0.02, TM.f(0xF4EEE2))
        }
        roof(k, xf, y0: y0 + 0.24 + s, w: s, d: s, steps: 4, rise: 0.22, inset: 0.32, TM.f(0x8A4B32), ridgeAlongX: false)
        let n = m.node(name: "city:power")
        // 透明水箱壁（不寫深度，看得到裡面的水）
        let g = SCNNode(geometry: SCNBox(width: CGFloat(s), height: CGFloat(s), length: CGFloat(s), chamferRadius: 0))
        g.geometry!.firstMaterial = TM.glass(0.28, 0xCFEFFF)
        g.position = SCNVector3(c.x, Double(y0 + 0.14 + s / 2), c.z)
        n.addChildNode(g)
        return n
    }

    /// 營火旁的木頭坐墩（n 個，照 VillageLayout.plazaSpot 的座位）
    static func stools(_ n: Int) -> SCNNode {
        let m = VoxelMesh(ao: 0), k = Kit(m: m)
        let h = Float(TowerSpec.seatTop) * Float(VillageBuilder.personScale)
        for i in 0..<n {
            let (p, a) = VillageLayout.plazaSpot(i)
            let xf = Xf(x: F(p.x), y: 0, z: F(p.z), a: F(a))
            k.b(xf, 0, 0, 0, 0.66, h - 0.04, 0.66, VoxMat.tex("darkplank"))
            k.b(xf, 0, h - 0.04, 0, 0.6, 0.04, 0.6, TM.f(0xE2C28E))
        }
        return m.node(name: "stools")
    }

    /// 營火：石圈、交叉的柴、火焰（發光）；下雨＝只剩小火苗和炭
    static func campfire(small: Bool) -> SCNNode {
        let c = VillageLayout.campfire
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(c.x), y: 0, z: F(c.z))
        for i in 0..<8 {
            let a = Float(i) / 8 * 2 * .pi
            k.b(xf, sin(a) * 0.7, 0, cos(a) * 0.7, 0.32, 0.24, 0.32, TM.f(stone))
        }
        k.b(Xf(x: F(c.x), y: 0, z: F(c.z), a: 0.6), 0, 0.05, 0, 0.18, 0.16, 1.0, VoxMat.tex("darkplank"))
        k.b(Xf(x: F(c.x), y: 0, z: F(c.z), a: -0.6), 0, 0.1, 0, 0.18, 0.16, 1.0, VoxMat.tex("darkplank"))
        k.b(xf, 0, 0.02, 0, 0.6, 0.08, 0.6, TM.glow(0xC2401A, 0.6, 1.6))       // 炭火
        if small {
            k.b(xf, 0.05, 0.12, 0, 0.18, 0.22, 0.18, TM.glow(0xFF7A1A, 0.8, 1.8))
        } else {
            let orange = TM.glow(0xFF7A1A, 1.0, 2.2), yellow = TM.glow(0xFFD23A, 1.0, 2.4)
            k.b(xf, 0, 0.12, 0, 0.5, 0.4, 0.5, orange)
            k.b(xf, 0.08, 0.5, -0.05, 0.36, 0.36, 0.36, orange)
            k.b(xf, -0.05, 0.2, 0.05, 0.3, 0.5, 0.3, yellow)
            k.b(xf, 0, 0.84, 0, 0.18, 0.26, 0.18, yellow)
            k.b(xf, 0.22, 0.3, 0.18, 0.16, 0.22, 0.16, yellow)
        }
        return m.node(name: "campfire")
    }

    /// 水煙壺（卡通版）：圓肚玻璃瓶、裡面一點水、長頸、側邊小碗
    static func bong() -> SCNNode {
        let m = VoxelMesh()
        let glass = TM.glass(0.55, 0xA8E6CF), water = TM.glow(0x6EC3E8, 0.2, 0.6), bowl = TM.f(0x3B3B3B)
        m.box(.identity, SIMD3(0, 0.1, 0), SIMD3(0.22, 0.2, 0.22), glass)
        m.box(.identity, SIMD3(0, 0.06, 0), SIMD3(0.18, 0.1, 0.18), water)
        m.box(.identity, SIMD3(0, 0.36, 0), SIMD3(0.09, 0.34, 0.09), glass)
        m.box(.identity, SIMD3(0, 0.55, 0), SIMD3(0.13, 0.05, 0.13), glass)
        m.box(.identity, SIMD3(0.12, 0.15, 0.06), SIMD3(0.12, 0.04, 0.04), glass)
        m.box(.identity, SIMD3(0.19, 0.19, 0.06), SIMD3(0.08, 0.06, 0.08), bowl)
        return m.node(name: "bong")
    }

    /// 煙（吸一口時冒的那幾團）
    static let smoke: SCNMaterial = {
        let m = SCNMaterial(); m.diffuse.contents = VoxMat.color(0xEDEBF2); m.lightingModel = .lambert
        m.emission.contents = VoxMat.color(0x6A6870)
        return m
    }()

    /// 風車（這台 Mac 的溫度）：塔身＋四片扇葉（不一直轉：持續動畫會一直重畫，耗電）
    static func windmill() -> SCNNode {
        let c = VillageLayout.windmill
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(c.x), y: 0, z: F(c.z))
        let w1 = VoxMat.dayNight(0xF1E8D6, 0x7D786E)
        for (i, s) in [2.3, 2.0, 1.75, 1.5, 1.3].enumerated() { k.b(xf, 0, Float(i) * 1.2, 0, Float(s), 1.2, Float(s), w1) }
        roof(k, xf, y0: 6.0, w: 1.3, d: 1.3, steps: 3, rise: 0.3, inset: 0.3, TM.f(0x8A4B32), ridgeAlongX: false)
        k.b(xf, 0, 0, 1.18, 0.7, 1.3, 0.06, TM.f(woodDark))
        k.b(xf, 0, 3.4, 0.9, 0.4, 0.4, 0.06, window)
        let n = m.node(name: "city:cooler")
        let hub = SCNNode(); hub.position = SCNVector3(c.x, 6.6, c.z + 0.85); hub.eulerAngles.z = 0.35
        let bm = VoxelMesh(ao: 0)
        bm.box(.identity, SIMD3(0, 0, 0), SIMD3(0.4, 0.4, 0.3), TM.f(woodDark))
        for r in 0..<4 {
            let ang = Float(r) * .pi / 2, dir = SIMD2<Float>(cos(ang), sin(ang))
            for j in 0..<5 {
                let t = 0.5 + Float(j) * 0.55
                bm.box(.identity, SIMD3(dir.x * t, dir.y * t, 0.1), SIMD3(abs(dir.x) > 0.5 ? 0.55 : 0.5, abs(dir.y) > 0.5 ? 0.55 : 0.5, 0.06),
                       TM.f(j == 0 ? woodDark : 0xFFFBF2))
            }
        }
        hub.addChildNode(bm.node(name: "blades"))
        n.addChildNode(hub)
        return n
    }

    /// 熱氣球（iCloud）：拴在北邊的木樁上，飄在空中
    static func balloon() -> SCNNode {
        let t = VillageLayout.balloonTether
        let m = VoxelMesh(ao: 0), k = Kit(m: m)
        let bx = F(t.x) + 1.5, bz = F(t.z) + 2.5, by: Float = 5.5
        k.b(.identity, F(t.x), 0, F(t.z), 0.4, 0.8, 0.4, TM.f(woodDark))
        let rope = SIMD3<Float>(bx - F(t.x), by - 0.8, bz - F(t.z))
        let len = simd_length(rope)
        for i in 0..<Int(len / 0.5) {
            let p = SIMD3<Float>(F(t.x), 0.8, F(t.z)) + rope * (Float(i) * 0.5 / len)
            m.box(.identity, p, SIMD3(0.05, 0.5, 0.05), TM.f(0xD8CCB0))
        }
        k.b(.identity, bx, by - 0.2, bz, 1.0, 0.7, 1.0, VoxMat.tex("darkplank"))     // 籃子
        for (x, z) in [(-0.4, -0.4), (0.4, -0.4), (-0.4, 0.4), (0.4, 0.4)] as [(Float, Float)] { k.b(.identity, bx + x, by + 0.5, bz + z, 0.05, 1.0, 0.05, TM.f(0x7A6A55)) }
        let rows: [Float] = [1.2, 2.2, 2.9, 3.2, 3.3, 3.2, 2.9, 2.3, 1.4]
        for (i, r) in rows.enumerated() {
            let y = by + 1.5 + Float(i) * 0.5
            let col: UInt32 = i % 2 == 0 ? 0x5AA9E6 : 0xFFFFFF
            k.b(.identity, bx, y, bz, r, 0.5, r, TM.f(col))
            if i == 4 { k.b(.identity, bx, y, bz, r + 0.06, 0.18, r + 0.06, TM.f(0xF2C230)) }
        }
        return m.node(name: "city:cloud:iCloud")
    }

    /// 內建碟的小棚子（11-12 第三輪：倉庫讓給學校；東南邊不起眼的小木棚）
    static func diskShed() -> SCNNode {
        let b = VillageLayout.diskShed
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(b.cx), y: 0, z: F(b.cz))
        let w = F(b.w), d = F(b.d)
        k.b(xf, 0, 0, 0, w, 1.4, d, VoxMat.tex("darkplank"))
        k.b(xf, 0, 1.4, 0, w + 0.3, 0.12, d + 0.3, TM.f(0x6E4A2E))
        k.b(xf, 0, 0, d / 2 + 0.02, 0.8, 1.1, 0.05, TM.f(0x8A4B32))
        k.b(xf, w / 2 + 0.4, 0, 0.2, 0.5, 0.5, 0.5, VoxMat.tex("plank"))
        return m.node(name: "city:disk:內建碟")
    }

    /// 學校（研究資料夾）：奶白牆、紅屋頂、鐘樓掛金鐘、旁邊旗桿、門口招牌「學校」
    static func school() -> SCNNode {
        let b = VillageLayout.school
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(b.cx), y: 0, z: F(b.cz))
        let w = F(b.w), d = F(b.d), zf = d / 2
        let wall = VoxMat.dayNight(0xF6EBD3, 0x8E8678), trim = TM.f(0xB8463A)
        k.b(xf, 0, 0, 0, w + 0.3, 0.2, d + 0.3, TM.f(stone))
        k.b(xf, 0, 0.2, 0, w, 2.2, d, wall)
        k.b(xf, 0, 2.4, 0, w + 0.1, 0.12, d + 0.1, trim)
        roof(k, xf, y0: 2.52, w: w, d: d, steps: 4, rise: 0.3, inset: 0.4, TM.f(0xB8463A))
        // 鐘樓＋金鐘
        k.b(xf, 0, 3.6, 0, 0.9, 0.9, 0.9, wall)
        for x: Float in [-0.35, 0.35] { k.b(xf, x, 4.5, 0, 0.12, 0.6, 0.12, TM.f(woodDark)) }
        k.b(xf, 0, 4.45, 0, 0.36, 0.36, 0.36, TM.glow(0xF2C230, 0.3, 1.0))
        roof(k, xf, y0: 5.1, w: 0.9, d: 0.9, steps: 3, rise: 0.2, inset: 0.25, TM.f(0x8A3528), ridgeAlongX: false)
        // 門（紅門）、窗
        k.b(xf, 0, 0.2, zf + 0.02, 0.9, 1.6, 0.06, trim)
        for x: Float in [-1.25, 1.25] { k.b(xf, x, 0.9, zf + 0.02, 0.7, 0.7, 0.06, window); k.b(xf, x, 0.85, zf + 0.06, 0.8, 0.08, 0.08, TM.f(woodDark)) }
        // 旗桿
        k.b(xf, -w / 2 - 0.6, 0, zf - 0.3, 0.08, 3.6, 0.08, TM.f(0x8A8F94))
        k.b(xf, -w / 2 - 0.25, 3.0, zf - 0.3, 0.6, 0.4, 0.04, TM.f(0x3D8BD9))
        let n = m.node(name: "city:school")
        n.addChildNode(sign(board("學校", w: 1.3, h: 0.42, bg: 0x2F5E3A, fg: 0xFFF6DD, rim: 0xD4AF4F), w: 1.3, h: 0.42,
                            at: SCNVector3(b.cx, 2.0, b.cz + Double(zf) + 0.06), back: 0x23452B))
        return n
    }

    /// 新筆記的小星星
    static func star() -> SCNNode {
        let m = VoxelMesh()
        let g = VoxMat.flat(0xFFE07A, emit: (0.9, 1.6))
        m.box(.identity, SIMD3(0, 0, 0), SIMD3(0.5, 0.18, 0.12), g)
        m.box(.identity, SIMD3(0, 0, 0), SIMD3(0.18, 0.5, 0.12), g)
        m.box(.identity, SIMD3(0, 0, 0), SIMD3(0.3, 0.3, 0.12), g)
        return m.node(name: "star")
    }

    /// 頭上的「！」（紅底方塊＋白色驚嘆號，兩面都看得到）
    static func bang() -> SCNNode {
        let m = VoxelMesh()
        let red = VoxMat.flat(0xEF4444, emit: (0.6, 1.4)), white = VoxMat.flat(0xFFFFFF, emit: (0.6, 1.4))
        m.box(.identity, SIMD3(0, 0.42, 0), SIMD3(0.5, 0.84, 0.18), red)
        m.box(.identity, SIMD3(0, 0.52, 0), SIMD3(0.14, 0.4, 0.22), white)
        m.box(.identity, SIMD3(0, 0.18, 0), SIMD3(0.14, 0.13, 0.22), white)
        let n = m.node()
        let bill = SCNBillboardConstraint(); bill.freeAxes = .Y
        n.constraints = [bill]
        return n
    }

    /// 主人（看板的使用者）：原創的矮圓小人，暖橘色、圓滾滾（方塊疊出圓角）、大眼睛＋腮紅、頭頂一株綠芽。面向 +z
    static func boss() -> SCNNode {
        let root = SCNNode(); root.name = "boss"
        let body = SCNNode(); body.name = "body"
        root.addChildNode(body)
        let skin = VoxMat.flat(0xD97757, emit: (0.05, 0.35)), shade = VoxMat.flat(0xB85F42), ink = VoxMat.flat(0x2A1D18)
        let white = VoxMat.flat(0xFFFFFF), blush = VoxMat.flat(0xF2A07F), leaf = VoxMat.flat(0x5DBB63, emit: (0.1, 0.5))
        let m = VoxelMesh()
        // 圓滾滾的身體：中間最寬、上下各縮一圈
        m.box(.identity, SIMD3(0, 0.62, 0), SIMD3(0.86, 0.5, 0.76), skin)
        m.box(.identity, SIMD3(0, 0.95, 0), SIMD3(0.72, 0.18, 0.64), skin)
        m.box(.identity, SIMD3(0, 1.08, 0), SIMD3(0.52, 0.1, 0.46), skin)
        m.box(.identity, SIMD3(0, 0.33, 0), SIMD3(0.72, 0.1, 0.64), skin)
        // 大眼睛（含亮點）、腮紅、小嘴
        for x: Float in [-0.17, 0.17] {
            m.box(.identity, SIMD3(x, 0.76, 0.385), SIMD3(0.13, 0.17, 0.02), ink)
            m.box(.identity, SIMD3(x + 0.03, 0.8, 0.398), SIMD3(0.04, 0.05, 0.01), white)
            m.box(.identity, SIMD3(x * 1.7, 0.63, 0.385), SIMD3(0.12, 0.06, 0.02), blush)
        }
        m.box(.identity, SIMD3(0, 0.6, 0.385), SIMD3(0.1, 0.03, 0.02), ink)
        // 小手
        for x: Float in [-0.47, 0.47] { m.box(.identity, SIMD3(x, 0.55, 0.05), SIMD3(0.12, 0.18, 0.14), skin) }
        // 頭頂綠芽（兩片葉子）
        m.box(.identity, SIMD3(0, 1.2, 0), SIMD3(0.05, 0.16, 0.05), leaf)
        m.box(.identity, SIMD3(-0.1, 1.29, 0), SIMD3(0.16, 0.06, 0.1), leaf)
        m.box(.identity, SIMD3(0.1, 1.33, 0), SIMD3(0.16, 0.06, 0.1), leaf)
        body.addChildNode(m.node())
        // 短短的腳（走路會擺）
        for (x, name) in [(Float(-0.18), "legL"), (Float(0.18), "legR")] {
            let lm = VoxelMesh()
            lm.box(.identity, SIMD3(0, -0.13, 0.02), SIMD3(0.2, 0.26, 0.24), shade)
            let n = lm.node(); n.name = name; n.simdPosition = SIMD3(x, 0.28, 0)
            body.addChildNode(n)
        }
        body.scale = SCNVector3(1.45, 1.45, 1.45)
        let anchor = SCNNode(); anchor.name = "anchor"; anchor.position = SCNVector3(0, 2.15, 0)
        root.addChildNode(anchor)
        let halo = SCNTorus(ringRadius: 0.9, pipeRadius: 0.04)
        let hm = SCNMaterial(); hm.lightingModel = .constant; hm.diffuse.contents = NSColor.white; hm.emission.contents = NSColor.white
        halo.firstMaterial = hm
        let hn = SCNNode(geometry: halo); hn.name = "halo"; hn.position = SCNVector3(0, 0.06, 0); hn.isHidden = true
        root.addChildNode(hn)
        let hit = SCNBox(width: 1.4, height: 2.0, length: 1.3, chamferRadius: 0)
        hit.firstMaterial = SCNMaterial(); hit.firstMaterial!.transparency = 0; hit.firstMaterial!.writesToDepthBuffer = false
        let hitN = SCNNode(geometry: hit); hitN.name = "hitbox"; hitN.position = SCNVector3(0, 1.0, 0); hitN.isHidden = true
        root.addChildNode(hitN)
        OfficeBuilder.pickable(root)
        return root
    }

    /// 小狗（本機設定 petName 那位島民）：奶茶色身體、白胸口、深色耳朵、翹尾巴、金色項圈；四條腿各自一個節點（走路會擺）。面向 +z
    static func dog() -> SCNNode {
        let root = SCNNode(); root.name = "dog"
        let body = SCNNode(); body.name = "body"
        root.addChildNode(body)
        let fur = VoxMat.flat(0xD9A066, emit: (0, 0.3)), light = VoxMat.flat(0xFFF1DC, emit: (0, 0.3)), ear = VoxMat.flat(0x8A5A32), ink = VoxMat.flat(0x2A1D18)
        let m = VoxelMesh()
        m.box(.identity, SIMD3(0, 0.5, 0), SIMD3(0.5, 0.36, 0.78), fur)
        m.box(.identity, SIMD3(0, 0.46, 0.3), SIMD3(0.4, 0.3, 0.2), light)
        m.box(.identity, SIMD3(0, 0.82, 0.42), SIMD3(0.46, 0.42, 0.42), fur)
        m.box(.identity, SIMD3(0, 0.74, 0.68), SIMD3(0.26, 0.2, 0.16), light)
        m.box(.identity, SIMD3(0, 0.8, 0.77), SIMD3(0.1, 0.08, 0.04), ink)
        for x: Float in [-0.12, 0.12] { m.box(.identity, SIMD3(x, 0.9, 0.64), SIMD3(0.07, 0.09, 0.02), ink) }
        for x: Float in [-0.27, 0.27] { m.box(.identity, SIMD3(x, 0.84, 0.4), SIMD3(0.1, 0.32, 0.22), ear) }
        m.box(.identity, SIMD3(0, 0.62, 0.22), SIMD3(0.52, 0.08, 0.1), VoxMat.flat(0xE0B04A, emit: (0.3, 0.9)))
        m.box(.identity, SIMD3(0, 0.56, 0.3), SIMD3(0.1, 0.1, 0.04), VoxMat.flat(0xFFE07A, emit: (0.4, 1.0)))
        m.box(.identity, SIMD3(0, 0.78, -0.42), SIMD3(0.1, 0.32, 0.1), fur)
        m.box(.identity, SIMD3(0, 0.96, -0.46), SIMD3(0.1, 0.1, 0.1), light)
        body.addChildNode(m.node())
        for (x, z, name) in [(-0.16, 0.26, "legFL"), (0.16, 0.26, "legFR"), (-0.16, -0.26, "legBL"), (0.16, -0.26, "legBR")] as [(Float, Float, String)] {
            let lm = VoxelMesh()
            lm.box(.identity, SIMD3(0, -0.16, 0), SIMD3(0.13, 0.32, 0.13), fur)
            lm.box(.identity, SIMD3(0, -0.3, 0.02), SIMD3(0.14, 0.05, 0.16), light)
            let n = lm.node(); n.name = name; n.simdPosition = SIMD3(x, 0.33, z)
            body.addChildNode(n)
        }
        body.scale = SCNVector3(1.9, 1.9, 1.9)
        let anchor = SCNNode(); anchor.name = "anchor"; anchor.position = SCNVector3(0, 2.15, 0)
        root.addChildNode(anchor)
        let halo = SCNTorus(ringRadius: 0.9, pipeRadius: 0.04)
        let hm = SCNMaterial(); hm.lightingModel = .constant; hm.diffuse.contents = NSColor.white; hm.emission.contents = NSColor.white
        halo.firstMaterial = hm
        let hn = SCNNode(geometry: halo); hn.name = "halo"; hn.position = SCNVector3(0, 0.06, 0); hn.isHidden = true
        root.addChildNode(hn)
        let hit = SCNBox(width: 1.3, height: 1.9, length: 1.8, chamferRadius: 0)
        hit.firstMaterial = SCNMaterial(); hit.firstMaterial!.transparency = 0; hit.firstMaterial!.writesToDepthBuffer = false
        let hitN = SCNNode(geometry: hit); hitN.name = "hitbox"; hitN.position = SCNVector3(0, 0.95, 0); hitN.isHidden = true
        root.addChildNode(hitN)
        OfficeBuilder.pickable(root)
        return root
    }
}
