import AppKit
import SceneKit
import simd
import ShoWorkCore

// 3D 辦公室第三版（10-20 Kang 拍板：名片徽章的「像素沙盒遊戲風 2.5D」）的底層零件：
//   像素材質（16×16 程式產生、最近鄰放大）、材質快取（同一種只建一次，夜晚只改發光強度）、
//   方塊合併器 VoxelMesh（整個靜態場景依材質合併成一個 geometry，一種材質一個 draw call）、像素字。
// 示意圖：~/Desktop/3D辦公室格局示意/*.png（mock.swift 產的），這裡照它的視覺做。

// MARK: - 像素材質

enum PixelTex {
    /// 固定種子的亂數（每次啟動材質都一樣）
    struct RNG {
        var s: UInt64
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 33) / Double(1 << 31) }
    }
    typealias RGB = (Double, Double, Double)

    static func c(_ h: UInt32, _ k: Double = 1) -> RGB {
        (min(1, Double(h >> 16 & 255) / 255 * k), min(1, Double(h >> 8 & 255) / 255 * k), min(1, Double(h & 255) / 255 * k))
    }

    /// 16×16 材質。10-20 坑：NSBitmapImageRep.setColor 遇到 sRGB 顏色會壞掉（整張貼圖無效、方塊整個不畫），所以直接寫 RGBA 位元組
    static func make(_ name: String, _ f: (Int, Int, inout RNG) -> RGB) -> CGImage? {
        let n = 16
        var px = [UInt8](repeating: 255, count: n * n * 4)
        var r = RNG(s: UInt64(name.unicodeScalars.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1.value) }) | 1)
        for y in 0..<n {
            for x in 0..<n {
                let col = f(x, y, &r), i = (y * n + x) * 4
                px[i] = UInt8(max(0, min(255, col.0 * 255))); px[i + 1] = UInt8(max(0, min(255, col.1 * 255)))
                px[i + 2] = UInt8(max(0, min(255, col.2 * 255))); px[i + 3] = 255
            }
        }
        return px.withUnsafeMutableBytes { buf -> CGImage? in
            guard let sp = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: sp,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
    static func noisy(_ base: UInt32, _ amp: Double) -> (Int, Int, inout RNG) -> RGB { { _, _, r in c(base, 1 - amp / 2 + r.next() * amp) } }

    /// 名稱 → 材質（只產一次）
    static let all: [String: CGImage] = {
        var t: [String: CGImage?] = [:]
        t["grass"] = make("grass", noisy(0x6aa84f, 0.35))
        t["dirtside"] = make("dirtside") { _, y, r in y < 4 + Int(r.next() * 2) ? c(0x6aa84f, 0.8 + r.next() * 0.3) : c(0x8b5a2b, 0.8 + r.next() * 0.35) }
        t["dirt"] = make("dirt", noisy(0x8b5a2b, 0.4))
        t["plank"] = make("plank") { x, y, r in
            let row = y / 4; let edge = y % 4 == 0 || (x + row * 5) % 16 == 0
            return c(0xc8955c, edge ? 0.72 : 0.92 + r.next() * 0.16)
        }
        t["darkplank"] = make("darkplank") { x, y, r in
            let edge = y % 4 == 0 || (x + (y / 4) * 7) % 16 == 0
            return c(0x7a4e2d, edge ? 0.7 : 0.9 + r.next() * 0.18)
        }
        t["stone"] = make("stone", noisy(0x9a9a9a, 0.3))
        t["cobble"] = make("cobble") { x, y, r in (x % 8 == 0 || (y + (x / 8) * 4) % 8 == 0) ? c(0x6b6b6b, 0.9) : c(0xa3a3a3, 0.8 + r.next() * 0.3) }
        t["leaf"] = make("leaf") { _, _, r in r.next() < 0.15 ? c(0x2e6b2e) : c(0x4caf50, 0.75 + r.next() * 0.4) }
        t["gold"] = make("gold") { x, y, r in (x + y) % 7 == 0 ? c(0xfff3a0) : c(0xf2c230, 0.85 + r.next() * 0.2) }
        t["wool"] = make("wool") { _, _, r in let v = 0.9 + r.next() * 0.1; return (v, v, v) }
        t["lantern"] = make("lantern") { x, y, r in (x < 3 || x > 12 || y < 3 || y > 12) ? c(0x3b3b3b) : c(0xffc95a, 0.85 + r.next() * 0.3) }
        return t.compactMapValues { $0 }
    }()
}

// MARK: - 材質快取

