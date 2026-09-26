// Claude Island — 仿動態島的 Claude Code 狀態提示
// 概念改編自 Okle42/ShoWork42：用 tty 精準對到視窗、內側燈條、完成要看過才清、同視窗取最緊急、選單列總覽
// 用法：claude-island run | wait | tick | done | hide   （hook 的 JSON 從 stdin 讀）
import AppKit
import SwiftUI

let notifName = Notification.Name("claude-island.state")
let pidPath = NSHomeDirectory() + "/.claude/island/island.pid"
let _ = try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.claude/island", withIntermediateDirectories: true)

enum Phase: String { case running = "run", waiting = "wait", done = "done", hidden = "hide", tick = "tick" }

extension Phase {
    /// 同一個視窗有好幾個分頁時，亮最緊急的（授權 > 完成 > 處理中）
    var priority: Int { switch self { case .waiting: return 3; case .done: return 2; case .running: return 1; default: return 0 } }
    var label: String { switch self { case .waiting: return "等你授權"; case .done: return "完成了"; case .running: return "處理中"; default: return "" } }
    var nsColor: NSColor {
        switch self {
        case .waiting: return NSColor(srgbRed: 1, green: 0.624, blue: 0.039, alpha: 1)
        case .done: return NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)
        default: return NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
        }
    }
}

struct Payload {
    var phase: Phase, session: String, project: String, detail: String, bundle: String, tty: String, pid: Int32
    var dict: [String: String] {
        ["phase": phase.rawValue, "session": session, "project": project, "detail": detail, "bundle": bundle, "tty": tty, "pid": String(pid)]
    }
    init(phase: Phase, session: String, project: String, detail: String, bundle: String, tty: String, pid: Int32) {
        self.phase = phase; self.session = session; self.project = project; self.detail = detail
        self.bundle = bundle; self.tty = tty; self.pid = pid
    }
    init?(_ d: [AnyHashable: Any]?) {
        guard let d = d, let p = Phase(rawValue: d["phase"] as? String ?? "") else { return nil }
        self.init(phase: p, session: d["session"] as? String ?? "", project: d["project"] as? String ?? "",
                  detail: d["detail"] as? String ?? "", bundle: d["bundle"] as? String ?? "com.apple.Terminal",
                  tty: d["tty"] as? String ?? "", pid: Int32(d["pid"] as? String ?? "") ?? 0)
    }
}

// MARK: - 顏色（Apple 系統色）
extension Color {
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let sysGreen = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let sysOrange = Color(red: 1.0, green: 0.624, blue: 0.039)  // #FF9F0A
}

let spring = Animation.spring(response: 0.5, dampingFraction: 0.78)

