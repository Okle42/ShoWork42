import AppKit
import SceneKit
import SwiftUI
import ShoWorkCore

// 戰情中心視窗：部門島（IslandView.swift）。10-12 Kang：原本的五欄看板拿掉，只留部門島。
// 欄位分法（BoardColumn）照舊，是角色狀態的來源；P2 的自報＋審核、放行／退回／丟待辦、新任務、右上角帳號流量都還在。
// 一般可縮放的視窗，記住位置；agent 沒有 Dock 圖示，打開時要 activate。

@MainActor
final class BoardWindow: NSObject, NSWindowDelegate {
    static let shared = BoardWindow()
    private var window: NSWindow?

    /// 開著／關著記起來：agent 重啟（更新、當掉）後照原樣打開（10-09：每次安裝新版戰情中心就被關掉）
    static var wasOpen: Bool {
        get { UserDefaults(suiteName: "ai.okle42.showork")?.bool(forKey: "board.open") ?? false }
        set { UserDefaults(suiteName: "ai.okle42.showork")?.set(newValue, forKey: "board.open") }
    }

    func show() {
        BoardModel.shared.start()
        if Engine.current != nil { BoardWindow.wasOpen = true }
        if window == nil {
            let w = (BoardWindow.testMode ? OffscreenWindow.self : NSWindow.self).init(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "AI工作戰情中心"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 860, height: 440)
            w.contentView = Self.content()
            if BoardWindow.testMode {
                // 測試視窗（--board-window）：放在所有螢幕外面、不記位置，截圖用 screencapture -l 照樣拍得到
                if let v = ProcessInfo.processInfo.environment["SHOWORK_TEST_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), v.count == 2 {
                    w.setContentSize(NSSize(width: v[0], height: v[1]))
                }
                let far = NSScreen.screens.map(\.frame).reduce(NSRect.zero) { $0.union($1) }
                w.setFrameOrigin(NSPoint(x: far.maxX + 4000, y: far.minY))
            } else {
                w.setFrameAutosaveName("ShoWork42.Board")
                if !w.setFrameUsingName("ShoWork42.Board") { w.center() }
            }
            w.delegate = self
            window = w
        } else if window?.contentView == nil {
            window?.contentView = Self.content()        // 關窗時拆掉了，重建（鏡頭、樓層、互動板位置在 OfficeMemory）
        }
        if BoardWindow.testMode {      // 不搶你的焦點；排進畫面後再放回螢幕外一次
            window?.orderFront(nil)
            let far = NSScreen.screens.map(\.frame).reduce(NSRect.zero) { $0.union($1) }
            window?.setFrameOrigin(NSPoint(x: far.maxX + 4000, y: far.minY))
            return
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 測試視窗自己存截圖（視窗在螢幕外，screencapture 拍不到）：先畫 SwiftUI 部分，再把 3D 畫面的 snapshot 疊上去
    func snapshot(to path: String) -> Bool {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        let swiftUI = rep.copy() as? NSBitmapImageRep          // SwiftUI 那層（3D 區域是空底＋疊在上面的卡片、選單）
        func scnViews(_ x: NSView) -> [SCNView] { (x as? SCNView).map { [$0] } ?? x.subviews.flatMap(scnViews) }
        var rects: [NSRect] = []
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for scn in scnViews(v) {
            var r = v.convert(scn.bounds, from: scn)
            if v.isFlipped { r.origin.y = v.bounds.height - r.maxY }
            scn.snapshot().draw(in: r)
            rects.append(r)
        }
        NSGraphicsContext.restoreGraphicsState()
        // 10-20：3D 畫面上疊的 SwiftUI（回答卡、保全面板、右上角選單）會被 snapshot 蓋掉 ⇒ 把 SwiftUI 層裡跟空底顏色不同的像素補回去
        if let ui = swiftUI, let dst = rep.bitmapData, let src = ui.bitmapData, rep.bitsPerPixel == 32, ui.bitsPerPixel == 32 {
            let k = CGFloat(rep.pixelsWide) / max(1, v.bounds.width), bpr = rep.bytesPerRow
            for r in rects {
                let x0 = Int(r.minX * k), x1 = min(rep.pixelsWide, Int(r.maxX * k))
                let y0 = Int((v.bounds.height - r.maxY) * k), y1 = min(rep.pixelsHigh, Int((v.bounds.height - r.minY) * k))
                // 空底的顏色：取 3D 區域四個角＋正中央，最多的那個（10-20 第 4 棒：螢幕空間標籤剛好蓋在正中央時，整片 3D 被當成「疊在上面的 UI」蓋掉）
                let pts = [((y0 + y1) / 2, (x0 + x1) / 2), (y0 + 3, x0 + 3), (y0 + 3, x1 - 4), (y1 - 4, x0 + 3), (y1 - 4, x1 - 4)]
                let cols = pts.map { (y, x) in let c = y * bpr + x * 4; return [src[c], src[c + 1], src[c + 2]] }
                let best = cols.max { a, b in cols.filter { $0 == a }.count < cols.filter { $0 == b }.count }!
                let ref = (best[0], best[1], best[2])
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = y * bpr + x * 4
                        if abs(Int(src[i]) - Int(ref.0)) + abs(Int(src[i + 1]) - Int(ref.1)) + abs(Int(src[i + 2]) - Int(ref.2)) > 6 {
                            dst[i] = src[i]; dst[i + 1] = src[i + 1]; dst[i + 2] = src[i + 2]; dst[i + 3] = src[i + 3]
                        }
                    }
                }
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    func toggle() { window?.isVisible == true ? window?.close() : show() }

    /// 戰情中心有沒有被人看著：開著、沒縮到 Dock、沒被完全蓋住（看板刷新頻率依這個調，10-24）
    var onScreen: Bool { guard let w = window else { return false }; return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible) }

    // 戰情中心開、關、搬動、改大小 ⇒ 終端機重排到它旁邊（停手 0.6 秒後才排，拖曳中不追）
    private var pending: DispatchWorkItem?
    private func rearrangeSoon() {
        guard Arranger.shared.autoArrange, Engine.current != nil else { return }      // 只有正式 agent 會搬視窗
        pending?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { Arranger.shared.arrange() } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }
    func windowDidMove(_ notification: Notification) { rearrangeSoon() }
    func windowDidEndLiveResize(_ notification: Notification) { rearrangeSoon() }
    func windowDidBecomeKey(_ notification: Notification) { if !opened { opened = true; rearrangeSoon() } }
    func closeForTest() { window?.close() }
    var hasContent: Bool { window?.contentView != nil }
    static func content() -> NSView { NSHostingView(rootView: BoardView(model: BoardModel.shared)) }

    func windowWillClose(_ notification: Notification) {
        opened = false; rearrangeSoon()
        // 10-24 Kang 選 C：關著時看板 SwiftUI 和 3D 還在跟著資料更新（約 1% CPU）⇒ 關窗就拆掉內容，重開再建
        if !BoardWindow.terminating {
            DispatchQueue.main.async { MainActor.assumeIsolated { if self.window?.isVisible == false { self.window?.contentView = nil } } }
        }
        // agent 結束時系統也會關視窗，那不算「你關的」
        if Engine.current != nil, !BoardWindow.terminating { BoardWindow.wasOpen = false }
    }
    static var terminating = false
    /// --board-window 測試視窗
    static var testMode = false
    func windowDidMiniaturize(_ notification: Notification) { rearrangeSoon() }
    func windowDidDeminiaturize(_ notification: Notification) { rearrangeSoon() }
    private var opened = false
}

/// 測試視窗：不被系統拉回螢幕範圍內（一般有標題列的視窗會被 constrainFrameRect 拉回來）
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
}

// MARK: - 整體

struct BoardView: View {
    @ObservedObject var model: BoardModel
    @State private var newTask = false
    @State private var reviewOn = Reviewer.shared.enabled
    @State private var autoWrap = CtxGuard.shared.autoWrapUp
    @State private var ctxThreshold = ContextGuard.threshold
    @State private var sendBackCard: BoardCard?
    @State private var parkCard: BoardCard?
    @State private var dispatchCard: BoardCard?
    @State private var toCaptain = false
    @State private var toast: String?
    /// 3D 辦公室／部門島（10-20 Kang：參考 IG 的 3D 辦公室做看板；部門島留著切換）
    @AppStorage("board.mode", store: UserDefaults(suiteName: "ai.okle42.showork")) private var view = "office"

