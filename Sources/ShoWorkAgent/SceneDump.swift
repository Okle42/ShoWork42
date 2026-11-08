import AppKit
import SceneKit
import simd
import ShoWorkCore

// 場景 dump（11-01 Windows 版照搬量尺）：只在 `--office-bench dump`／`--office-bench kit`，或 city 模式加 SHOWORK_SCENE_DUMP=<資料夾> 時才開。
//   不開的時候 registry 是 nil，VoxelMesh 完全不多記東西，畫面行為不變。
//   輸出（JSON，格式跟 Windows 端 Web/bench 的 dump 一樣，windows/tools/scene_diff.py 拿兩份來比）：
//     mac-input.json        ＝餵給 OfficeBuilder.update／updateCity 的輸入（TowerPlan、decor、wander、islands、guardStatus、CityState）＋鏡頭常數
//     mac-scene-day.json／mac-scene-night.json ＝整個 scene graph：VoxelMesh 方塊（世界座標）、其他 geometry、燈光、6 個鏡頭
//   方塊的格式：c＝中心、s＝長寬高（已乘節點縮放）、yaw＝繞 Y 軸角度（節點＋Xf 合起來）、m／mt／mb＝側面／頂面／底面的材質 key、
//   p＝節點路徑（有名字的祖先用 / 接起來）、h＝實際有沒有被藏（任一祖先 isHidden）、o＝累乘的 opacity。

@MainActor
enum SceneDump {
    /// 一個 VoxelMesh 方塊（VoxelMesh 坐標系裡；材質記 element 的序號，dump 時讀 geometry 目前的材質）
    struct Box { var c: SIMD3<Float>; var s: SIMD3<Float>; var yaw: Float; var side: Int; var top: Int; var bottom: Int; var uv: String }

    /// geometry → 方塊清單；nil＝沒開 dump（VoxelMesh 不記）。geometry 本身也留著，避免被釋放後 ObjectIdentifier 被重複使用
    static var registry: [ObjectIdentifier: (geo: SCNGeometry, boxes: [Box], ao: Float?)]?
    static func enable() { if registry == nil { registry = [:] } }
    static func register(_ g: SCNGeometry, _ boxes: [Box], ao: Float?) { registry?[ObjectIdentifier(g)] = (g, boxes, ao) }

    // MARK: 數字