// MARK: - 終端機：tty → 視窗（Terminal／iTerm2 的 AppleScript 視窗 id 就是 CGWindowID）
enum Term {
    static func run(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    static func windowID(bundle: String, tty: String) -> Int? {
        guard tty.hasPrefix("/dev/tty") else { return nil }
        switch bundle {
        case "com.apple.Terminal":
            return run("""
                tell application id "com.apple.Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(tty)" then return id of w
                    end repeat
                  end repeat
                end tell
                """).map { Int($0.int32Value) }.flatMap { $0 > 0 ? $0 : nil }
        case "com.googlecode.iterm2":
            return run("""
                tell application id "com.googlecode.iterm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "\(tty)" then return id of w
                      end repeat
                    end repeat
                  end repeat
                end tell
                """).map { Int($0.int32Value) }.flatMap { $0 > 0 ? $0 : nil }
        default: return nil
        }
    }

    // MARK: Ghostty（AppleScript 查不到 tty → 照 ShoWork42：往 tty 寫一次性 OSC 7 記號，找出帶記號的分頁）
    static let ghosttyID = "com.mitchellh.ghostty"

    static func writeTTY(_ tty: String, _ s: String) {
        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return }
        _ = s.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
    static var host: String { var b = [CChar](repeating: 0, count: 256); gethostname(&b, 255); return String(cString: b) }

    static func ghosttyNames(_ list: [[String: Any]], pid: pid_t) -> [(Int, String?)] {
        list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { w in (w[kCGWindowNumber as String] as? Int).map { ($0, w[kCGWindowName as String] as? String) } }
    }

    /// 回傳（視窗 CGWindowID, Ghostty terminal id）
    static func ghostty(tty: String, pid: Int32) -> (Int?, String?) {
        guard tty.hasPrefix("/dev/tty"),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyID).first else { return (nil, nil) }
        let nonce = "island-probe-\(UInt32.random(in: 100000...999999))"
        writeTTY(tty, "\u{1b}]7;file://\(host)/\(nonce)\u{07}")
        Thread.sleep(forTimeInterval: 0.12)
        let r = run("""
            tell application id "com.mitchellh.ghostty"
              repeat with w in windows
                repeat with t in terminals of w
                  if working directory of t contains "\(nonce)" then return {id of t, name of w, name of t}
                end repeat
              end repeat
            end tell
            """)
        let cwd = pid > 0 ? (processCWD(pid) ?? NSHomeDirectory()) : NSHomeDirectory()
        writeTTY(tty, "\u{1b}]7;file://\(host)\(cwd)\u{07}")               // 還原工作資料夾
        guard let r = r, r.numberOfItems == 3, let tid = r.atIndex(1)?.stringValue else { return (nil, nil) }
        let wname = r.atIndex(2)?.stringValue ?? "", tname = r.atIndex(3)?.stringValue ?? ""
        let names = ghosttyNames(windows(), pid: app.processIdentifier)
        if names.allSatisfy({ $0.1 == nil }), !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()                                // 視窗標題要「螢幕錄製」權限才讀得到
            log("Ghostty：需要螢幕錄製權限才能讀視窗標題，先用最前面的視窗")
            return (nil, tid)
        }
        let same = names.filter { $0.1 == wname }.map { $0.0 }
        if same.count == 1 { return (same[0], tid) }
        // 好幾個視窗同名：暫時把這個分頁的標題改成記號，看是哪個視窗，再改回來
        writeTTY(tty, "\u{1b}]2;\(nonce)\u{07}")
        Thread.sleep(forTimeInterval: 0.15)
        let hit = ghosttyNames(windows(), pid: app.processIdentifier).first { $0.1 == nonce }?.0
        writeTTY(tty, "\u{1b}]2;\(tname)\u{07}")
        return (hit, tid)
    }

    /// Claude 會把分頁標題設成對話主題（前面帶 ✳ 或轉圈符號），拿來當膠囊名稱最好認
    static func topic(bundle: String, tty: String, gid: String? = nil) -> String? {
        guard tty.hasPrefix("/dev/tty") else { return nil }
        let src: String
        switch bundle {
        case ghosttyID:
            guard let gid = gid else { return nil }
            src = "tell application id \"com.mitchellh.ghostty\" to return name of terminal id \"\(gid)\""
        case "com.apple.Terminal":
            src = """
                tell application id "com.apple.Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(tty)" then return custom title of t
                    end repeat
                  end repeat
                end tell
                """
        case "com.googlecode.iterm2":
            src = """
                tell application id "com.googlecode.iterm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "\(tty)" then return name of s
                      end repeat
                    end repeat
                  end repeat
                end tell
                """
        default: return nil
        }
        guard var t = run(src)?.stringValue else { return nil }
        while let c = t.unicodeScalars.first, !c.properties.isAlphabetic, !CharacterSet.decimalDigits.contains(c) {
            t.unicodeScalars.removeFirst()                         // 去掉 ✳ ◐ ⠋ 之類的符號
        }
        t = t.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: " — ") { t = String(t[..<r.lowerBound]) }
        return (t.isEmpty || t == "Claude Code" || t == "claude") ? nil : t
    }

    /// 跳到那個視窗、選到那個分頁
    static func jump(bundle: String, tty: String, gid: String? = nil) {
        if bundle == ghosttyID, let gid = gid {
            _ = run("tell application id \"com.mitchellh.ghostty\" to focus terminal id \"\(gid)\"")
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        guard tty.hasPrefix("/dev/tty") else { return }
        if bundle == "com.apple.Terminal" {
            _ = run("""
                tell application id "com.apple.Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        return
                      end if
                    end repeat
                  end repeat
                end tell
                """)
        } else if bundle == "com.googlecode.iterm2" {
            _ = run("""
                tell application id "com.googlecode.iterm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                          select t
                          select w
                          return
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                """)
        }
    }

    static func windows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }
    static func frontWindow(pid: pid_t, in list: [[String: Any]]) -> Int? {
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.width > 150, r.height > 100 else { continue }
            return w[kCGWindowNumber as String] as? Int
        }
        return nil
    }
    static func bounds(_ wid: Int, in list: [[String: Any]]) -> CGRect? {
        for w in list where (w[kCGWindowNumber as String] as? Int) == wid {
            if let b = w[kCGWindowBounds as String] as? NSDictionary { return CGRect(dictionaryRepresentation: b) }
        }
        return nil
    }
}

