import AppKit
import Metal
import SceneKit
import ShoWorkCore

// 3D 辦公室的渲染量測（10-20 第四版）：ShoWorkAgent --office-bench <walk|move|still> [秒數] [fps]
// 測試視窗開在螢幕外，SceneKit 不推進動畫，量不到「有人在走」「搬家」時的 CPU；這裡用 SCNRenderer 畫進螢幕外的貼圖（不開任何視窗），
// 場景跟正式版同一個 OfficeBuilder（示範資料 all：21 人、5 個專案樓層），照指定 fps 一張一張畫，量這個行程的 CPU 時間。
//   walk  ＝閒晃（休息的 4 人照 WanderPlanner 上頂樓，最多同時 3 人在路上），預設 10 fps
//   move  ＝每 2.2 秒觸發一次搬家（某層跟上一層對調），24 fps
//   still ＝什麼都不動、照樣每幀畫（跟「閒置不渲染」比較用）
// 只是近似：沒有視窗合成、沒有 SwiftUI 疊層；GPU 時間不算在這個行程的 CPU 裡。

@MainActor
enum OfficeBench {
    static func run(mode: String, seconds: Double, fps: Double) -> Never {
        setenv("SHOWORK_OFFICE_DEMO", "all", 1)
        let s = BoardReader().read()
        let fm = FileManager.default
        let real = Board.build(sessions: s.sessions, transcripts: s.transcripts, glows: s.glows, teams: s.teams, inbox: s.inbox,
                               reports: s.reports, reviews: s.reviews, decisions: s.decisions, contexts: s.contexts, nicknames: s.nicknames,
                               now: Date(), home: BoardPaths.home, isRepo: { fm.fileExists(atPath: $0 + "/.git") })
        let demo = OfficeDemo.apply(real)
        // 閒晃：休息的人先當成在工作（坐在桌前），之後每 25 秒在「休息（搭電梯上頂樓）」與「工作（溜滑梯回座位）」之間切換
        func phase(_ idle: Bool) -> [BoardCard] {
            demo.map { c in var c = c; if c.project == "Demo-休息" && !c.unused && !idle { c.column = .active; c.reason = "工作中" }; return c }
        }
        var cards = mode == "walk" ? phase(false) : demo
        guard cards.first?.id.hasPrefix("demo-") == true else { print("bench：沒有任何 session 可以當示範資料的底"); exit(1) }
        let deps = OfficeDepartments.build(residents: [], cards: cards)
        let cache = OfficeDemo.TowerCache()
        var (tower, decor, wander) = cache.make(deps, cards: cards, real: [:])
        var islands = Islands.build(cards)
        OfficeBuilder.cutFade = 0          // 10-20 第 4 棒：原本牆的淡出動畫在 SCNRenderer 裡走不完，量到的是「正面玻璃＋直框都還在」的畫面
        let b = OfficeBuilder()
        _ = b.setNight(true)
        b.update(tower: tower, decor: decor, wander: wander, islands: islands, guardStatus: GuardStatus(), scanning: false, animate: true)
        let size = CGSize(width: 1600, height: 1000)
        let v = SCNView(frame: NSRect(origin: .zero, size: size))         // 只拿來算取景，不放進視窗
        v.scene = b.scene; v.pointOfView = b.camera
        b.frameCamera(v)
        _ = b.updateLOD(camera: b.camera.position, target: v.defaultCameraController.target)
        // rain（10-23）：颱風天＋鏡頭照 SHOWORK_BENCH_CAM=方位,仰角,距離 擺好，再以 SHOWORK_BENCH_ORBIT 度/秒繞著轉（模擬滑鼠拖曳），
        // 每 SHOWORK_BENCH_EVERY 秒（預設 2）存一張到 SHOWORK_BENCH_DIR ⇒ 看得到雨「落了一陣子、轉了一段」之後的樣子（螢幕外視窗不推進粒子）
        let env = ProcessInfo.processInfo.environment
        let rainCam = (env["SHOWORK_BENCH_CAM"] ?? "16,25,180").split(separator: ",").compactMap { Double($0) }
        let orbit = Double(env["SHOWORK_BENCH_ORBIT"] ?? "") ?? 0
        let rainEvery = Double(env["SHOWORK_BENCH_EVERY"] ?? "") ?? 2
        var nextRainShot = rainEvery
        func rainPlace(_ t: Double) {
            // SHOWORK_BENCH_TARGET=x,y,z：鏡頭看的點（預設大樓中心；10-24 看保全走路要對準廣場）
            let tg = (env["SHOWORK_BENCH_TARGET"] ?? "").split(separator: ",").compactMap { Double($0) }
            let c = tg.count == 3 ? SIMD3(tg[0], tg[1], tg[2]) : SIMD3(0, tower.totalHeight / 2, 0)
            b.placeTest(v, target: c, dist: rainCam[2], az: rainCam[0] + orbit * t, el: rainCam[1])
            _ = b.updateLOD(camera: b.camera.position, target: v.defaultCameraController.target)
        }
        if mode == "rain" {
            BoardWindow.testMode = true          // 鏡頭直接定位（不走 0.5 秒過場）
            _ = b.setWeather(WeatherLook.of(WeatherKind.preset(env["SHOWORK_BENCH_WEATHER"] ?? "typhoon")))
            rainPlace(0)
            // SHOWORK_BENCH_PATROL=1：保全馬上出門巡邏（10-23），配合 SHOWORK_BENCH_CAM 拉遠看整條路線
            if env["SHOWORK_BENCH_PATROL"] != nil {
                if CityMonitor.demo { b.updateCity(CityMonitor.demoState(), animate: false) }
                print("bench patrol 出發 \(b.startPatrol())")
            }
        }
        let trips = wander.states.values.filter { $0.trip != nil }.count
        print("bench mode=\(mode) fps=\(fps) 秒=\(seconds) 路上的人=\(trips) \(b.stats())"); fflush(stdout)

        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { print("沒有 Metal"); exit(1) }
        let r = SCNRenderer(device: dev, options: nil)
        r.scene = b.scene; r.pointOfView = b.camera
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width) * 2, height: Int(size.height) * 2, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let tex = dev.makeTexture(descriptor: td)!
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: td.width, height: td.height, mipmapped: false)
        dd.usage = .renderTarget; dd.storageMode = .private
        let depth = dev.makeTexture(descriptor: dd)!

        func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
        let c0 = cpu(), t0 = Date()
        var frames = 0, lastMove = 0.0, flip = false, maxTrips = 0, probed = false, shot = false
        var poofStep = 0, base = 0, afterOut = 0
        let wall = DispatchTime.now()
        while Date().timeIntervalSince(t0) < seconds {
            let t = Date().timeIntervalSince(t0)
            if mode == "move", t - lastMove > 2.2 {
                // 把最上面兩個專案樓層對調（模擬固定號碼的專案進出造成換位置）
                lastMove = t; flip.toggle()
                var fl = tower.floors
                let idx = fl.indices.filter { fl[$0].kind == .project }
                if idx.count >= 2 {
                    let a = idx[idx.count - 2], c = idx[idx.count - 1]
                    let ya = fl[a].y; fl.swapAt(a, c); fl[a].y = ya; fl[c].y = ya + fl[a].height
                    tower = TowerPlan(floors: fl)
                    b.update(tower: tower, decor: decor, wander: wander, islands: islands, guardStatus: GuardStatus(), scanning: false, animate: true)
                    _ = b.updateLOD(camera: b.camera.position, target: v.defaultCameraController.target)     // 跟正式版一樣：每次更新後補算 cutaway
                }
            }
            if mode == "walk", t - lastMove > 25 || frames == 2 {
                lastMove = t; flip.toggle()
                cards = phase(flip); islands = Islands.build(cards)
                (tower, decor, wander) = cache.make(deps, cards: cards, real: [:])
                b.update(tower: tower, decor: decor, wander: wander, islands: islands, guardStatus: GuardStatus(), scanning: false, animate: true)
                _ = b.updateLOD(camera: b.camera.position, target: v.defaultCameraController.target)
                let n = wander.states.values.filter { $0.trip != nil }.count
                maxTrips = max(maxTrips, n)
                print(String(format: "bench t=%.1f %@：出發 %d 人（最長 %.0f 秒）", t, flip ? "去休息" : "回去工作", n,
                             wander.states.values.compactMap { $0.trip?.duration }.max() ?? 0)); fflush(stdout)
            }
            // poof：第 0.5 秒拿掉一個人（離開過場）、第 2 秒放回來（出現過場）；每個階段印節點數，結束要回到原本的數量
            if mode == "poof" {
                let victim = cards.first { $0.project == "Demo-動作" && !$0.unused }?.id ?? ""
                func upd(_ cs: [BoardCard]) {
                    b.update(tower: tower, decor: decor, wander: wander, islands: Islands.build(cs), guardStatus: GuardStatus(), scanning: false, animate: true)
                }
                if poofStep == 0, t > 0.5 { poofStep = 1; base = b.nodeCount; upd(cards.filter { $0.id != victim })
                    print("bench poof 離開 開始 nodes \(base) → \(b.nodeCount)（煙 10 顆＋煙的根）"); fflush(stdout) }
                if poofStep == 1, t > 0.9 { poofStep = 2; print("bench poof 離開 第 0.4 秒 nodes \(b.nodeCount)"); fflush(stdout) }
                if poofStep == 2, t > 1.6 { poofStep = 3; afterOut = b.nodeCount; print("bench poof 離開 結束 nodes \(afterOut)（少了那個人的節點）"); fflush(stdout)
                    upd(cards); print("bench poof 出現 開始 nodes \(b.nodeCount)"); fflush(stdout) }
                if poofStep == 3, t > 2.8 { poofStep = 4
                    print("bench poof 出現 結束 nodes \(b.nodeCount)（應＝原本 \(base)）\(b.nodeCount == base ? " OK" : " 不一致")"); fflush(stdout) }
            }
            if mode == "move", !probed, t - lastMove > 1.0, lastMove > 0 {
                probed = true
                let ys = b.scene.rootNode.childNodes.flatMap(\.childNodes).filter { $0.name?.hasPrefix("floor:p:") == true }
                    .map { String(format: "%@ y=%.2f z=%.2f", $0.name!, $0.presentation.position.y, $0.presentation.position.z) }
                print("bench 搬家中第 1 秒：", ys.joined(separator: "、")); fflush(stdout)
            }
            // SHOWORK_BENCH_SHOT=<png>：閒晃第 SHOWORK_BENCH_SHOT_T 秒（預設 8）存一張（看路線有沒有穿過家具）
            if let out = ProcessInfo.processInfo.environment["SHOWORK_BENCH_SHOT"], !shot,
               t >= Double(ProcessInfo.processInfo.environment["SHOWORK_BENCH_SHOT_T"] ?? "") ?? 8 {
                shot = true
                let img = r.snapshot(atTime: t, with: size, antialiasingMode: .multisampling2X)
                if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out)); print("bench shot", out); fflush(stdout)
                }
            }
            if mode == "rain" {
                // SHOWORK_BENCH_SCAN=開始秒,結束秒：模擬按「立即掃描」（保全要馬上出門、掃描結束重建時接著走不跳回）
                let scan = (env["SHOWORK_BENCH_SCAN"] ?? "").split(separator: ",").compactMap { Double($0) }
                if scan.count == 2, let on = [scan[0], scan[1]].firstIndex(where: { t >= $0 && t - 1 / fps < $0 }) {
                    b.update(tower: tower, decor: decor, wander: wander, islands: islands, guardStatus: GuardStatus(), scanning: on == 0, animate: true)
                    print("bench scan \(on == 0 ? "開始" : "結束") t=\(t)"); fflush(stdout)
                }
                // SHOWORK_BENCH_CTRL=1：改用 SceneKit 內建鏡頭控制器轉（跟滑鼠拖曳同一條路）
                if orbit != 0 {
                    if env["SHOWORK_BENCH_CTRL"] != nil {
                        v.defaultCameraController.rotateBy(x: Float(orbit / fps), y: 0)
                        if v.pointOfView !== b.camera { print("bench 控制器換了鏡頭：\(v.pointOfView?.name ?? "nil")"); fflush(stdout); r.pointOfView = v.pointOfView }
                        _ = b.updateLOD(camera: b.camera.position, target: v.defaultCameraController.target)
                    } else { rainPlace(t) }
                }
                if let dir = env["SHOWORK_BENCH_DIR"], t >= nextRainShot {
                    let out = String(format: "%@/rain_t%04.1f_az%03.0f.png", dir, t, rainCam[0] + orbit * t)
                    nextRainShot += rainEvery
                    let img = r.snapshot(atTime: t, with: size, antialiasingMode: .multisampling2X)
                    if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out)); print("bench shot", out); fflush(stdout)
                    }
                }
            }
            if mode == "walk", frames % 50 == 0 {
                let walkers = b.peopleNodes().filter { $0.1.parent?.parent == nil || $0.1.parent === b.scene.rootNode.childNodes.first }.count
                if walkers > 0 { print("bench t=\(Int(t)) 路上節點 \(walkers)"); fflush(stdout) }
            }
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = tex; pd.colorAttachments[0].loadAction = .clear; pd.colorAttachments[0].storeAction = .store
            pd.depthAttachment.texture = depth; pd.depthAttachment.loadAction = .clear; pd.depthAttachment.storeAction = .dontCare
            let cb = q.makeCommandBuffer()!
            r.render(atTime: t, viewport: CGRect(origin: .zero, size: CGSize(width: td.width, height: td.height)), commandBuffer: cb, passDescriptor: pd)
            cb.commit(); cb.waitUntilCompleted()
            frames += 1
            // 主執行緒要讓出來：customAction 播完的回呼走 DispatchQueue.main
            RunLoop.main.run(until: Date(timeIntervalSince1970: t0.timeIntervalSince1970 + Double(frames) / fps))
        }
        let secs = Double(DispatchTime.now().uptimeNanoseconds - wall.uptimeNanoseconds) / 1e9
        let used = cpu() - c0
        print(String(format: "bench %@：%d 張／%.1f 秒（%.1f fps），CPU %.2f 秒 ＝ 平均 %.1f%%（單核）", mode, frames, secs, Double(frames) / secs, used, used / secs * 100))
        print("bench after", b.stats())
        exit(0)
    }
}