/// 同一種材質只建一次（10-20：靜態場景合併後，一種材質＝一個 draw call）。
/// 會發光的材質記下白天／夜晚兩個強度，切燈光時只改強度，不重建場景。
@MainActor
enum VoxMat {
    private static var cache: [String: SCNMaterial] = [:]
    private static var glowing: [(SCNMaterial, day: CGFloat, night: CGFloat)] = []
    private(set) static var night = false
    /// 10-21 日出日落：日夜底色依暗度混合、發光強度依「燈」混合（0＝白天、1＝夜晚）
    private(set) static var dark: CGFloat = 0, lamps: CGFloat = 0
    static func emitNow(_ e: (day: CGFloat, night: CGFloat)) -> CGFloat { (e.day + (e.night - e.day) * lamps) * power }
    /// 自己做的發光材質（招牌）也跟著日夜、停電一起變
    static func registerGlow(_ m: SCNMaterial, day: CGFloat, night: CGFloat) {
        m.emission.intensity = emitNow((day, night))
        glowing.append((m, day, night))
    }
    /// 電力（10-22 電廠＝AI 額度）：1＝正常、0.6 節電、0.35 吃緊、0 停電；所有發光材質一起乘
    private(set) static var power: CGFloat = 1
    @discardableResult
    static func setPower(_ p: CGFloat) -> Bool {
        let p = min(1, max(0, p))
        guard abs(p - power) > 0.001 else { return false }
        power = p
        for g in glowing { g.0.emission.intensity = emitNow((g.day, g.night)) }
        return true
    }
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        if t <= 0 { return a }
        if t >= 1 { return b }
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t, green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
    }

    /// 像素材質（可乘一個顏色＝羊毛地毯的染色）
    static func tex(_ name: String, tint: NSColor? = nil, emit: (day: CGFloat, night: CGFloat)? = nil) -> SCNMaterial {
        let key = "t:\(name)|\(tint.map(hex) ?? "")|\(emit.map { "\($0.day),\($0.night)" } ?? "")"
        if let m = cache[key] { return m }
        let m = SCNMaterial()
        m.diffuse.contents = PixelTex.all[name]
        if let tint { m.multiply.contents = tint }
        m.diffuse.magnificationFilter = .nearest           // 近看是一格一格的像素
        m.diffuse.minificationFilter = .linear; m.diffuse.mipFilter = .linear     // 遠看不閃爍（摩爾紋）
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.lightingModel = .lambert
        if let emit {
            m.emission.contents = PixelTex.all[name]; m.emission.magnificationFilter = .nearest
            m.emission.wrapS = .repeat; m.emission.wrapT = .repeat
            m.emission.intensity = emitNow(emit)
            glowing.append((m, emit.day, emit.night))
        }
        cache[key] = m
        return m
    }

    /// 純色方塊（螢幕框、咖啡杯、角色身體）；emit＝會發光（螢幕、寶石）
    static func flat(_ c: NSColor, emit: (day: CGFloat, night: CGFloat)? = nil) -> SCNMaterial {
        let key = "f:\(hex(c))|\(emit.map { "\($0.day),\($0.night)" } ?? "")"
        if let m = cache[key] { return m }
        let m = SCNMaterial()
        m.diffuse.contents = c
        m.lightingModel = .lambert
        if let emit {
            m.emission.contents = c
            m.emission.intensity = emitNow(emit)
            glowing.append((m, emit.day, emit.night))
        }
        cache[key] = m
        return m
    }
    static func flat(_ h: UInt32, emit: (day: CGFloat, night: CGFloat)? = nil) -> SCNMaterial { flat(color(h), emit: emit) }

    /// 白天、夜晚不同底色的純色（10-20 UI/UX 優化 §3.5：白天樓板側邊加深、後牆米色降一階，層與層才分得開）；切換時只改這幾個材質的顏色
    private static var dayNightMats: [(SCNMaterial, day: NSColor, night: NSColor)] = []
    static func dayNight(_ day: UInt32, _ nightHex: UInt32) -> SCNMaterial {
        let key = "dn:\(day)|\(nightHex)"
        if let m = cache[key] { return m }
        let m = SCNMaterial()
        let d = color(day), n = color(nightHex)
        m.diffuse.contents = mix(d, n, dark)
        m.lightingModel = .lambert
        dayNightMats.append((m, d, n))
        cache[key] = m
        return m
    }

    /// 日夜不同底色＋發光顏色另給（10-21 主光改版：路燈光池＝白天跟路面同色看不出來、夜晚暖色微亮）
    static func dayNight(_ day: UInt32, _ nightHex: UInt32, glow: UInt32, emit: (day: CGFloat, night: CGFloat)) -> SCNMaterial {
        let key = "dng:\(day)|\(nightHex)|\(glow)|\(emit.day),\(emit.night)"
        if let m = cache[key] { return m }
        let m = SCNMaterial()
        let d = color(day), n = color(nightHex)
        m.diffuse.contents = mix(d, n, dark)
        m.emission.contents = color(glow)
        m.emission.intensity = emitNow(emit)
        m.lightingModel = .lambert
        dayNightMats.append((m, d, n))
        glowing.append((m, emit.day, emit.night))
        cache[key] = m
        return m
    }

    /// 白天／夜晚：只改發光強度與日夜底色（材質是共用的，整個場景一起變）
    static func setNight(_ n: Bool) { setBlend(dark: n ? 1 : 0, lamps: n ? 1 : 0) }

    /// 日出日落（10-21）：暗度、燈連續混合；只改參數，不重建材質。值沒變就不動（回 false）
    @discardableResult
    static func setBlend(dark d: CGFloat, lamps l: CGFloat) -> Bool {
        let d = min(1, max(0, d)), l = min(1, max(0, l))
        guard abs(d - dark) > 0.001 || abs(l - lamps) > 0.001 else { return false }
        let dChanged = abs(d - dark) > 0.001
        dark = d; lamps = l; night = d >= 0.5
        for g in glowing { g.0.emission.intensity = emitNow((g.day, g.night)) }
        if dChanged { for x in dayNightMats { x.0.diffuse.contents = mix(x.day, x.night, d) } }
        return true
    }

    static var count: Int { cache.count }

    nonisolated static func color(_ h: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
    }
    nonisolated static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return c.description }
        return String(format: "%02x%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255), Int(s.alphaComponent * 255))
    }
}