let logPath = NSHomeDirectory() + "/.claude/island/island.log"
func log(_ m: String) {
    let line = "\(Date()) \(m)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(toFile: logPath, atomically: true, encoding: .utf8) }
}

// MARK: - 單一 Claude 對話（一個專案一個膠囊）
final class Session: ObservableObject, Identifiable {
    let id: String
    @Published var phase: Phase = .hidden
    @Published var compact = false          // 完成 8 秒後縮成小顆，等你看過才消失
    @Published var project = ""
    @Published var detail = ""
    @Published var startedAt = Date()
    @Published var elapsed: TimeInterval = 0
    var bundle: String
    var tty: String
    var pid: Int32
    var wid: Int?
    var gid: String?          // Ghostty 的 terminal id
    var lastEvent = Date()
    var folder = ""
    var pending: DispatchWorkItem?
    weak var hub: Hub?

    init(id: String, bundle: String, tty: String, pid: Int32, hub: Hub) {
        self.id = id; self.bundle = bundle; self.tty = tty; self.pid = pid; self.hub = hub
    }

    var height: CGFloat { (phase == .running || compact) ? 30 : 44 }

    func apply(_ p: Payload) {
        lastEvent = Date()
        if p.pid > 0 { pid = p.pid }
        if p.phase == .tick {           // 工具跑完：從「等授權」回到「處理中」
            guard phase == .waiting else { return }
            withAnimation(spring) { phase = .running; detail = "" }
            hub?.changed()
            return
        }
        if p.phase == .hidden { hub?.remove(self, "SessionEnd"); return }
        pending?.cancel()
        if !p.project.isEmpty { folder = p.project }
        project = Term.topic(bundle: bundle, tty: tty, gid: gid) ?? folder
        withAnimation(spring) {
            compact = false
            switch p.phase {
            case .running:
                if phase != .running && phase != .waiting { startedAt = Date() }
                detail = ""; phase = .running
            case .waiting:
                detail = p.detail; phase = .waiting
            case .done:
                elapsed = (phase == .running || phase == .waiting) ? Date().timeIntervalSince(startedAt) : 0
                detail = p.detail; phase = .done
            default: break
            }
        }
        if p.phase == .done {
            let w = DispatchWorkItem { [weak self] in withAnimation(spring) { self?.compact = true }; self?.hub?.changed() }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
        }
        hub?.changed()
    }

    func tapped() {
        Term.jump(bundle: bundle, tty: tty, gid: gid)
        if phase == .done { hub?.remove(self, "點膠囊") }
    }
}

