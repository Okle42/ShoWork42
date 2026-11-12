import AppKit
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

    struct Person { var node: SCNNode; var look: String; var goal: VPoint; var face: Double; var spot: VillageSpot; var resident: VillageResident }
    private var persons: [String: Person] = [:]
    private var homeNodes: [SCNNode] = []
    private var homeSig = ""
    private var stallNode: SCNNode?
    private var stallSig = ""
    private var wellNode: SCNNode?
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
        add(VillageArt.sea())
        add(VillageArt.terrain())
        add(VillageArt.townhall(), pick: true)
        add(VillageArt.company(), pick: true)
        for (k, n) in [("windmill", VillageArt.windmill()), ("balloon", VillageArt.balloon()), ("warehouse", VillageArt.warehouse())] {
            facilityNodes[k] = n; add(n, pick: true)
        }
        // 夜晚：廣場、店屋、公司小屋三盞暖燈（強度跟著天色／停電，setLamps）
        for p in [SCNVector3(0, 4.5, 3), SCNVector3(-12, 4.2, 1), SCNVector3(12, 4.2, 1), SCNVector3(0, 4.5, -6.5)] {
            let l = SCNNode(); l.light = SCNLight(); l.light!.type = .omni
            l.light!.color = VoxMat.color(0xFFD9A0); l.light!.attenuationStartDistance = 2; l.light!.attenuationEndDistance = 15
            l.position = p; l.isHidden = true
            root.addChildNode(l); lamps.append(l)
        }
        dog = VillageArt.dog()
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
    }

    // MARK: 更新（看板刷新時）

    /// 回傳要播幾秒（走路、跳一下）
    func update(_ islanders: [Islander], animate: Bool, now: Date = Date()) -> TimeInterval {
        buildIfNeeded()
        let cards = islanders.map(\.card)
        VillageStore.remember(cards, now: now)
        let p = VillageStore.plan(cards, now: now)
        let first = persons.isEmpty && plan.residents.isEmpty
        plan = p
        updateShop(p.shopName)
        updateStalls(p.stalls)
        updateHomes(p.homes)
        obstacles = VillageLayout.obstacles(stallCount: p.stalls.count)
        let acc = Dictionary(islanders.map { ($0.id, $0.accessory) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        for r in p.residents where r.spot != .home {
            guard let c = r.card else { continue }
            seen.insert(r.id)
            let (goal, face) = r.spot == .work ? VillageLayout.workSpot(zone: r.zone, stall: r.stall, slot: r.slot) : VillageLayout.plazaSpot(r.slot)
            let isl = Islander(card: c, mood: r.mood ?? .idle, accessory: acc[r.id] ?? nil)
            let look = "\(isl.mood.rawValue)|\(isl.accessory?.rawValue ?? "")|\(c.activity.rawValue)|\(r.needsAnswer)|\(c.subagents.count)"
            if var old = persons[r.id] {
                if old.look != look {
                    let n = makeNode(isl, r, intro: old.resident.mood != r.mood)
                    n.position = old.node.position; n.eulerAngles = old.node.eulerAngles
                    let halo = old.node.childNode(withName: "halo", recursively: false)?.isHidden ?? true
                    n.childNode(withName: "halo", recursively: false)?.isHidden = halo
                    old.node.removeFromParentNode(); root.addChildNode(n)
                    old.node = n; old.look = look
                }
                // 換地點才走；在廣場晃的人留在晃到的地方（不要每次刷新都走回原位）
                let moved = old.spot != r.spot || (r.spot == .work && old.goal.dist(goal) > 0.05)
                if moved {
                    bump(walk(old.node, to: goal, face: face, speed: Self.walkSpeed, animate: animate))
                    old.goal = goal; old.face = face; old.spot = r.spot
                }
                old.resident = r
                persons[r.id] = old
            } else {
                let n = makeNode(isl, r, intro: !first)
                root.addChildNode(n)
                // 剛上線：從自己家門口走出來（第一次載入直接到位）
                let start = !first && animate ? r.home.map(VillageLayout.homeDoor) ?? goal : goal
                n.simdPosition = SIMD3(Float(start.x), 0, Float(start.z)); n.eulerAngles.y = CGFloat(face)
                if start != goal { bump(walk(n, to: goal, face: face, speed: Self.walkSpeed, animate: animate)) }
                persons[r.id] = Person(node: n, look: look, goal: goal, face: face, spot: r.spot, resident: r)
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
        if !ambientStarted { ambientStarted = true; scheduleAmbient() }
        defer { transient = 0 }
        return transient
    }

    var looping: Bool { persons.values.contains { $0.resident.mood == .working && $0.resident.card?.activity == .editing } }

    private func makeNode(_ isl: Islander, _ r: VillageResident, intro: Bool) -> SCNNode {
        guard let o = owner else { return SCNNode() }
        let n = o.makePerson(isl, seated: false, atDesk: false, intro: intro)
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
                let a = Double.random(in: 0..<(2 * .pi)), r = Double.random(in: 3.0...6.5)
                let q = VPoint(VillageLayout.plaza.x + sin(a) * r, VillageLayout.plaza.z + cos(a) * r)
                if VillageLayout.walkable(q, obstacles: obstacles) {
                    t = max(t, walk(dog, to: q, face: Double.random(in: -1.5...1.5), speed: Self.dogSpeed * 0.6, animate: true))
                }
            }
        }
        if let id = persons.filter({ $0.value.spot == .plaza && $0.value.node.action(forKey: "walk") == nil }).keys.randomElement(), var p = persons[id] {
            let a = Double.random(in: 0..<(2 * .pi)), r = Double.random(in: 2.2...VillageLayout.plazaRadius + 1.5)
            let q = VPoint(VillageLayout.plaza.x + sin(a) * r, VillageLayout.plaza.z + cos(a) * r)
            if VillageLayout.walkable(q, obstacles: obstacles), !persons.values.contains(where: { $0.goal.dist(q) < 1.0 }) {
                let face = Double.random(in: -.pi...(.pi))
                t = max(t, walk(p.node, to: q, face: face, speed: Self.walkSpeed * 0.7, animate: true))
                p.goal = q; p.face = face; persons[id] = p
            }
        }
        if t > 0 { onPlay?(t) }
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
        let lv = Int((VillageSigns.water(s.grid) * 10).rounded())
        let sig = "\(lv)"
        if sig != wellSig {
            wellSig = sig
            wellNode?.removeFromParentNode()
            let w = VillageArt.well(level: Float(lv) / 10)
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
            return OfficeBuilder.LabelPerson(id: id, anchor: a, card: p.resident.card, mood: p.resident.mood ?? .idle, floor: "village")
        }
        if let a = dog.childNode(withName: "anchor", recursively: true) {
            out.append(OfficeBuilder.LabelPerson(id: "dog", anchor: a, card: nil, mood: .idle, floor: "village"))
        }
        return out
    }

    func peopleNodes() -> [(String, SCNNode)] { persons.map { ($0.key, $0.value.node) } + [("dog", dog)] }
    func personNode(_ id: String) -> SCNNode? { id == "dog" ? dog : persons[id]?.node }

    func highlight(_ id: String?) {
        func set(_ n: SCNNode?, _ h: Bool) { if let n, n.isHidden != h { n.isHidden = h } }
        for (pid, p) in persons { set(p.node.childNode(withName: "halo", recursively: false), pid != id) }
        set(dog.childNode(withName: "halo", recursively: false), id != "dog")
    }

    /// 城市 id／地點 → 島上的點（鏡頭飛過去、警告牌錨點）
    func point(_ id: String) -> SCNVector3? {
        func v(_ p: VPoint, _ y: Double) -> SCNVector3 { SCNVector3(p.x, y, p.z) }
        if id == "city:cooler" || id == facilityIds["windmill"] { return v(VillageLayout.windmill, 7.2) }
        if id == "city:power" || id == "city:fuel" { return v(VillageLayout.well, 3.0) }
        if id.hasPrefix("city:cloud:") { return SCNVector3(VillageLayout.balloonTether.x + 1.5, 9.5, VillageLayout.balloonTether.z + 2.5) }
        if id.hasPrefix("city:disk:") { return v(VPoint(VillageLayout.warehouse.cx, VillageLayout.warehouse.cz), 4.2) }
        return nil
    }

    /// 左側清單點地點：鏡頭對準哪裡、框多大（公尺）
    func focus(_ id: String) -> (SIMD3<Double>, Double)? {
        let key = id.hasPrefix("place:") ? String(id.dropFirst(6)) : id
        func r(_ b: VRect, _ k: Double = 1.6) -> (SIMD3<Double>, Double) { (SIMD3(b.cx, 1.6, b.cz + 1.5), max(b.w, b.d) * k) }
        switch key {
        case "townhall": return r(VillageLayout.townhall)
        case "shop": return r(VillageLayout.shop)
        case "company": return r(VillageLayout.company)
        case "plaza": return (SIMD3(VillageLayout.plaza.x, 1, VillageLayout.plaza.z), 11)
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

    static func sea() -> SCNNode {
        let m = VoxelMesh(), k = Kit(m: m)
        k.b(.identity, 0, -1.6, 0, 420, 1.0, 420, VoxMat.dayNight(0x4E9FC4, 0x1A3049))
        // 淺灘：比海面亮一階的一圈
        let R = F(VillageLayout.radius) + 6
        var z = -R
        while z <= R {
            let hw = (R * R - z * z).squareRoot()
            if hw > 0.5 { k.b(.identity, 0, -0.7, z, hw * 2, 0.12, 1.02, VoxMat.dayNight(0x7CC7DA, 0x274766)) }
            z += 1
        }
        return m.node(name: "sea")
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
        lane(VPoint(-4.4, 2.2), VPoint(-12, 0.6)); lane(VPoint(-12, 0.6), VPoint(-12, -1.2), w: 2.2)
        lane(VPoint(4.4, 2.2), VPoint(12, 0.4)); lane(VPoint(12, 0.4), VPoint(12, -1.6), w: 2.0)
        lane(VPoint(-2.4, 7.0), VPoint(-8.5, 10.2)); lane(VPoint(2.4, 7.0), VPoint(8.5, 10.2))
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
        let bx: Float = 2.6, bz = F(VillageLayout.radius) + 5.5
        k.b(.identity, bx, -0.8, bz, 1.3, 0.4, 3.0, TM.f(0xE7E2D6)); k.b(.identity, bx, -0.45, bz, 1.0, 0.1, 2.6, TM.f(0xB8463A))
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

    static func townhall() -> SCNNode {
        let b = VillageLayout.townhall
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(b.cx), y: 0, z: F(b.cz))
        let w = F(b.w), d = F(b.d), zf = d / 2
        let wall = VoxMat.dayNight(0xF4EEE2, 0x8C887F), trim = TM.f(0xC8B48A), roofM = VoxMat.dayNight(0x4C6A8C, 0x26364A)
        k.b(xf, 0, 0, 0, w + 0.5, 0.3, d + 0.5, TM.f(stone))
        k.b(xf, 0, 0.3, 0, w, 3.2, d, wall)
        k.b(xf, 0, 3.5, 0, w + 0.1, 0.18, d + 0.1, trim)
        roof(k, xf, y0: 3.68, w: w, d: d, steps: 5, roofM)
        // 鐘塔
        k.b(xf, 0, 4.6, -0.4, 1.7, 1.8, 1.7, wall)
        k.b(xf, 0, 5.6, 0.46, 1.0, 1.0, 0.02, TM.glow(0xFFF6DD, 0.25, 1.2))
        k.b(xf, 0, 6.06, 0.48, 0.06, 0.42, 0.02, TM.f(ink)); k.b(xf, 0.15, 6.06, 0.48, 0.32, 0.06, 0.02, TM.f(ink))
        roof(k, xf.at(0, 0, -0.4), y0: 6.4, w: 1.6, d: 1.6, steps: 3, rise: 0.3, inset: 0.35, roofM)
        // 旗子
        k.b(xf, 0, 7.3, -0.4, 0.07, 1.4, 0.07, TM.f(0x5A5A5A)); k.b(xf, 0.4, 8.2, -0.4, 0.75, 0.45, 0.04, TM.f(0x4CAF50))
        // 門、柱、台階、窗
        k.b(xf, 0, 0.3, zf + 0.02, 1.3, 2.1, 0.08, TM.f(woodDark))
        k.b(xf, 0, 0, zf + 0.5, 2.6, 0.15, 0.8, TM.f(stone))
        for x: Float in [-1.1, 1.1] { k.b(xf, x, 0.3, zf + 0.35, 0.36, 3.2, 0.36, TM.f(0xFFFFFF)) }
        k.b(xf, 0, 3.3, zf + 0.35, 3.0, 0.24, 0.7, trim)
        for x: Float in [-2.6, -1.9, 1.9, 2.6] { k.b(xf, x, 1.3, zf + 0.02, 0.5, 0.9, 0.06, window) }
        for x: Float in [-2.3, 2.3] { k.b(xf, x, 2.5, zf + 0.02, 1.2, 0.6, 0.06, window) }
        let n = m.node(name: "place:townhall")
        n.addChildNode(sign(board("鎮公所", w: 2.0, h: 0.5, bg: 0x2F4A68, fg: 0xFFF3D6, rim: 0xD4AF4F), w: 2.0, h: 0.5,
                            at: SCNVector3(b.cx, 2.75, b.cz + Double(zf) + 0.42), back: 0x2F4A68))
        return n
    }

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
        n.addChildNode(suv())
        return n
    }

    /// 休旅車（深灰、車頭朝 +z）
    static func suv() -> SCNNode {
        let c = VillageLayout.shopCar
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(c.cx), y: 0, z: F(c.cz))
        let body = TM.f(0x3C4248), glass = TM.f(0x1F2B35), tire = TM.f(0x161616), rim = TM.f(0xB0B4B8)
        k.b(xf, 0, 0.32, 0, 1.95, 0.78, 4.1, body)
        k.b(xf, 0, 1.1, -0.25, 1.8, 0.72, 2.9, body)
        k.b(xf, 0, 1.18, -0.25, 1.84, 0.54, 2.6, glass)
        k.b(xf, 0, 1.18, 1.06, 1.7, 0.5, 0.06, glass)
        k.b(xf, 0, 1.84, -0.25, 1.5, 0.08, 2.4, TM.f(0x222222))           // 車頂架
        for (x, z) in [(-0.92, 1.3), (0.92, 1.3), (-0.92, -1.35), (0.92, -1.35)] as [(Float, Float)] {
            k.b(xf, x, 0, z, 0.32, 0.68, 0.68, tire); k.b(xf, x + (x > 0 ? 0.17 : -0.17), 0.2, z, 0.02, 0.28, 0.28, rim)
        }
        for x: Float in [-0.65, 0.65] { k.b(xf, x, 0.72, 2.06, 0.42, 0.18, 0.04, TM.glow(0xFFFBEA, 0.3, 1.8)); k.b(xf, x, 0.76, -2.06, 0.36, 0.16, 0.04, TM.glow(0xD7263D, 0.3, 1.2)) }
        k.b(xf, 0, 0.45, 2.06, 0.9, 0.2, 0.04, TM.f(0x8A8F94))
        return m.node(name: "suv")
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

    /// 水井（AI 額度）：石圈、木頂、水位＝5 小時額度剩多少
    static func well(level: Float) -> SCNNode {
        let c = VillageLayout.well
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(c.x), y: 0, z: F(c.z))
        let st = VoxMat.tex("cobble")
        k.b(xf, 0, 0, 0.62, 1.5, 0.8, 0.26, st); k.b(xf, 0, 0, -0.62, 1.5, 0.8, 0.26, st)
        k.b(xf, 0.62, 0, 0, 0.26, 0.8, 1.0, st); k.b(xf, -0.62, 0, 0, 0.26, 0.8, 1.0, st)
        k.b(xf, 0, 0, 0, 1.0, 0.05 + 0.7 * level, 1.0, level > 0.02 ? TM.glow(0x4FA6E0, 0.2, 0.6) : TM.f(0x6B5A44))
        for x: Float in [-0.62, 0.62] { k.b(xf, x, 0.8, 0, 0.14, 1.3, 0.14, TM.f(woodDark)) }
        k.b(xf, 0, 2.1, 0, 0.14, 0.14, 1.4, TM.f(woodDark))
        roof(k, xf, y0: 2.15, w: 1.6, d: 1.3, steps: 3, rise: 0.22, inset: 0.3, TM.f(0x8A4B32))
        k.b(xf, 0.1, 1.35, 0, 0.26, 0.28, 0.26, TM.f(wood))       // 水桶
        return m.node(name: "city:power")
    }

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

    /// 倉庫小屋（內建碟）：木板牆、紅棕屋頂、穀倉門、門口幾個木箱
    static func warehouse() -> SCNNode {
        let b = VillageLayout.warehouse
        let m = VoxelMesh(ao: 0), k = Kit(m: m), xf = Xf(x: F(b.cx), y: 0, z: F(b.cz))
        let w = F(b.w), d = F(b.d), zf = d / 2
        k.b(xf, 0, 0, 0, w, 2.3, d, VoxMat.tex("darkplank"))
        roof(k, xf, y0: 2.3, w: w, d: d, steps: 4, rise: 0.32, inset: 0.4, TM.f(0x8A4B32))
        k.b(xf, 0, 0, zf + 0.02, 1.5, 1.8, 0.06, TM.f(0xB8463A))
        k.b(xf, 0, 0.1, zf + 0.06, 1.5, 0.1, 0.04, TM.f(0xF4EEE2)); k.b(xf, 0, 1.6, zf + 0.06, 1.5, 0.1, 0.04, TM.f(0xF4EEE2))
        for (x, y, z) in [(1.4, 0, zf + 0.7), (1.0, 0, zf + 1.2), (1.2, 0.6, zf + 0.9)] as [(Float, Float, Float)] {
            k.b(xf, x, y, z, 0.6, 0.6, 0.6, VoxMat.tex("plank"))
        }
        return m.node(name: "city:disk:內建碟")
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

    /// 小狗（主人）：奶茶色身體、白胸口、深色耳朵、翹尾巴、金色項圈；四條腿各自一個節點（走路會擺）。面向 +z
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
