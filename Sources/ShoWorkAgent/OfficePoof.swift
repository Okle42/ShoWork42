import AppKit
import SceneKit
import simd
import ShoWorkCore

// 忍術「ドロン」過場（10-21 Kang：關掉終端機，角色在 3D 裡憑空消失很突兀）。
//   離開：角色位置「砰」地爆出一團白灰體素煙（10 顆方塊往外往上擴散、放大、淡出），角色在煙最濃時縮到 0，0.8 秒後整團節點移除。
//   出現：反過來，先冒煙、角色從煙裡彈出來（略大再回原尺寸）。
// 曲線在 ShoWorkCore.PoofCurve（純函式，有單元測試）；這裡只是節點。一次性 SCNAction（customAction＋removeFromParentNode），不常駐；
// 煙的方塊共用一個 geometry＋一個材質（一個 draw call 一顆，0.8 秒內最多 10 個）。

final class Poof: @unchecked Sendable {
    let root: SCNNode
    let person: SCNNode?
    let appear: Bool
    private let puffs: [SCNNode]
    private let personScale: SCNVector3
    private let baseYaw: CGFloat

    /// 共用的煙：一個 0.42 立方的方塊、一個材質（淡灰白、微微自發光：白天夜晚都看得到）
    @MainActor static let cube: SCNBox = {
        let b = SCNBox(width: 0.42, height: 0.42, length: 0.42, chamferRadius: 0)
        let m = SCNMaterial()
        m.lightingModel = .lambert                // 有明暗才看得出是一顆顆方塊（.constant 會糊成一片白）
        m.diffuse.contents = VoxMat.color(0xE4E2DD)
        m.emission.contents = VoxMat.color(0xE4E2DD); m.emission.intensity = 0.35     // 夜晚也看得到
        m.writesToDepthBuffer = false            // 半透明的煙互相疊不要擋來擋去
        b.firstMaterial = m
        return b
    }()

    /// 在 parent 裡、角色所在位置建一團煙；person＝離開時要縮掉的角色（會被搬進煙的節點底下，煙散完一起移除）／出現時要彈出來的角色
    @MainActor init(at pos: SIMD3<Float>, in parent: SCNNode, person: SCNNode?, appear: Bool) {
        root = SCNNode(); root.name = "poof"
        root.simdPosition = pos
        self.person = person; self.appear = appear
        personScale = person?.scale ?? SCNVector3(1, 1, 1)
        baseYaw = person?.eulerAngles.y ?? 0
        var ps: [SCNNode] = []
        for _ in 0..<PoofCurve.puffs {
            let n = SCNNode(geometry: Self.cube); n.renderingOrder = 5
            root.addChildNode(n); ps.append(n)
        }
        puffs = ps
        parent.addChildNode(root)
        if let person, !appear {
            // 離開：角色搬進煙的節點底下（位置不變），煙散完整團一起移除
            let w = person.simdWorldTransform
            person.removeFromParentNode()
            root.addChildNode(person)
            person.simdWorldTransform = w
        }
    }

    /// 第 t 秒的樣子（定格截圖、動畫每幀都呼叫）。煙的中心在角色身體中間（1 公尺；坐著的 Kubo 身體約 1 公尺寬，煙一冒出來就要包住身體）
    func apply(_ t: Double) {
        for (i, n) in puffs.enumerated() {
            let p = PoofCurve.puff(i, at: t)
            n.simdPosition = SIMD3(Float(p.offset.x), Float(p.offset.y) + 1.0, Float(p.offset.z))
            n.scale = SCNVector3(p.scale, p.scale, p.scale)
            n.eulerAngles = SCNVector3(0.35, p.spin, 0.2)
            n.opacity = CGFloat(p.opacity)
            n.isHidden = p.opacity <= 0.001
        }
        if let person {
            let s = PoofCurve.person(at: t, appear: appear)
            person.scale = SCNVector3(personScale.x * CGFloat(s.scale), personScale.y * CGFloat(s.scale), personScale.z * CGFloat(s.scale))
            person.isHidden = s.scale <= 0.001
            person.eulerAngles.y = baseYaw + CGFloat(s.spin)
        }
    }

    /// 播一次：0.8 秒後拿掉煙（離開的話角色也一起）；出現的角色回到原尺寸、留在原位
    @MainActor func run() {
        apply(0)
        let a = SCNAction.customAction(duration: PoofCurve.duration) { [self] _, el in apply(Double(el)) }
        let finish = SCNAction.run { [self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish() } }
        }
        root.runAction(.sequence([a, finish]), forKey: "poof")
    }

    @MainActor func finish() {
        root.removeAllActions()
        if appear, let person { person.isHidden = false; person.scale = personScale; person.eulerAngles.y = baseYaw }
        root.removeFromParentNode()
    }
}