// MARK: - 所有膠囊＋光暈＋選單列
final class Hub: NSObject, ObservableObject {
    @Published var sessions: [Session] = []
    var panel: NSPanel!
    var glows: [Int: GlowController] = [:]      // 每個視窗一圈
    var status: NSStatusItem?
    var timer: Timer?
    var lastFront: Int?
    var mouseMonitor: Any?
    var onGone: (() -> Void)?
    static let width: CGFloat = 290
    static let spacing: CGFloat = 8
    static let topPad: CGFloat = 6
    static let bottomPad: CGFloat = 22   // 留給陰影

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.watch() }
        // 在「完成」的視窗裡點一下 ＝ 看過了（滑鼠監聽不需要輔助使用權限）
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.clickCheck() }
        }
    }

    func apply(_ p: Payload) {
        if let s = sessions.first(where: { $0.id == p.session }) { s.apply(p); return }
        guard p.phase == .running || p.phase == .waiting || p.phase == .done else { return }
        let s = Session(id: p.session, bundle: p.bundle, tty: p.tty, pid: p.pid, hub: self)
        if p.bundle == Term.ghosttyID { (s.wid, s.gid) = Term.ghostty(tty: p.tty, pid: p.pid) }
        else { s.wid = Term.windowID(bundle: p.bundle, tty: p.tty) }
        s.wid = s.wid
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: p.bundle).first
                .flatMap { Term.frontWindow(pid: $0.processIdentifier, in: Term.windows()) }
        log("新增 \(Term.topic(bundle: p.bundle, tty: p.tty, gid: s.gid) ?? p.project) [\(p.bundle)] tty=\(p.tty) pid=\(p.pid) wid=\(s.wid.map(String.init) ?? "nil")")
        withAnimation(spring) { sessions.insert(s, at: 0) }      // 新的放最上面，跟系統通知一樣
        s.apply(p)
    }

    func remove(_ s: Session, _ why: String = "") {
        log("移除 \(s.project) [\(s.phase.rawValue)] 原因：\(why)")
        s.pending?.cancel()
        withAnimation(spring) { sessions.removeAll { $0 === s } }
        changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.relayout() }
        if sessions.isEmpty {
            onGone?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { if self.sessions.isEmpty { exit(0) } }
        }
    }

    func changed() {
        relayout()
        syncGlows()
        refreshMenu()
    }

    // 同一個視窗取最緊急的狀態
    func syncGlows() {
        var best: [Int: (Phase, String)] = [:]
        for s in sessions {
            guard let w = s.wid else { continue }
            if (best[w]?.0.priority ?? 0) < s.phase.priority { best[w] = (s.phase, s.bundle) }
        }
        for (w, g) in glows where best[w] == nil {
            g.set(.hidden)
            glows[w] = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { g.teardown() }
        }
        for (w, (ph, bundle)) in best {
            let g = glows[w] ?? GlowController(wid: w, bundle: bundle)
            glows[w] = g
            if g.phase != ph { g.set(ph) }
        }
    }

    // 每 0.25 秒：光暈跟著視窗、切到完成的視窗就算看過、Claude 關掉就清掉
    func watch() {
        let list = Term.windows()
        for g in glows.values { g.follow(list) }
        let frontApp = NSWorkspace.shared.frontmostApplication
        var front: Int?
        if let app = frontApp, ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"].contains(app.bundleIdentifier ?? "") {
            front = Term.frontWindow(pid: app.processIdentifier, in: list)
        }
        if front != lastFront, let f = front {
            for s in sessions where s.phase == .done && s.wid == f && Date().timeIntervalSince(s.lastEvent) > 0.8 { remove(s, "切到視窗 \(f)") }
        }
        lastFront = front
        for s in sessions where s.pid > 0 && kill(s.pid, 0) != 0 { remove(s, "程序 \(s.pid) 結束") }
        for s in sessions where s.phase == .running && Date().timeIntervalSince(s.lastEvent) > 60 * 60 { remove(s, "一小時沒動靜") }
    }

    func clickCheck() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"].contains(app.bundleIdentifier ?? ""),
              let f = Term.frontWindow(pid: app.processIdentifier, in: Term.windows()) else { return }
        for s in sessions where s.phase == .done && s.wid == f { remove(s, "在視窗 \(f) 點擊") }
    }

    // 視窗高度貼著膠囊的總高，其他地方不擋滑鼠
    func relayout() {
        let content = sessions.reduce(0) { $0 + max($1.height, 44) } + CGFloat(max(0, sessions.count - 1)) * Hub.spacing
        let h = max(60, content + Hub.topPad + Hub.bottomPad)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.maxX - Hub.width - 6, y: vf.maxY - h, width: Hub.width, height: h)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    // MARK: 選單列總覽：● 各狀態數量，點開直接跳過去
    func refreshMenu() {
        if sessions.isEmpty { if let s = status { NSStatusBar.system.removeStatusItem(s); status = nil }; return }
        if status == nil { status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        let t = NSMutableAttributedString()
        for ph in [Phase.waiting, .done, .running] {
            let n = sessions.filter { $0.phase == ph }.count
            guard n > 0 else { continue }
            t.append(NSAttributedString(string: "●", attributes: [.foregroundColor: ph.nsColor, .font: NSFont.systemFont(ofSize: 11)]))
            t.append(NSAttributedString(string: "\(n) ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]))
        }
        status?.button?.attributedTitle = t
        let menu = NSMenu()
        for s in sessions.sorted(by: { $0.phase.priority > $1.phase.priority }) {
            let item = NSMenuItem(title: "", action: #selector(menuJump(_:)), keyEquivalent: "")
            let a = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: s.phase.nsColor])
            a.append(NSAttributedString(string: (s.project.isEmpty ? "Claude" : s.project) + "　" + s.phase.label,
                                        attributes: [.font: NSFont.menuFont(ofSize: 13)]))
            item.attributedTitle = a
            item.representedObject = s.id
            item.target = self
            menu.addItem(item)
        }
        if sessions.contains(where: { $0.phase == .done }) {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "清除所有「完成了」", action: #selector(clearDone), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        status?.menu = menu
    }

    @objc func menuJump(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let s = sessions.first(where: { $0.id == id }) else { return }
        s.tapped()
    }
    @objc func clearDone() { for s in sessions where s.phase == .done { remove(s, "選單清除") } }
}

// MARK: - 模糊淡入淡出轉場
struct BlurFade: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.blur(radius: on ? 8 : 0).opacity(on ? 0 : 1).scaleEffect(on ? 0.92 : 1)
    }
}
extension AnyTransition {
    static var blurFade: AnyTransition { .modifier(active: BlurFade(on: true), identity: BlurFade(on: false)) }
}

