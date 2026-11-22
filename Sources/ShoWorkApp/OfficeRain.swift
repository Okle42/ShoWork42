import AppKit
import SceneKit
import simd
import ShoWorkCore

/// 3D 辦公室的雨與閃電（10-21 台北真實天氣，規範 §3.8.2）。
/// 雨：一個 SCNParticleSystem 掛在鏡頭底下（跟著鏡頭走，只蓋住看得到的那一塊：鏡頭前 10 公尺到 ≈ 鏡頭距離 ×0.7），
///     粒子在鏡頭座標落下（isLocal，10-23）、拉長成雨絲（stretchFactor）；雨量決定數量、風速決定傾斜（往畫面右邊斜）。
///     不下雨就整個拿掉 ⇒ 不會讓場景一直畫（晴天、多雲、陰天 CPU 跟沒有天氣一樣）。
/// 閃電：雷雨時 6–16 秒隨機閃一次（兩下）；用一盞平常關著的 ambient 光，閃完就藏起來。
@MainActor
final class WeatherFX {
    private let rig = SCNNode()
    private weak var camera: SCNNode?
    private var ps: SCNParticleSystem?
    private let flash = SCNNode()
    private(set) var weather = WeatherLook.clear
    private var dist: Float = 80
    private var dark = 0.0
    private var flashGen = 0
    /// 下雨中（粒子要動 ⇒ 場景要持續渲染）
    var raining: Bool { ps != nil }
    /// 測試：SHOWORK_OFFICE_FLASH=1 ⇒ 閃電一直亮著（截圖看閃光的樣子）
    private let holdFlash = OfficeView.testEnv("SHOWORK_OFFICE_FLASH") != nil

    /// 粒子數（整個雨區同時存在的雨絲）：雨量 0 → 400、1 → 3000
    static func particles(_ rain: Double) -> Double { 400 + 2600 * rain }
    /// 10-23 Kang：鏡頭拉近時雨看起來太密（雨盒變淺、雨絲離鏡頭近、每條都變大）⇒ 拉近減半：鏡頭距離 ≤40 → ×0.5、≥120 → ×1，中間線性
    static func closeFactor(_ dist: Float) -> Double { 0.5 + 0.5 * Double(min(1, max(0, (dist - 40) / 80))) }

    func attach(camera: SCNNode, scene: SCNScene) {
        self.camera = camera
        rig.name = "weather-rain"
        rig.renderingOrder = 1000       // 在擋雨盒（900）之後畫
        camera.addChildNode(rig)
        flash.light = SCNLight(); flash.light!.type = .ambient
        flash.light!.color = NSColor(srgbRed: 0.82, green: 0.86, blue: 1.0, alpha: 1)
        flash.light!.intensity = 0
        flash.isHidden = true
        scene.rootNode.addChildNode(flash)
    }

    /// 10-23 Kang（第二輪）：轉鏡頭後整座城市只有一面在下雨。雨掛在 builder.camera 底下，但真實視窗裡滑鼠拖曳
    /// 可能讓 SceneKit 換成另一個鏡頭節點 ⇒ 雨盒留在舊鏡頭的位置，從遠處看成一團小點。
    /// 每次鏡頭動完確認雨跟著「實際在畫的那台」鏡頭；只比一個指標，0 額外成本。回 true＝剛搬過
    @discardableResult
    func follow(_ pov: SCNNode?) -> Bool {
        guard let pov, rig.parent !== pov else { return false }
        pov.addChildNode(rig)
        camera = pov
        aim()
        return true
    }

    /// 地下室、鏡頭鑽進大樓裡時藏起來
    private var hidden = (underground: false, inside: false)
    func setHidden(_ h: Bool) { hidden.underground = h; rig.isHidden = hidden.underground || hidden.inside }
    func setInside(_ i: Bool) { hidden.inside = i; rig.isHidden = hidden.underground || hidden.inside }