    var body: some View {
        VStack(spacing: 12) {
            // 視窗窄時不硬擠一排（10-13：518 寬時按鈕、開關的字被壓成一字寬直排）：先試一排 → 兩排 → 兩排短標籤
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { controls(short: false); Spacer(minLength: 12); UsageView(limits: model.rateLimits) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { controls(short: false) }
                    UsageView(limits: model.rateLimits)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { controls(short: true) }
                    UsageView(limits: model.rateLimits)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 測試視窗可用 SHOWORK_TEST_VIEW=islands|office 指定檢視（只讀不寫，不會改到你存的選擇；10-20 審查）
            if (BoardWindow.testMode ? ProcessInfo.processInfo.environment["SHOWORK_TEST_VIEW"] : nil) ?? view == "office" {
                OfficeView(cards: model.cards, departments: model.departments, tower: model.tower, decor: model.decor, wander: model.wander, guardStatus: model.guardStatus, guardScanning: model.guardScanning, captainThread: model.captainThread, captainTasks: model.captainTasks, sessionThread: model.sessionThread, city: model.city, loaded: model.loaded,
                           reviewing: model.reviewing, onSendBack: { sendBackCard = $0 }, onPark: { parkCard = $0 },
                           onDispatch: { dispatchCard = $0 }, onToast: show)
            } else {
                IslandsView(cards: model.cards, reviewing: model.reviewing, onSendBack: { sendBackCard = $0 }, onPark: { parkCard = $0 },
                            onDispatch: { dispatchCard = $0 }, onToast: show)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {   // 提示浮在底部，不佔工具列寬度（不然一跳出來工具列就換排）
            if let toast {
                Text(toast).font(.callout).lineLimit(2)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $newTask) { NewTaskSheet(folders: Self.folders(model.cards), onDone: show) }
        .sheet(item: $sendBackCard) { c in SendBackSheet(card: c, onDone: show) }
        .sheet(item: $parkCard) { c in ParkSheet(card: c) }
        .sheet(item: $dispatchCard) { c in
            DispatchSheet(card: c, others: model.cards.filter { !$0.id.contains("#") && $0.sessionId != c.sessionId && !$0.captain }.compactMap(\.name),
                          captain: captainCard?.sessionId, onDone: show)
        }
        .sheet(isPresented: $toCaptain) { CaptainSheet(captain: captainCard, onDone: show) }
    }

    private var captainCard: BoardCard? { model.cards.first { $0.captain } }

    /// 工具列按鈕與開關；`short` 時用短標籤（完整說明在 help）。fixedSize：寧可換排也不壓字
    @ViewBuilder private func controls(short: Bool) -> some View {
        Picker("檢視", selection: $view) {
            Image(systemName: "cube").tag("office").help("3D 辦公室")
            Image(systemName: "square.grid.2x2").tag("islands").help("部門島")
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        Button { newTask = true } label: { Label(short ? "新任務" : "新任務⋯", systemImage: "plus") }
            .keyboardShortcut("n").fixedSize()
        Button { toCaptain = true } label: { Label(short ? "隊長" : "交給隊長⋯", systemImage: "crown") }
            .fixedSize()
            .help(captainCard == nil ? "還沒有隊長：送出時會開一個 \(BoardActions.modelTitle(BoardActions.captainModel)) 背景隊長" : "把一件事交給隊長，由它決定給哪個 session")
        Toggle(short ? "審核" : "AI 審核", isOn: $reviewOn)
            .toggleStyle(.switch).controlSize(.small).fixedSize()
            .onChange(of: reviewOn) { _, v in Reviewer.shared.enabled = v }
            .help("AI 審核：卡片進「待審」時，請 \(Reviewer.model) 獨立審一次（走你的訂閱額度）")
        HStack(spacing: 2) {
            SwiftUI.Menu {                          // 門檻可調（10-15 Kang）
                Picker("門檻", selection: $ctxThreshold) {
                    ForEach(ContextGuard.choices, id: \.self) { v in Text("\(Int(v))%" + (v == 70 ? "（建議）" : "")).tag(v) }
                }
                .pickerStyle(.inline)
            } label: { Text(short ? "\(Int(ctxThreshold))%" : "ctx \(Int(ctxThreshold))%") }
            .menuStyle(.borderlessButton).fixedSize()
            .onChange(of: ctxThreshold) { _, v in ContextGuard.threshold = v }
            .help("點一下改門檻：context 超過這個 % 就通知你（開著自動收尾時，也請那個 AI 收尾）")
            Toggle(short ? "收尾" : "自動收尾", isOn: $autoWrap)
                .toggleStyle(.switch).controlSize(.small).fixedSize()
                .onChange(of: autoWrap) { _, v in CtxGuard.shared.autoWrapUp = v }
                .help("ctx \(Int(ctxThreshold))% 自動收尾：context 超過 \(Int(ctxThreshold))% 會通知你；開著時，等那個 AI 停下來就請它 commit、規則允許才 push、更新交接")
        }
    }

    private func show(_ s: String) {
        withAnimation(.smooth) { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if toast == s { withAnimation(.smooth) { toast = nil } } }
    }

    /// 新任務可選的資料夾：看板上出現過的專案根目錄
    static func folders(_ cards: [BoardCard]) -> [String] {
        var seen: [String] = []
        for c in cards { if let r = c.cwd.map(gitRoot), r != BoardPaths.home, !seen.contains(r) { seen.append(r) } }
        return seen
    }
    static func gitRoot(_ p: String) -> String {
        var d = p
        while d.count > 1 && d != BoardPaths.home {
            if FileManager.default.fileExists(atPath: d + "/.git") { return d }
            d = (d as NSString).deletingLastPathComponent
        }
        return p
    }
}

// MARK: - 右上角：帳號流量

struct UsageView: View {
    let limits: RateLimits?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            if let l = limits?.current(now: now) {
                HStack(spacing: 14) {
                    if let w = l.fiveHour { Meter(label: "5 小時", window: w, now: now) }
                    if let w = l.sevenDay { Meter(label: "7 天", window: w, now: now) }
                }
                .help(l.snapshotAt.map { "帳號流量（訂閱額度）・資料時間 \($0.formatted(date: .omitted, time: .shortened))，由 Claude Code 狀態列更新" } ?? "帳號流量（訂閱額度）")
            } else {
                Label("帳號流量：尚無資料", systemImage: "gauge.with.dots.needle.0percent")
                    .font(.callout).foregroundStyle(.secondary)
                    .help("Claude Code 的狀態列要把 rate_limits 存到 ~/.claude/cache/rate_limits.json")
            }
        }
    }

    struct Meter: View {
        let label: String
        let window: RateLimits.Window
        let now: Date
        var level: Color { window.used >= 90 ? .red : window.used >= 70 ? .orange : .accentColor }

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(label).foregroundStyle(.secondary)
                    Text("\(Int(window.used.rounded()))%").monospacedDigit().fontWeight(.semibold)
                    if window.used >= 70 { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(level) }
                    if let r = window.resetsAt, r > now {
                        Text("↻ \(Self.left(r.timeIntervalSince(now)))").monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                ProgressView(value: min(window.used, 100), total: 100).tint(level).frame(width: 120)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label)流量已用 \(Int(window.used.rounded()))%")
        }

        static func left(_ s: TimeInterval) -> String {
            let m = Int(s / 60)
            if m >= 24 * 60 { return "\(m / 1440)天\(m % 1440 / 60)時" }
            return m >= 60 ? "\(m / 60):\(String(format: "%02d", m % 60))" : "\(m) 分"
        }
    }
}

// MARK: - 欄位顏色（派工單、詳情圖示用）

extension BoardColumn {
    /// 欄色只上在符號上（文字維持 label 色）；進行中／完成／待審沿用光暈的紫／綠／紅
    @MainActor var tint: Color {
        switch self {
        case .todo: .secondary
        case .active: Color(nsColor: Look.color(.working))
        case .review: Color(nsColor: Look.color(.input))
        case .done: Color(nsColor: Look.color(.done))
        case .stuck: .orange
        }
    }
}

/// 隊長卡：派出去的單；其他卡：交給它還沒結束的單
struct TaskList: View {
    let tasks: [CaptainTask]
    let captain: Bool
    let expanded: Bool

    var body: some View {
        let shown = captain && !expanded ? Array(tasks.filter { $0.state.open || $0.updatedAt.timeIntervalSinceNow > -2 * 3600 }.prefix(4)) : tasks
        VStack(alignment: .leading, spacing: 3) {
            if captain {
                let open = tasks.filter { $0.state.open }.count
                Text("派工 \(tasks.count) 張・未結 \(open)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown) { t in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: Self.symbol(t.state)).foregroundStyle(Self.color(t.state)).font(.caption2)
                    Text(captain ? "→ \(t.to)：\(t.summary ?? t.text)" : "隊長派工：\(t.text)")
                        .lineLimit(expanded ? nil : 1)
                }
                .font(.caption).foregroundStyle(.secondary)
                .help("\(t.id)［\(t.state.title)］\(t.text)" + (t.summary.map { "\n回報：\($0)" } ?? ""))
            }
        }
    }

    static func symbol(_ s: CaptainTask.State) -> String {
        switch s {
        case .sent: "paperplane"
        case .working: "circle.dotted.circle"
        case .review: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }
    @MainActor static func color(_ s: CaptainTask.State) -> Color {
        switch s {
        case .sent: .secondary
        case .working: BoardColumn.active.tint
        case .review: BoardColumn.review.tint
        case .done: BoardColumn.done.tint
        case .blocked: .orange
        case .cancelled: .secondary
        }
    }
}

// MARK: - 對話框

struct SendBackSheet: View {
    let card: BoardCard
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("退回「\(card.title)」").font(.headline)
            Text("這句話會打進那個 session 並送出（在 tmux 裡）；不在 tmux 的會拷貝到剪貼簿並跳過去。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("送出") {
                    switch BoardActions.sendBack(card, text: text) {
                    case .typed: onDone("已送進「\(card.title)」")
                    case .copied(let m): onDone(m)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }
}

/// 看板上直接派工（可設接力：它做完自動交給下一個）
struct DispatchSheet: View {
    let card: BoardCard
    let others: [String]
    let captain: String?
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var relay = false
    @State private var thenTo = ""
    @State private var thenText = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("派工給 \(card.name ?? card.title)").font(.headline)
            Text("\(card.project)・\(card.title)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if !card.sameProject.isEmpty {
                Label("同專案還有 \(card.sameProject.joined(separator: "、"))", systemImage: "exclamationmark.2").font(.callout).foregroundStyle(.orange)
            }
            Text("訊息會排進它的收件匣，下一次它用工具時讀到，不會打進輸入框。" + (captain == nil ? "回報會用系統通知告訴你。" : "回報會傳給隊長。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            Toggle("做完後自動交給下一個（接力）", isOn: $relay).disabled(others.isEmpty)
            if relay {
                Picker("下一棒", selection: $thenTo) {
                    if thenTo.isEmpty { Text("請選擇").tag("") }
                    ForEach(others, id: \.self) { Text($0).tag($0) }
                }
                TextField("下一棒要做什麼（會附上這一棒的回報）", text: $thenText)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("派出") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (relay && (thenTo.isEmpty || thenText.trimmingCharacters(in: .whitespaces).isEmpty)))
            }
        }
        .padding(20).frame(width: 480)
    }

    private func send() {
        busy = true; error = nil
        let c = card, t = text, nt = relay ? thenTo : nil, nx = relay ? thenText : nil, cap = captain
        DispatchQueue.global().async {
            let r = BoardActions.dispatch(to: c, text: t, thenTo: nt, thenText: nx, captain: cap)
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success(let id):
                    BoardModel.shared.append(["ev": "dispatch", "id": id, "to": c.sessionId, "text": t])
                    BoardModel.shared.refresh()
                    onDone("已派工 \(id) 給 \(c.name ?? c.title)"); dismiss()
                case .failure(let e): error = "送不出去：\(e.message)"
                }
            }
        }
    }
}

/// 交給隊長：由隊長決定給誰
struct CaptainSheet: View {
    let captain: BoardCard?
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(captain.map { "交給隊長（\($0.name ?? $0.title)）" } ?? "交給隊長（送出時開 \(BoardActions.modelTitle(BoardActions.captainModel)) 隊長）",
                  systemImage: "crown.fill").font(.headline)
            Text("隊長會看名冊，決定交給哪個 session，或自己做。訊息排進它的收件匣，不會打斷它正在做的事。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body).frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                if busy { ProgressView().controlSize(.small); Text(captain == nil ? "正在開隊長⋯" : "送出中⋯").font(.callout) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("交給隊長") {
                    // 測試視窗看的是你真的 session：不送、不開隊長
                    if BoardWindow.testMode { onDone("測試：不交給隊長"); dismiss(); return }
                    busy = true
                    let t = text
                    DispatchQueue.global().async {
                        let msg = BoardActions.askCaptain(t)
                        DispatchQueue.main.async {
                            BoardModel.shared.append(["ev": "tocaptain", "text": t])
                            onDone(msg); dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }
}

struct ParkSheet: View {
    let card: BoardCard
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把「\(card.title)」丟回待辦").font(.headline)
            TextField("備註（選填），例如：下週再看", text: $note)
            Text("這個 session 一有新動靜，就會自動回到它該在的欄。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("丟回待辦") { BoardActions.park(card, note: note); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
    }
}

struct NewTaskSheet: View {
    let folders: [String]
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var prompt = ""
    @State private var fullAuto = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新任務").font(.headline)
            Text("在選的資料夾開一個 Claude 背景 session（不開視窗），看板上看得到；要看細節用 claude attach。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("資料夾", selection: $folder) {
                    if folder.isEmpty { Text("請選擇").tag("") }
                    ForEach(folders + (folders.contains(folder) || folder.isEmpty ? [] : [folder]), id: \.self) {
                        Text(($0 as NSString).lastPathComponent).tag($0)
                    }
                }
                Button("選擇⋯") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    if p.runModal() == .OK, let u = p.url { folder = u.path }
                }
            }
            if !folder.isEmpty { Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            Text("要它做什麼").font(.callout)
            TextEditor(text: $prompt).font(.body).frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            Toggle("全自動（不問權限，等同 bypassPermissions）", isOn: $fullAuto)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("開始") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || folder.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }

    private func start() {
        busy = true; error = nil
        let f = folder, p = prompt, a = fullAuto
        DispatchQueue.global().async {
            let r = BoardActions.newTask(folder: f, prompt: p, fullAuto: a)
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success(let id):
                    BoardModel.shared.append(["ev": "newtask", "folder": f, "bg": id, "prompt": p])
                    BoardModel.shared.refresh()
                    onDone("已開背景 session \(id)")
                    dismiss()
                case .failure(let e):
                    error = e.message.contains("not trusted") ? "這個資料夾還沒信任過：先在終端機進去跑一次 claude 並同意。" : e.message
                }
            }
        }
    }
}