// MARK: - 處理中：Claude 光芒（旋轉＋呼吸）
struct Spark: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2
                for i in 0..<10 {
                    let a = Double(i) / 10 * .pi * 2 + t * 0.9
                    let wobble = 0.72 + 0.28 * sin(t * 3.2 + Double(i) * 1.7)
                    var p = Path()
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + cos(a) * r * wobble, y: c.y + sin(a) * r * wobble))
                    ctx.stroke(p, with: .color(.claude), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
            }
            .scaleEffect(0.92 + 0.08 * sin(t * 2.4))
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - 流光文字
struct Shimmer: View {
    let text: String
    var body: some View {
        let label = Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        label.foregroundColor(.white.opacity(0.5))
            .overlay(
                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.55)
                            .offset(x: -g.size.width * 0.55 + t * g.size.width * 1.55)
                    }
                }
                .mask(label)
            )
    }
}

// MARK: - 聲波條
struct Wave: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4) { i in
                    Capsule().fill(Color.claude.opacity(0.9))
                        .frame(width: 2.5, height: 4 + 7 * abs(sin(t * 3.1 + Double(i) * 0.9)))
                }
            }
            .frame(height: 12)
        }
    }
}

// MARK: - 完成：打勾徽章
struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.53))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.69))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.34))
        return p
    }
}
struct CheckBadge: View {
    @State private var pop = false
    @State private var draw: CGFloat = 0
    @State private var ripple = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.sysGreen, lineWidth: 2)
                .scaleEffect(ripple ? 1.9 : 1).opacity(ripple ? 0 : 0.8)
            Circle().fill(Color.sysGreen).scaleEffect(pop ? 1 : 0.3)
            CheckShape().trim(from: 0, to: draw)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 28, height: 28)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { pop = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.18)) { draw = 1 }
            withAnimation(.easeOut(duration: 0.9).delay(0.2)) { ripple = true }
        }
    }
}

// MARK: - 等待：搖鈴
struct Bell: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8)
            let angle = t < 0.6 ? sin(t / 0.6 * .pi * 5) * 16 * (1 - t / 0.6) : 0
            ZStack {
                Circle().fill(Color.sysOrange.opacity(0.18))
                Image(systemName: "bell.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.sysOrange)
                    .rotationEffect(.degrees(angle), anchor: .top)
            }
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - 終端機視窗邊框光暈（外暈＋內側燈條，Core Animation 在 GPU 上跑）
let glowPad: CGFloat = 32

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }

final class GlowPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }   // 貼齊選單列時不被系統往下推
}

final class GlowController {
    let wid: Int
    let panel: GlowPanel
    let container = CALayer()
    let maskLayer = CALayer()
    var holders: [Phase: CALayer] = [:]
    var spinners: [CAGradientLayer] = []
    var phase: Phase = .hidden
    var lastOrder = Date.distantPast
    var lastFrame = NSRect.zero
    var lastSize = CGSize.zero