// MARK: - 方塊合併器

/// 平面上的擺放：位置＋繞 Y 軸轉（跟 SCNNode.eulerAngles.y 同一個方向）
struct Xf {
    var x: Float = 0, y: Float = 0, z: Float = 0, a: Float = 0
    static let identity = Xf()

    func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(a), s = sin(a)
        return SIMD3(x + p.x * c + p.z * s, y + p.y, z - p.x * s + p.z * c)
    }
    func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(a), s = sin(a)
        return SIMD3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
    }
    /// 子座標系（child 是在這個座標系裡的擺放）
    func then(_ child: Xf) -> Xf {
        let p = apply(SIMD3(child.x, child.y, child.z))
        return Xf(x: p.x, y: p.y, z: p.z, a: a + child.a)
    }
    func at(_ x: Float, _ y: Float, _ z: Float, a: Float = 0) -> Xf { then(Xf(x: x, y: y, z: z, a: a)) }
    var vector: SCNVector3 { SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)) }
    func place(_ n: SCNNode) { n.position = vector; n.eulerAngles.y = CGFloat(a) }
}

/// 一堆方塊合併成一個 geometry：依材質分成幾個 element（一個 element＝一個 draw call）。
/// 10-20：原本每張桌子、每根柵欄都是自己的節點（上千個 draw call）；整層樓合併後只剩十幾個。
@MainActor
final class VoxelMesh {
    /// 材質怎麼貼：tile＝每幾公尺重複一次（地板、牆）；fit＝每一面剛好一張（葉子方塊、小東西）；
    /// sideFit＝側面橫向重複、縱向剛好一張（草地方塊的側面：上緣一條草）
    enum UV { case tile(Float), fit, sideFit(Float) }

    private var pos: [Float] = [], nrm: [Float] = [], tex: [Float] = [], col: [Float] = []
    /// 頂點色假 AO（10-21 主光改版，研究 R2-2-4）：nil＝不加；有值＝這個高度當地面（城市＝0）。
    /// 側面越靠地越暗（0–2.5 m：0.78→1）、頂面 1（貼地的頂面 0.97）、底面 0.7。頂點色只乘 diffuse、不乘自發光（窗、燈不受影響）
    private let aoBase: Float?
    init(ao: Float? = nil) { aoBase = ao }
    nonisolated static func aoSide(_ y: Float) -> Float {
        let t = min(max(y / 2.5, 0), 1)
        return 0.78 + 0.22 * t * t * (3 - 2 * t)
    }
    private var parts: [(SCNMaterial, [UInt32])] = []
    private var index: [ObjectIdentifier: Int] = [:]
    private(set) var boxes = 0
    /// 穿插稽核（SHOWORK_CITY_AUDIT）：非 nil 時記下每個方塊的世界位置、大小、角度
    var log: [CityBox]?

    var isEmpty: Bool { boxes == 0 }