    static func r(_ x: Double, _ p: Double = 10000) -> Double { x.isFinite ? (x * p).rounded() / p : 0 }
    static func v3(_ v: SIMD3<Float>) -> [Double] { [r(Double(v.x)), r(Double(v.y)), r(Double(v.z))] }
    static func v3(_ v: SIMD3<Double>) -> [Double] { [r(v.x), r(v.y), r(v.z)] }
    static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "?" }
        func b(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", b(s.redComponent), b(s.greenComponent), b(s.blueComponent))
    }

    // MARK: 材質描述（Windows 端 kit.js matDesc 產一樣的 key）

    /// 貼圖反查名稱：PixelTex.all 的同一張 CGImage
    static func texName(_ any: Any?) -> String? {
        guard let a = any else { return nil }
        let o = a as AnyObject
        for (k, img) in PixelTex.all where (img as AnyObject) === o { return "tex:" + k }
        if CFGetTypeID(o) == CGImage.typeID { return "img" }
        if a is NSImage { return "img" }
        return nil
    }
    static func contents(_ p: SCNMaterialProperty) -> String? {
        if let t = texName(p.contents) { return t }
        if let c = p.contents as? NSColor { return hex(c) }
        if p.contents == nil { return nil }
        return "other"
    }
    static func lm(_ m: SCNMaterial.LightingModel) -> String {
        switch m {
        case .lambert: return "lambert"
        case .constant: return "constant"
        case .blinn: return "blinn"
        case .phong: return "phong"
        case .physicallyBased: return "pbr"
        default: return m.rawValue
        }
    }
    /// 材質 key：lm|d|m|e|ec|a|ds|zw|bm（Windows 端照同一個順序組）
    static func matKey(_ m: SCNMaterial) -> String {
        let d = contents(m.diffuse) ?? "#ffffff"
        var mul = contents(m.multiply) ?? ""
        if mul == "#ffffff" { mul = "" }
        var ec = contents(m.emission) ?? ""
        var e = Double(m.emission.intensity)
        if ec == "" || ec == "#000000" { ec = ""; e = 0 }
        let a = Double(m.transparency)
        let bm: String = m.blendMode == .alpha ? "alpha" : m.blendMode == .add ? "add" : "bm\(m.blendMode.rawValue)"
        return [lm(m.lightingModel), d, mul, String(format: "e%.2f", e), ec, String(format: "a%.2f", a),
                m.isDoubleSided ? "2s" : "1s", m.writesToDepthBuffer ? "zw" : "nz", bm].joined(separator: "|")
    }

    // MARK: 走訪

    struct Walk {
        var boxes: [[String: Any]] = []
        var geoms: [[String: Any]] = []
        var lights: [[String: Any]] = []
        var mats = Set<String>()
    }

    static func yawOf(_ w: simd_float4x4) -> Float {
        let x = simd_normalize(SIMD3(w.columns.0.x, w.columns.0.y, w.columns.0.z))
        return atan2(-x.z, x.x)          // 跟 Xf 同一個方向（local x → (cos a, 0, −sin a)）
    }

    static func walk(_ n: SCNNode, path: String, hidden: Bool, opacity: CGFloat, into w: inout Walk, only: String?) {
        let p = n.name.map { path.isEmpty ? $0 : path + "/" + $0 } ?? path
        let h = hidden || n.isHidden
        let o = opacity * n.opacity
        let take = only == nil || p.hasPrefix(only!)
        let wt = n.simdWorldTransform
        if take, let l = n.light {
            var d: [String: Any] = ["type": l.type.rawValue, "intensity": r(Double(l.intensity), 1000), "mask": l.categoryBitMask,
                                    "pos": v3(n.simdWorldPosition), "dir": v3(n.simdWorldFront), "p": p, "h": h]
            if let c = l.color as? NSColor { d["color"] = hex(c) } else { d["color"] = "other" }
            if l.type == .omni || l.type == .spot { d["att"] = [r(Double(l.attenuationStartDistance)), r(Double(l.attenuationEndDistance)), r(Double(l.attenuationFalloffExponent))] }
            if l.type == .spot { d["spot"] = [r(Double(l.spotInnerAngle)), r(Double(l.spotOuterAngle))] }
            w.lights.append(d)
        }
        if take, let g = n.geometry {
            let sx = simd_length(SIMD3(wt.columns.0.x, wt.columns.0.y, wt.columns.0.z))
            let sy = simd_length(SIMD3(wt.columns.1.x, wt.columns.1.y, wt.columns.1.z))
            let sz = simd_length(SIMD3(wt.columns.2.x, wt.columns.2.y, wt.columns.2.z))
            let up = simd_normalize(SIMD3(wt.columns.1.x, wt.columns.1.y, wt.columns.1.z))
            let tilt = abs(up.y) < 0.9999
            let keys = g.materials.map(matKey)
            keys.forEach { w.mats.insert($0) }
            if let reg = registry?[ObjectIdentifier(g)] {
                let ny = yawOf(wt)
                for b in reg.boxes {
                    let c4 = wt * SIMD4(b.c.x, b.c.y, b.c.z, 1)
                    func k(_ i: Int) -> String { i < keys.count ? keys[i] : "?" }
                    var d: [String: Any] = ["c": v3(SIMD3(c4.x, c4.y, c4.z)), "s": v3(b.s * SIMD3(sx, sy, sz)), "yaw": r(Double(ny + b.yaw)),
                                            "m": k(b.side), "p": p, "h": h, "o": r(Double(o), 1000), "uv": b.uv]
                    if b.top != b.side { d["mt"] = k(b.top) }
                    if b.bottom != b.side { d["mb"] = k(b.bottom) }
                    if reg.ao != nil { d["ao"] = r(Double(reg.ao!)) }
                    if tilt { d["tilt"] = true }
                    if n.categoryBitMask != 1 { d["cat"] = n.categoryBitMask }
                    w.boxes.append(d)
                }
            } else {
                var d: [String: Any] = ["type": String(describing: type(of: g)), "pos": v3(n.simdWorldPosition), "yaw": r(Double(yawOf(wt))),
                                        "scale": v3(SIMD3(sx, sy, sz)), "m": keys, "p": p, "h": h, "o": r(Double(o), 1000), "cat": n.categoryBitMask]
                if tilt { d["tilt"] = true; d["up"] = v3(up) }
                switch g {
                case let x as SCNPlane: d["params"] = ["w": r(Double(x.width)), "h": r(Double(x.height))]
                case let x as SCNBox: d["params"] = ["w": r(Double(x.width)), "h": r(Double(x.height)), "l": r(Double(x.length)), "chamfer": r(Double(x.chamferRadius))]
                case let x as SCNCylinder: d["params"] = ["r": r(Double(x.radius)), "h": r(Double(x.height))]
                case let x as SCNCone: d["params"] = ["r0": r(Double(x.topRadius)), "r1": r(Double(x.bottomRadius)), "h": r(Double(x.height))]
                case let x as SCNTorus: d["params"] = ["ring": r(Double(x.ringRadius)), "pipe": r(Double(x.pipeRadius))]
                case let x as SCNSphere: d["params"] = ["r": r(Double(x.radius))]
                case let x as SCNCapsule: d["params"] = ["r": r(Double(x.capRadius)), "h": r(Double(x.height))]
                case let x as SCNTube: d["params"] = ["ri": r(Double(x.innerRadius)), "ro": r(Double(x.outerRadius)), "h": r(Double(x.height))]
                default:
                    let (lo, hi) = g.boundingBox
                    d["params"] = ["bboxLo": v3(SIMD3<Float>(Float(lo.x), Float(lo.y), Float(lo.z))), "bboxHi": v3(SIMD3<Float>(Float(hi.x), Float(hi.y), Float(hi.z))),
                                   "verts": g.sources(for: .vertex).first?.vectorCount ?? 0]
                }
                w.geoms.append(d)
            }
        }
        for c in n.childNodes { walk(c, path: p, hidden: h, opacity: o, into: &w, only: only) }
    }

    /// 一個鏡頭（6 個 city 鏡頭各一份）：位置、朝向、fov、近遠裁切、霧距、目前被藏起來的節點（cutaway 跟鏡頭走）
    static func camera(_ b: OfficeBuilder, _ v: SCNView, name: String) -> [String: Any] {
        let n = v.pointOfView ?? b.camera
        let c = n.camera ?? b.camera.camera!
        let q = n.simdWorldOrientation
        let t = v.defaultCameraController.target
        var hidden: [String] = []
        func scan(_ x: SCNNode, _ path: String) {
            let p = x.name.map { path.isEmpty ? $0 : path + "/" + $0 } ?? path
            if x.isHidden { hidden.append(p); return }
            for ch in x.childNodes { scan(ch, p) }
        }
        scan(b.scene.rootNode, "")
        return ["name": name, "pos": v3(n.simdWorldPosition), "quat": [r(Double(q.imag.x)), r(Double(q.imag.y)), r(Double(q.imag.z)), r(Double(q.real))],
                "front": v3(n.simdWorldFront), "up": v3(n.simdWorldUp), "target": v3(SIMD3<Double>(Double(t.x), Double(t.y), Double(t.z))),
                "fov": r(Double(c.fieldOfView)), "vertical": c.projectionDirection == .vertical, "near": r(c.zNear), "far": r(c.zFar),
                "fogStart": r(Double(b.scene.fogStartDistance)), "fogEnd": r(Double(b.scene.fogEndDistance)),
                "fogColor": (b.scene.fogColor as? NSColor).map(hex) ?? "other", "fogExp": r(Double(b.scene.fogDensityExponent)),
                "hdr": c.wantsHDR, "bloom": r(Double(c.bloomIntensity)), "bloomThreshold": r(Double(c.bloomThreshold)), "bloomBlur": r(Double(c.bloomBlurRadius)),
                "vignette": r(Double(c.vignettingIntensity)), "vignettePower": r(Double(c.vignettingPower)), "hidden": hidden.sorted()]
    }

    /// 整個場景（或 only 開頭的子樹）
    static func scene(_ b: OfficeBuilder, night: Bool, cameras: [[String: Any]], only: String? = nil) -> [String: Any] {
        var w = Walk()
        walk(b.scene.rootNode, path: "", hidden: false, opacity: 1, into: &w, only: only)
        let bg: String
        if let imgs = b.scene.background.contents as? [CGImage] { bg = "cube\(imgs.count)" } else { bg = String(describing: type(of: b.scene.background.contents)) }
        return ["source": "mac", "night": night, "only": only ?? "", "boxes": w.boxes, "geoms": w.geoms, "lights": w.lights,
                "materials": w.mats.sorted(), "cameras": cameras,
                "env": ["background": bg, "bg": hex(OfficeBuilder.bg), "fogColor": (b.scene.fogColor as? NSColor).map(hex) ?? "other"]]
    }

    static func write(_ obj: Any, _ path: String) {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { print("dump：JSON 失敗 \(path)"); return }
        try? d.write(to: URL(fileURLWithPath: path))
        print("dump", path, "\(d.count / 1024) KB"); fflush(stdout)
    }

    // MARK: 通用 JSON 編碼（Mirror）：struct、class、enum（含 associated value）、Optional、Array、Set、Dictionary、tuple、Date、SIMD、NSColor

    static func json(_ v: Any, depth: Int = 0, seen: Set<ObjectIdentifier> = []) -> Any {
        if depth > 40 { return "<deep>" }
        switch v {
        case let x as String: return x
        case let x as Substring: return String(x)
        case let x as Character: return String(x)
        case let x as Bool: return x
        case let x as Date: return r(x.timeIntervalSince1970, 1000)
        case let x as URL: return x.absoluteString
        case let x as UUID: return x.uuidString
        case let x as Data: return "<data \(x.count)>"
        case let x as NSColor: return hex(x)
        case let x as SIMD2<Float>: return [r(Double(x.x)), r(Double(x.y))]
        case let x as SIMD3<Float>: return v3(x)
        case let x as SIMD4<Float>: return [r(Double(x.x)), r(Double(x.y)), r(Double(x.z)), r(Double(x.w))]
        case let x as SIMD2<Double>: return [r(x.x), r(x.y)]
        case let x as SIMD3<Double>: return v3(x)
        case let x as SIMD4<Double>: return [r(x.x), r(x.y), r(x.z), r(x.w)]
        case let x as CGFloat: return r(Double(x), 1e6)
        case let x as any BinaryInteger: return Int(truncatingIfNeeded: x)
        case let x as any BinaryFloatingPoint: return r(Double(x), 1e6)
        default: break
        }
        let m = Mirror(reflecting: v)
        if String(describing: type(of: v)).contains("->") { return "<fn>" }
        var seen = seen
        if m.displayStyle == .class {
            let id = ObjectIdentifier(v as AnyObject)
            if seen.contains(id) { return "<cycle>" }
            seen.insert(id)
        }
        switch m.displayStyle {
        case .optional:
            guard let c = m.children.first else { return NSNull() }
            return json(c.value, depth: depth + 1, seen: seen)
        case .collection:
            return m.children.map { json($0.value, depth: depth + 1, seen: seen) }
        case .set:
            let a = m.children.map { json($0.value, depth: depth + 1, seen: seen) }
            return a.sorted { "\($0)" < "\($1)" }
        case .dictionary:
            var o: [String: Any] = [:]
            for c in m.children {
                let kv = Array(Mirror(reflecting: c.value).children)
                guard kv.count == 2 else { continue }
                let k = json(kv[0].value, depth: depth + 1, seen: seen)
                o[k as? String ?? "\(k)"] = json(kv[1].value, depth: depth + 1, seen: seen)
            }
            return o
        case .tuple:
            if m.children.allSatisfy({ $0.label?.hasPrefix(".") ?? true }) { return m.children.map { json($0.value, depth: depth + 1, seen: seen) } }
            var o: [String: Any] = [:]
            for (i, c) in m.children.enumerated() { o[c.label ?? "\(i)"] = json(c.value, depth: depth + 1, seen: seen) }
            return o
        case .enum:
            // 沒有 associated value ⇒ 直接寫 case 名稱；有 ⇒ {"$case": 名稱, "$value": 內容}
            guard let c = m.children.first else { return String(describing: v) }
            return ["$case": c.label ?? String(describing: v), "$value": json(c.value, depth: depth + 1, seen: seen)]
        case .struct, .class:
            var o: [String: Any] = [:]
            var mm: Mirror? = m
            while let x = mm {
                for (i, c) in x.children.enumerated() {
                    var k = c.label ?? "\(i)"
                    if k.hasPrefix("_") && k.count > 1 { k.removeFirst() }      // property wrapper／lazy 的底線
                    if k.hasPrefix("$__lazy_storage_$_") { k = String(k.dropFirst("$__lazy_storage_$_".count)) }
                    if o[k] == nil { o[k] = json(c.value, depth: depth + 1, seen: seen) }
                }
                mm = x.superclassMirror
            }
            return o
        default:
            if m.children.isEmpty { return String(describing: v) }
            return m.children.map { json($0.value, depth: depth + 1, seen: seen) }
        }
    }

    /// 示範資料拿真實 session 當底（OfficeDemo.apply 的 base card）：家目錄、真實路徑、session 檔名換成假的再寫出去（輸入 JSON 會進 repo）
    static func scrub(_ v: Any) -> Any {
        let home = NSHomeDirectory()
        switch v {
        case let s as String:
            if s.hasPrefix(home) || s.hasPrefix("file://" + home) { return "/Users/demo/project" }
            return s
        case let a as [Any]: return a.map(scrub)
        case let o as [String: Any]:
            var out: [String: Any] = [:]
            for (k, x) in o { out[k] = ["cwd", "path", "transcript", "transcriptPath", "home"].contains(k) && x is String ? "/Users/demo/project" : scrub(x) }
            return out
        default: return v
        }
    }

    static func input(tower: TowerPlan, decor: [String: FloorDecor], wander: WanderPlan, islands: [Island], city: CityState) -> [String: Any] {
        let b = CityBuilder.bounds
        return ["source": "mac", "now": r(Date().timeIntervalSince1970, 1000),
                "tower": scrub(json(tower)), "decor": scrub(json(decor)), "wander": scrub(json(wander)), "islands": scrub(json(islands)),
                "guardStatus": scrub(json(GuardStatus())), "scanning": false, "city": scrub(json(city)),
                "size": [1600, 1000],
                // 鏡頭用到的常數（OfficeBench.cityShots／frameCity／updateFog）：JS 端照同樣的數學擺鏡頭
                "consts": ["cityBoundsLo": v3(b.lo), "cityBoundsHi": v3(b.hi), "branchX": r(Double(CityBuilder.branchX)), "laneZ": r(Double(CityBuilder.laneZ)),
                           "airshipDockZ": r(Double(CityBuilder.airshipDock(0).z)), "portX": r(Double(CityBuilder.portX)), "streetZ": r(Double(CityBuilder.streetZ)),
                           "basementBottomY": r(Double(OfficeBasement.bottomY)), "azimuth": r(Double(OfficeBuilder.azimuth)), "elevation": r(Double(OfficeBuilder.elevation))]]
    }

    // MARK: kit 測試場景（--office-bench kit）：地基本身的量尺

    /// 小場景：兩個白方塊（室內位元 1／戶外位元 16）、三件 TowerProps 家具、貼圖方塊、羊毛染色、日夜材質、玻璃、假 AO 柱、像素字。
    /// 只有 OfficeBuilder 的燈光、天空、霧、大地面；鏡頭固定。日／夜各存一張 PNG＋一份 dump（只 dump kit-test 子樹＋全部燈光）。
    /// Windows 端 Web/bench/kittest.js 照抄一樣的東西。
    static func kitScene() -> SCNNode {
        let root = SCNNode(); root.name = "kit-test"
        let m = VoxelMesh(), k = Kit(m: m)
        let white = TM.f(0xFFFFFF)
        k.b(.identity, 0, 0, 3, 1, 1, 1, white)
        let rack = TowerProps.all["server_rack"]!, cons = TowerProps.all["console1"]!, plant = TowerProps.all["plant_tall"]!
        let acc = TM.f(0x4A90E2)
        let ag: (CGFloat, CGFloat) -> SCNMaterial = { d, n in TM.glow(0x4A90E2, d, n) }
        rack.build(k, Xf(x: -3, y: 0, z: 0, a: 0), acc, ag)
        cons.build(k, Xf(x: -1, y: 0, z: 0.5, a: 0.4), acc, ag)
        plant.build(k, Xf.identity.at(1.5, 0, 0, a: -.pi / 2).at(0.3, 0, 0.2), acc, ag)
        m.box(Xf(x: 3.5, y: 0, z: 1, a: 0.3), SIMD3(0, 0.5, 0), SIMD3(1, 1, 1), VoxMat.tex("dirtside"), top: VoxMat.tex("grass"), bottom: VoxMat.tex("dirt"), uv: .sideFit(1))
        m.box(.identity, SIMD3(5, 0.25, 1), SIMD3(1.2, 0.5, 1.2), VoxMat.tex("wool", tint: VoxMat.color(0xC85A5A)), uv: .fit)
        m.box(.identity, SIMD3(-5, 0.5, 2), SIMD3(2, 1, 1), VoxMat.tex("plank"), uv: .tile(1))
        k.b(.identity, 5, 0, -1.5, 1, 0.6, 1, VoxMat.dayNight(0x8E8B85, TP.ST2))
        k.b(.identity, 6.5, 0, -1.5, 1, 0.6, 1, VoxMat.dayNight(TP.groundDay, TP.groundNight, glow: TP.LT1, emit: (0, 0.6)))
        k.b(.identity, -1, 0, 3, 1.5, 1.5, 0.1, TM.glass(0.15))
        k.b(.identity, 7.5, 0, 0.5, 0.6, 0.6, 0.6, TM.glow(0x6FD08C, 0.6, 1.5))
        let n = m.node(name: "kit-props")
        root.addChildNode(n)
        let mo = VoxelMesh(), ko = Kit(m: mo)
        ko.b(.identity, 2, 0, 3, 1, 1, 1, white)
        let out = mo.node(name: "kit-outdoor"); out.categoryBitMask = OfficeBuilder.outdoorMask
        root.addChildNode(out)
        let ma = VoxelMesh(ao: 0), ka = Kit(m: ma)
        ka.b(.identity, -2.5, 0, 3, 1, 3, 1, white)
        let ao = ma.node(name: "kit-ao"); ao.categoryBitMask = OfficeBuilder.outdoorMask
        root.addChildNode(ao)
        let sign = PixelText.sign("ABC 測試", bg: VoxMat.color(TP.INK))
        sign.name = "kit-sign"; sign.position = SCNVector3(0, 2.6, 2)
        root.addChildNode(sign)
        // omni 衰減量尺：一盞只照位元 64 的 omni（起點 1、終點 9、指數 2），下面一排白方塊吃得到（z −4）、旁邊一排一樣的吃不到（z −6，戶外位元）
        let mr = VoxelMesh(), kr = Kit(m: mr), mn = VoxelMesh(), kn = Kit(m: mn)
        for i in 0..<6 {
            kr.b(.identity, 10 + Float(i) * 1.5, 0, -4, 1, 0.4, 1, white)
            kn.b(.identity, 10 + Float(i) * 1.5, 0, -6, 1, 0.4, 1, white)
        }
        let rowLit = mr.node(name: "kit-omni-row"); rowLit.categoryBitMask = 64
        let rowRef = mn.node(name: "kit-omni-ref"); rowRef.categoryBitMask = OfficeBuilder.outdoorMask
        root.addChildNode(rowLit); root.addChildNode(rowRef)
        let o = SCNNode(); o.name = "kit-omni"; o.light = SCNLight(); o.light!.type = .omni
        o.light!.intensity = 1000; o.light!.color = VoxMat.color(0xFFFFFF)
        o.light!.attenuationStartDistance = 1; o.light!.attenuationEndDistance = 9; o.light!.attenuationFalloffExponent = 2
        o.light!.categoryBitMask = 64
        o.position = SCNVector3(10, 3, -4)
        root.addChildNode(o)
        return root
    }

    /// 量亮度的點（世界座標；畫面座標由 SCNRenderer.projectPoint 算，兩邊同一個鏡頭）
    static let kitProbes: [(String, SIMD3<Float>)] = [
        ("white-in-top", SIMD3(0, 1.0, 3)), ("white-in-front", SIMD3(0, 0.5, 3.5)), ("white-in-right", SIMD3(0.5, 0.5, 3)),
        ("white-out-top", SIMD3(2, 1.0, 3)), ("white-out-front", SIMD3(2, 0.5, 3.5)), ("white-out-right", SIMD3(2.5, 0.5, 3)),
        ("ao-front-low", SIMD3(-2.5, 0.3, 3.5)), ("ao-front-mid", SIMD3(-2.5, 1.25, 3.5)), ("ao-front-high", SIMD3(-2.5, 2.7, 3.5)),
        ("glow-front", SIMD3(7.5, 0.3, 0.8)), ("ground", SIMD3(1, 0, 5.5)), ("sky", SIMD3(0, 40, -150)),
    ] + (0..<6).flatMap { i -> [(String, SIMD3<Float>)] in
        let x = 10 + Float(i) * 1.5
        return [("omni-lit-\(i)", SIMD3(x, 0.4, -4)), ("omni-ref-\(i)", SIMD3(x, 0.4, -6))]
    }

    static func kitTest() -> Never {
        BoardWindow.testMode = true
        enable()
        OfficeBuilder.cutFade = 0
        let env = ProcessInfo.processInfo.environment
        let dir = env["SHOWORK_SCENE_DUMP"] ?? env["SHOWORK_BENCH_DIR"] ?? FileManager.default.currentDirectoryPath
        let b = OfficeBuilder()
        let size = CGSize(width: 1600, height: 1000)
        let v = SCNView(frame: NSRect(origin: .zero, size: size))
        v.scene = b.scene; v.pointOfView = b.camera
        b.scene.rootNode.childNodes.first?.addChildNode(kitScene())        // world
        guard let dev = MTLCreateSystemDefaultDevice() else { print("沒有 Metal"); exit(1) }
        let rr = SCNRenderer(device: dev, options: nil)
        rr.scene = b.scene
        for night in [false, true] {
            _ = b.setNight(night)
            b.placeTest(v, target: SIMD3(6.5, 1, -1.5), dist: 28, az: 20, el: 32)
            _ = b.updateLOD(camera: b.camera.position, target: v.defaultCameraController.target)
            rr.pointOfView = v.pointOfView ?? b.camera
            let img = rr.snapshot(atTime: 0, with: size, antialiasingMode: .none)
            let tag = night ? "night" : "day"
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/mac-kit-\(tag).png")); print("kit shot", "\(dir)/mac-kit-\(tag).png")
            }
            let probes: [[String: Any]] = kitProbes.map { name, p in
                let s = rr.projectPoint(SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z)))
                return ["name": name, "world": v3(p), "px": [r(Double(s.x), 10), r(Double(size.height - s.y), 10)]]     // 畫面座標：左上原點
            }
            var sc = scene(b, night: night, cameras: [camera(b, v, name: "kit")], only: "kit-test")
            var lw = Walk(); walk(b.scene.rootNode, path: "", hidden: false, opacity: 1, into: &lw, only: nil)
            sc["lights"] = lw.lights
            sc["probes"] = probes
            write(sc, "\(dir)/mac-kit-\(tag).json")
        }
        exit(0)
    }
}