    init(wid: Int, bundle: String) {
        self.wid = wid
        panel = GlowPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // 滑鼠直接穿透，不影響操作終端機
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        let v = NSView(); v.wantsLayer = true
        panel.contentView = v
        v.layer!.addSublayer(container)
        container.mask = maskLayer
        container.opacity = 0

        let sets: [(Phase, [CGColor], Double, Float, Double)] = [
            // 處理中：Claude 橘、粉、紫緩慢旋轉＋呼吸
            (.running, [rgb(0.85, 0.47, 0.34), rgb(1, 0.42, 0.62), rgb(0.62, 0.45, 1), rgb(1, 0.72, 0.4)], 6, 0.6, 1.9),
            // 等授權：琥珀色快速脈動
            (.waiting, [rgb(1, 0.62, 0.04), rgb(1, 0.82, 0.2), rgb(1, 0.62, 0.04), rgb(1, 0.42, 0.08)], 2.6, 0.3, 0.5),
            // 完成：綠色，一直亮著等你來看（輕微呼吸）
            (.done, [rgb(0.19, 0.82, 0.35), rgb(0.4, 1, 0.75), rgb(0.19, 0.82, 0.35), rgb(0.7, 1, 0.4)], 5, 0.8, 2.4),
        ]
        for (ph, cols, spin, low, breath) in sets {
            let holder = CALayer(); holder.opacity = 0
            let g = CAGradientLayer()
            g.type = .conic
            g.colors = cols + [cols[0]]
            g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 0.5, y: 0)
            let rot = CABasicAnimation(keyPath: "transform.rotation.z")
            rot.fromValue = 0; rot.toValue = -Double.pi * 2; rot.duration = spin; rot.repeatCount = .infinity
            g.add(rot, forKey: "spin")
            let b = CABasicAnimation(keyPath: "opacity")
            b.fromValue = 1; b.toValue = low; b.duration = breath
            b.autoreverses = true; b.repeatCount = .infinity
            b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            g.add(b, forKey: "breath")
            holder.addSublayer(g); container.addSublayer(holder)
            holders[ph] = holder; spinners.append(g)
        }
    }

    func teardown() { panel.orderOut(nil); panel.close() }

    func set(_ ph: Phase) {
        let wasDark = phase == .hidden
        phase = ph
        CATransaction.begin(); CATransaction.setAnimationDuration(0.5)
        for (k, h) in holders { h.opacity = k == ph ? 1 : 0 }
        CATransaction.commit()
        if ph == .done && !wasDark {             // 完成那一刻先亮一下
            let k = CAKeyframeAnimation(keyPath: "opacity")
            k.values = [1, 1.0, 0.75, 1]; k.keyTimes = [0, 0.1, 0.5, 1]; k.duration = 1.2
            container.add(k, forKey: "flash")
        }
        CATransaction.begin(); CATransaction.setAnimationDuration(ph == .hidden ? 0.4 : 0.6)
        container.opacity = ph == .hidden ? 0 : 1
        CATransaction.commit()
    }

    // 光暈貼著目標視窗、疊在它正上方
    func follow(_ list: [[String: Any]]) {
        guard phase != .hidden else { return }
        guard let rect = Term.bounds(wid, in: list) else { if panel.isVisible { panel.orderOut(nil) }; return }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: rect.minX - glowPad, y: primaryH - rect.maxY - glowPad,
                           width: rect.width + glowPad * 2, height: rect.height + glowPad * 2)
        if frame != lastFrame {                  // 用自己記的目標框比對（系統可能會把超出螢幕的框夾住）
            lastFrame = frame
            panel.setFrame(frame, display: false)
            if frame.size != lastSize { lastSize = frame.size; layout(frame.size) }
            lastOrder = .distantPast
        }
        if !panel.isVisible || Date().timeIntervalSince(lastOrder) > 0.3 {
            panel.order(.above, relativeTo: wid); lastOrder = Date()
        }
    }

    func layout(_ size: CGSize) {
        let scale = panel.screen?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: size)
        container.frame = bounds
        maskLayer.frame = bounds
        maskLayer.contentsScale = scale
        maskLayer.contents = ringImage(size, scale: scale)
        let side = hypot(size.width, size.height)
        for h in holders.values { h.frame = bounds }
        for g in spinners {
            g.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            g.position = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        CATransaction.commit()
    }

    // 只在視窗大小改變時畫一次：外暈＋視窗內側一圈燈條（旁邊被別的視窗蓋住時也看得到）
    func ringImage(_ size: CGSize, scale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let win = CGRect(origin: .zero, size: size).insetBy(dx: glowPad, dy: glowPad)
        let edge = CGPath(roundedRect: win, cornerWidth: 12, cornerHeight: 12, transform: nil)
        for (width, blur, alpha) in [(6.0, 16.0, 0.9), (3.0, 6.0, 0.95), (1.5, 1.2, 1.0)] {
            ctx.saveGState()
            let c = CGColor(gray: 1, alpha: alpha)
            ctx.setShadow(offset: .zero, blur: blur * scale, color: c)
            ctx.setStrokeColor(c); ctx.setLineWidth(width)
            ctx.addPath(edge); ctx.strokePath()
            ctx.restoreGState()
        }
        // 內側燈條：只畫在視窗裡面
        ctx.saveGState()
        ctx.addPath(edge); ctx.clip()
        let inner = CGPath(roundedRect: win.insetBy(dx: 1, dy: 1), cornerWidth: 11, cornerHeight: 11, transform: nil)
        let c = CGColor(gray: 1, alpha: 1)
        ctx.setShadow(offset: .zero, blur: 4 * scale, color: c)
        ctx.setStrokeColor(c); ctx.setLineWidth(1.8)
        ctx.addPath(inner); ctx.strokePath()
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

// MARK: - 膠囊
struct Pill: View {
    @ObservedObject var s: Session
    @State private var hover = false

    var size: CGSize {
        if s.phase == .done && s.compact { return CGSize(width: 210, height: 30) }
        switch s.phase {
        case .running: return CGSize(width: 210, height: 30)
        case .waiting, .done: return CGSize(width: 250, height: 44)
        default: return CGSize(width: 120, height: 30)
        }
    }
    var accent: Color {
        switch s.phase {
        case .waiting: return .sysOrange
        case .done: return .sysGreen
        default: return .claude
        }
    }
    var name: String { s.project.isEmpty ? "Claude" : s.project }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.height / 2, style: .continuous)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: size.height / 2, style: .continuous)
                    .strokeBorder(accent.opacity(s.phase == .running ? 0.18 : 0.4), lineWidth: 1))
                .shadow(color: accent.opacity(0.45), radius: 9)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            content.padding(.horizontal, (s.phase == .running || s.compact) ? 11 : 9)
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(hover ? 1.03 : 1)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
        .onTapGesture { s.tapped() }
    }

    @ViewBuilder var content: some View {
        switch s.phase {
        case .running:
            HStack(spacing: 8) {
                Spark()
                Shimmer(text: name)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: s.startedAt, by: 1)) { tl in
                    Text(clock(tl.date.timeIntervalSince(s.startedAt)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.55))
                }
                Wave()
            }
            .transition(.blurFade)
        case .waiting:
            HStack(spacing: 9) {
                Bell()
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(s.detail.isEmpty ? "在等你回覆" : s.detail)
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.sysOrange).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .transition(.blurFade)
        case .done where s.compact:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundColor(.sysGreen)
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Spacer(minLength: 4)
                Text("完成").font(.system(size: 11, weight: .medium)).foregroundColor(.sysGreen)
            }
            .transition(.blurFade)
        case .done:
            HStack(spacing: 9) {
                CheckBadge()
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(doneLine).font(.system(size: 11)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .transition(.blurFade)
        default:
            EmptyView()
        }
    }

    var doneLine: String { s.elapsed >= 1 ? "完成了 · 用時 " + friendly(s.elapsed) : "完成了" }
    func clock(_ t: TimeInterval) -> String { let n = max(0, Int(t)); return String(format: "%d:%02d", n / 60, n % 60) }
    func friendly(_ t: TimeInterval) -> String { let n = Int(t); return n < 60 ? "\(n) 秒" : "\(n / 60) 分 \(n % 60) 秒" }
}