    /// 6 面：法線、u 軸、v 軸（v 往下＝材質上緣在面的上緣）
    private static let faces: [(n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
        (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, -1, 0)),
        (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, -1, 0)),
        (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, -1, 0)),
        (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0)),
        (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)),
    ]

    /// 一個方塊：xf＝擺放的座標系，c＝中心（在 xf 裡），s＝長寬高。
    /// m＝6 面同一種；top／bottom 另外指定（草地方塊：上草、側邊泥土帶草、底泥土）
    func box(_ xf: Xf, _ c: SIMD3<Float>, _ s: SIMD3<Float>, _ m: SCNMaterial, top: SCNMaterial? = nil, bottom: SCNMaterial? = nil,
             uv: UV = .tile(1)) {
        boxes += 1
        log?.append(CityBox(center: xf.apply(c), size: s, yaw: xf.a))
        let h = s / 2
        for (k, f) in Self.faces.enumerated() {
            let mat = k == 4 ? (top ?? m) : k == 5 ? (bottom ?? m) : m
            let hu = abs(simd_dot(f.u, h)), hv = abs(simd_dot(f.v, h))
            let du = hu * 2, dv = hv * 2
            let center = c + f.n * h
            let base = UInt32(pos.count / 3)
            let wn = xf.rotate(f.n)
            for (su, sv) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                let p = xf.apply(center + f.u * (hu * su) + f.v * (hv * sv))
                pos += [p.x, p.y, p.z]; nrm += [wn.x, wn.y, wn.z]
                if let b = aoBase {
                    let a: Float = k == 4 ? (p.y - b < 0.3 ? 0.97 : 1) : k == 5 ? 0.7 : Self.aoSide(p.y - b)
                    col += [a, a, a, 1]
                }
                let fu = (su + 1) / 2, fv = (sv + 1) / 2
                switch uv {
                case .tile(let t): tex += [fu * du / t, fv * dv / t]
                case .fit: tex += [fu, fv]
                case .sideFit(let t): tex += k < 4 ? [fu * du / t, fv] : [fu * du / t, fv * dv / t]
                }
            }
            let i = slot(mat)
            parts[i].1 += [base, base + 2, base + 1, base, base + 3, base + 2]
        }
    }

    private func slot(_ m: SCNMaterial) -> Int {
        let k = ObjectIdentifier(m)
        if let i = index[k] { return i }
        parts.append((m, [])); index[k] = parts.count - 1
        return parts.count - 1
    }

    /// 合併成一個節點（一個 geometry、每種材質一個 element）
    func node(name: String? = nil) -> SCNNode {
        let n = SCNNode(); n.name = name
        guard !pos.isEmpty else { return n }
        let count = pos.count / 3
        let vs = SCNGeometrySource(data: pos.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex, vectorCount: count,
                                   usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let ns = SCNGeometrySource(data: nrm.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .normal, vectorCount: count,
                                   usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let ts = SCNGeometrySource(data: tex.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .texcoord, vectorCount: count,
                                   usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
        let els = parts.map { p in
            SCNGeometryElement(data: p.1.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                               primitiveCount: p.1.count / 3, bytesPerIndex: 4)
        }
        var srcs = [vs, ns, ts]
        if !col.isEmpty {
            srcs.append(SCNGeometrySource(data: col.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color, vectorCount: count,
                                          usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16))
        }
        let g = SCNGeometry(sources: srcs, elements: els)
        g.materials = parts.map(\.0)
        n.geometry = g
        return n
    }
}

// MARK: - 像素字

enum PixelText {
    /// 小字不反鋸齒畫進點陣圖、貼圖用最近鄰放大＝像素字（木牌、招牌）。
    /// 回傳 CGImage＋像素大小；直接寫 CGContext（不走 NSBitmapImageRep.setColor，同上面的坑）
    static func image(_ s: String, fg: NSColor, bg: NSColor, size: CGFloat = 11, padX: Int = 4, padY: Int = 2) -> (CGImage, Int, Int)? {
        let font = NSFont(name: "PingFang TC Semibold", size: size) ?? .boldSystemFont(ofSize: size)
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let ts = (s as NSString).size(withAttributes: a)
        let W = Int(ceil(ts.width)) + padX * 2, H = Int(ceil(ts.height)) + padY * 2
        guard let sp = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sp,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(bg.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setShouldAntialias(false); ctx.setAllowsAntialiasing(false)
        ctx.setShouldSmoothFonts(false); ctx.setAllowsFontSmoothing(false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (s as NSString).draw(at: NSPoint(x: CGFloat(padX), y: CGFloat(padY) - font.descender * 0.15), withAttributes: a)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return (img, W, H)
    }

    /// 像素字招牌：一塊平面，每 `pxPerMeter` 個像素一公尺
    @MainActor static func sign(_ s: String, fg: NSColor = .white, bg: NSColor, pxPerMeter: CGFloat = 32, size: CGFloat = 11) -> SCNNode {
        guard let (img, W, H) = image(s, fg: fg, bg: bg, size: size) else { return SCNNode() }
        let plane = SCNPlane(width: CGFloat(W) / pxPerMeter, height: CGFloat(H) / pxPerMeter)
        let m = SCNMaterial()
        m.diffuse.contents = img; m.diffuse.magnificationFilter = .nearest; m.diffuse.minificationFilter = .linear
        m.lightingModel = .constant; m.isDoubleSided = true
        plane.firstMaterial = m
        return SCNNode(geometry: plane)
    }
}