    /// 10-23 Kang：雨穿進室內。雨盒在鏡頭前 10 公尺起、蓋住整個畫面；大樓是剖面（面向鏡頭的牆淡掉）⇒ 雨絲疊在樓層上，看起來像室內在下雨。
    /// 擋雨盒：大樓外框一個只寫深度、不畫顏色的盒子，排在大樓之後、雨之前畫。頂點著色器把每個頂點沿視線拉到離鏡頭 7 公尺
    /// （比雨盒的 10 公尺近、比 zNear 最大 4 遠）⇒ 螢幕上的輪廓跟大樓一樣，深度卻在所有雨絲前面 ⇒ 大樓那一塊不下雨，四周照下。
    /// GPU 每格自己算（跟著鏡頭轉不用 CPU 更新）；一個盒子 12 個三角形，跟著雨一起出現（晴天藏起來）。頂到頂樓花園地板（花園照樣下雨）
    private let shelterNode: SCNNode = {
        let n = SCNNode()
        n.name = "weather-shelter"
        n.renderingOrder = 900
        n.categoryBitMask = 1 << 20     // 不被燈光、點選當成大樓
        n.castsShadow = false
        n.isHidden = true
        return n
    }()
    private static let shelterMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = false
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.shaderModifiers = [.geometry: """
        float3 c = (scn_node.inverseModelViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
        float3 d = _geometry.position.xyz - c;
        _geometry.position.xyz = c + d * (7.0 / max(length(d), 0.001));
        """]
        return m
    }()

    func shelter(in parent: SCNNode, lo: SIMD3<Float>, hi: SIMD3<Float>) {
        if shelterNode.parent !== parent { parent.addChildNode(shelterNode) }
        let e = hi - lo
        let b = SCNBox(width: CGFloat(e.x), height: CGFloat(e.y), length: CGFloat(e.z), chamferRadius: 0)   // 實際尺寸（不用 scale：著色器量的是模型座標的長度）
        b.firstMaterial = Self.shelterMaterial
        shelterNode.geometry = b
        shelterNode.simdPosition = (lo + hi) / 2
    }

    /// 換天氣；回 true＝有變（畫面要重套燈光）
    func set(_ w: WeatherLook) -> Bool {
        guard w != weather else { return false }
        weather = w
        if w.rain > 0 {
            if ps == nil { let p = Self.makeRain(); rig.addParticleSystem(p); ps = p }
            configure()
        } else if let p = ps {
            rig.removeParticleSystem(p); ps = nil
        }
        shelterNode.isHidden = ps == nil
        flashGen += 1
        flash.isHidden = true; flash.light!.intensity = 0
        if w.lightning {
            if holdFlash { flash.isHidden = false; flash.light!.intensity = 800 } else { scheduleFlash(flashGen) }
        }
        return true
    }

    /// 天色暗度變了（日出日落／天氣）：雨絲顏色跟著換（白天淺灰、夜晚暗藍灰）
    func setDark(_ d: Double) {
        guard abs(d - dark) > 0.02 else { return }
        dark = d
        ps?.particleColor = color
    }

    /// 鏡頭距離變了（updateFog，鏡頭停下才算）：雨區深度跟著變
    func size(dist d: Float) {
        guard abs(d - dist) > max(2, dist * 0.1) else { return }
        dist = d
        if ps != nil { configure() }
    }

    /// 鏡頭停下來：雨絲方向重新對準（世界的「往下＋往畫面右邊斜」換成鏡頭座標）
    func aim() {
        guard let p = ps, let cam = camera?.presentation else { return }
        let r = cam.simdWorldRight
        var h = SIMD3<Float>(r.x, 0, r.z)
        h = simd_length(h) > 1e-4 ? simd_normalize(h) : SIMD3(1, 0, 0)
        let world = simd_normalize(SIMD3<Float>(0, -1, 0) + h * Float(weather.tilt))
        let local = cam.simdConvertVector(world, from: nil)
        p.emittingDirection = SCNVector3(local)
    }

    private var color: NSColor {
        let k = CGFloat(min(1, max(0, dark)))
        let a = CGFloat(0.32 + 0.22 * weather.rain)
        // 白天 #E6ECF5 → 夜晚 #8C9AB4
        return NSColor(srgbRed: 0.90 - 0.35 * k, green: 0.925 - 0.32 * k, blue: 0.96 - 0.255 * k, alpha: a)
    }

    private func configure() {
        guard let p = ps else { return }
        let w = weather
        // 看得到的那一塊：鏡頭前 near → far；垂直視角 34°（tan 17° ≈ 0.306），寬度照最寬 2:1 的視窗算
        let near: Float = 10, far = min(70, max(24, dist * 0.7))
        let halfH = 0.306 * far * 1.1, halfW = halfH * 2
        let v = Float(w.fallSpeed)
        let margin = halfH          // 上方多留一截：雨從畫面外落進來，上緣才不會稀
        let boxH = halfH * 2 + margin
        p.emitterShape = SCNBox(width: CGFloat(halfW * 2), height: CGFloat(boxH), length: CGFloat(far - near), chamferRadius: 0)
        rig.simdPosition = SIMD3(0, margin / 2, -(near + far) / 2)
        let life = boxH / v
        p.particleLifeSpan = CGFloat(life)
        p.particleLifeSpanVariation = CGFloat(life * 0.2)
        p.birthRate = CGFloat(Self.particles(w.rain) * Self.closeFactor(dist) / Double(life))
        p.particleVelocity = CGFloat(v)
        p.particleVelocityVariation = CGFloat(v * 0.12)
        p.particleSize = w.kind == .typhoon ? 0.026 : 0.018 + 0.006 * CGFloat(w.rain)
        p.stretchFactor = 0.03
        p.warmupDuration = CGFloat(life)        // 一開就是下到一半的樣子（截圖、剛打開都不會是空的）
        p.particleColor = color
        aim()
    }

    private static let dot: NSImage = {
        let n = 16
        let img = NSImage(size: NSSize(width: n, height: n))
        img.lockFocus()
        let g = NSGradient(colors: [.white, NSColor.white.withAlphaComponent(0)])!
        g.draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: n, height: n)), relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }()

    private static func makeRain() -> SCNParticleSystem {
        let p = SCNParticleSystem()
        p.particleImage = dot
        p.birthLocation = .volume
        p.birthDirection = .constant
        p.spreadingAngle = 2
        p.isAffectedByGravity = false
        p.isLightingEnabled = false
        p.blendMode = .alpha
        p.sortingMode = .none
        p.particleColorVariation = SCNVector4(0, 0, 0.05, 0.25)
        p.loops = true
        // 10-23 Kang：轉鏡頭時雨「只有那一塊」很不自然。原因：粒子預設活在世界座標，發射盒卻掛在鏡頭底下跟著轉 ⇒
        // 已落下的雨絲留在原地變成一塊雨方塊，新視野要等一整輪壽命才補滿。改成粒子活在鏡頭座標：雨幕永遠鋪滿畫面，
        // 粒子數、繪製量完全不變（0 額外成本）。鏡頭沒有翻滾，左右轉時「往下」在鏡頭座標不變；俯仰改變由 aim() 在停下時對準
        p.isLocal = true
        return p
    }

    private func scheduleFlash(_ gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 6...16)) { [weak self] in
            guard let self, self.flashGen == gen else { return }
            // 兩下：亮 0.12 秒、暗 0.1 秒、再亮 0.1 秒（12 fps 下每下至少一格）
            let steps: [(Double, CGFloat)] = [(0, 800), (0.12, 0), (0.22, 500), (0.32, 0)]
            for (t, i) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    guard let self, self.flashGen == gen else { return }
                    self.flash.light!.intensity = i
                    self.flash.isHidden = i == 0
                }
            }
            self.scheduleFlash(gen)
        }
    }
}