struct Stack: View {
    @ObservedObject var hub: Hub
    var body: some View {
        VStack(alignment: .trailing, spacing: Hub.spacing) {
            ForEach(hub.sessions) { s in
                Pill(s: s)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .modifier(active: BlurFade(on: true), identity: BlurFade(on: false))
                                                .combined(with: .move(edge: .trailing))))
            }
        }
        .padding(.top, Hub.topPad)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

// MARK: - 視窗
final class ClickHosting<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func runServer(_ first: Payload) -> Never {
    try? String(getpid()).write(toFile: pidPath, atomically: true, encoding: .utf8)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let hub = Hub()

    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Hub.width, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.hidesOnDeactivate = false
    panel.contentView = ClickHosting(rootView: Stack(hub: hub))
    hub.panel = panel
    hub.relayout()
    panel.orderFrontRegardless()
    hub.start()

    let center = DistributedNotificationCenter.default()
    let token = center.addObserver(forName: notifName, object: nil, queue: .main) { n in
        if let p = Payload(n.userInfo) { hub.apply(p) }
    }
    hub.onGone = {
        center.removeObserver(token)
        if (try? String(contentsOfFile: pidPath)) == String(getpid()) { try? FileManager.default.removeItem(atPath: pidPath) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { hub.apply(first) }
    app.run()
    exit(0)
}

// MARK: - 用戶端
func serverAlive() -> Bool {
    guard let s = try? String(contentsOfFile: pidPath), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return kill(pid, 0) == 0
}

func spawnServer(_ p: Payload) {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let args = [exe, "--serve", p.phase.rawValue, p.session, p.project, p.detail, p.bundle, p.tty, String(p.pid)]
    var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&fa, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
    var pid: pid_t = 0
    posix_spawn(&pid, exe, &fa, &attr, &argv, environ)
    argv.forEach { free($0) }
}

func readHookJSON() -> [String: Any] {
    guard isatty(0) == 0 else { return [:] }
    var data = Data()
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { data = FileHandle.standardInput.readDataToEndOfFile(); sem.signal() }
    guard sem.wait(timeout: .now() + 0.5) == .success else { return [:] }   // stdin 沒關也不會卡住
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// hook 的 stdin/stdout 都被導走了，往上找父程序，第一個有 tty 的就是 Claude 所在的分頁
func findTTY() -> (String, Int32) {
    var p = getppid()
    for _ in 0..<12 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
        guard p > 1, sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        let dev = info.kp_eproc.e_tdev
        if dev != UInt32(bitPattern: -1), dev != 0, let name = devname(dev_t(dev), S_IFCHR) {
            return ("/dev/" + String(cString: name), p)
        }
        p = info.kp_eproc.e_ppid
    }
    return ("", 0)
}

@_silgen_name("proc_pidinfo")
func c_proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

/// Claude 程序自己的工作目錄（PROC_PIDVNODEPATHINFO＝9；前 152 bytes 是 vnode_info，接著是 1024 bytes 路徑）
func processCWD(_ pid: Int32) -> String? {
    var buf = [UInt8](repeating: 0, count: 2352)
    let n = buf.withUnsafeMutableBytes { c_proc_pidinfo(pid, 9, 0, $0.baseAddress, 2352) }
    guard n == 2352 else { return nil }
    let path = String(cString: Array(buf[152..<(152 + 1024)]) + [0])
    return path.hasPrefix("/") ? path : nil
}

let argv = CommandLine.arguments
if argv.count >= 3, argv[1] == "--serve", let ph = Phase(rawValue: argv[2]) {
    func a(_ i: Int) -> String { argv.count > i ? argv[i] : "" }
    runServer(Payload(phase: ph, session: a(3), project: a(4), detail: a(5), bundle: a(6).isEmpty ? "com.apple.Terminal" : a(6),
                      tty: a(7), pid: Int32(a(8)) ?? 0))
}
guard argv.count >= 2, let phase = Phase(rawValue: argv[1]) else {
    print("用法：claude-island run | wait | tick | done | hide"); exit(1)
}
let hook = readHookJSON()
let cwd = hook["cwd"] as? String ?? FileManager.default.currentDirectoryPath
var project = cwd == NSHomeDirectory() ? "" : (cwd as NSString).lastPathComponent
let session = hook["session_id"] as? String ?? ProcessInfo.processInfo.environment["ISLAND_SESSION"] ?? cwd
var detail = ""
if phase == .waiting {
    let msg = (hook["message"] as? String ?? "").lowercased()
    detail = msg.contains("permission") ? "需要你授權" : "在問你問題"
}
let bundle = ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "com.apple.Terminal"
let (tty, claudePID) = findTTY()
let env = ProcessInfo.processInfo.environment
if claudePID > 0, let d = processCWD(claudePID) {
    project = d == NSHomeDirectory() ? "" : (d as NSString).lastPathComponent
}
let payload = Payload(phase: phase, session: session, project: project, detail: detail, bundle: bundle,
                      tty: env["ISLAND_TTY"] ?? tty, pid: env["ISLAND_PID"].flatMap { Int32($0) } ?? claudePID)

if serverAlive() {
    DistributedNotificationCenter.default().postNotificationName(notifName, object: nil, userInfo: payload.dict, deliverImmediately: true)
} else if phase != .hidden && phase != .tick {
    spawnServer(payload)
}
