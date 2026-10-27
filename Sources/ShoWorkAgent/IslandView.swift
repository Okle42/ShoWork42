import AppKit
import SwiftUI
import ShoWorkCore

// 部門島：戰情中心的主畫面（10-12 決策板 docs/design/角色決策板.html，Kang 選 A 像素豆 Kubo）。
// 一個專案一座 2D 等角島，一個 session 一個 Kubo 坐在桌前；紫＝打字、紅「!」＝等你回答、綠勾＝做完沒看、橘「?」＝卡住、閉眼＝閒置。
// 全部用程式畫（不用圖檔），8 fps（10-14 Kang 並排比過 12 格選 8 格；打字 0.5 秒＝剛好 4 格一循環）；沒有角色在動或「減少動態效果」開著就停。

struct IslandsView: View {
    let cards: [BoardCard]
    let reviewing: Set<String>
    let onSendBack: (BoardCard) -> Void
    let onPark: (BoardCard) -> Void
    let onDispatch: (BoardCard) -> Void
    let onToast: (String) -> Void

    var body: some View {
        let islands = Islands.build(cards)
        if islands.isEmpty {
            ContentUnavailableView("還沒有 session", systemImage: "person.3", description: Text("開一個 Claude Code，它就會出現在島上。"))
        } else {
            // 每張一樣大、剛好塞滿視窗（10-12 Kang）；塞不下才往下捲
            GeometryReader { g in
                let gap = 12.0
                let L = IslandGrid.fit(count: islands.count, width: g.size.width, height: g.size.height, gap: gap)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(L.width), spacing: gap), count: L.cols), alignment: .leading, spacing: gap) {
                        ForEach(islands) { i in
                            IslandCard(island: i, size: CGSize(width: L.width, height: L.height), reviewing: reviewing,
                                       onSendBack: onSendBack, onPark: onPark, onDispatch: onDispatch, onToast: onToast)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }

        }
    }
}

// MARK: - 一座島：左邊是島，右邊是每個角色的對話框（10-12 Kang：右邊空著，放小對話框）

struct IslandCard: View {
    let island: Island
    let size: CGSize
    let reviewing: Set<String>
    let onSendBack: (BoardCard) -> Void
    let onPark: (BoardCard) -> Void
    let onDispatch: (BoardCard) -> Void
    let onToast: (String) -> Void

    static let maxPeople = 16
    private var shown: [Islander] { Array(island.people.prefix(Self.maxPeople)) }
    private var geo: IslandGeometry { IslandGeometry(count: shown.count) }

    // 滑鼠停在角色或對話框上 ⇒ 放大的對話框（popover）；移進 popover 也不關，離開 0.35 秒才關
    @State private var open: String?
    @State private var overSource = false
    @State private var overPop = false

    static let pad: CGFloat = 10, headerH: CGFloat = 24
    /// 島（玩偶區）固定佔卡片寬的這個比例，剩下給對話框
    static let dollShare: CGFloat = 0.42
    static let minBubble: CGFloat = 36, bubbleGap: CGFloat = 8     // 36＝精簡版（標題＋數字）放得下

    var body: some View {
        let inner = CGSize(width: size.width - Self.pad * 2, height: size.height - Self.pad * 2 - Self.headerH - 4)
        let area = CGSize(width: inner.width * Self.dollShare, height: inner.height)
        // 整座島（含角色）一起縮放到玩偶區大小
        let s = max(0.3, min(area.width / geo.size.width, area.height / geo.size.height))
        // 對話框平分右側整個高度（10-13 Kang：下面還有空間卻被「…」截掉）；放不下就收成「還有 N 個」。卡片大，字也跟著大
        let fit = BubbleFit(people: shown, height: area.height)
        let bubbleH = fit.height
        let bubbleW = inner.width - area.width - 10 - 10
        let k = min(1.6, max(1, min(bubbleH / 120, bubbleW / 280)))
        VStack(alignment: .leading, spacing: 4) {
            header.frame(height: Self.headerH)
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    IslandCanvas(island: island, people: shown, geo: geo, scale: s, focus: open)
                    ForEach(Array(shown.enumerated()), id: \.element.id) { n, p in
                        let pt = geo.spot(n)
                        Color.clear
                            .frame(width: 80 * s, height: 92 * s)
                            .contentShape(Rectangle())
                            .position(x: pt.x * s, y: (pt.y - 22) * s)
                            .onTapGesture { jump(p.card) }
                            .onHover { hover(p.id, $0) }
                            .contextMenu { menu(p.card) }
                            .accessibilityElement()
                            .accessibilityLabel("\(p.card.title)，\(p.card.reason)")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .frame(width: geo.size.width * s, height: geo.size.height * s)
                .frame(width: area.width, height: area.height, alignment: .top)    // 靠上：對話框的尾巴才指得到角色
                VStack(alignment: .leading, spacing: Self.bubbleGap) {
                    ForEach(fit.visible) { p in
                        SpeechBubble(p: p, lit: open == p.id, height: fit.height, scale: k)
                            .onTapGesture { jump(p.card) }
                            .onHover { hover(p.id, $0) }
                            .contextMenu { menu(p.card) }
                            .popover(isPresented: Binding(get: { open == p.id }, set: { if !$0, open == p.id { open = nil } }),
                                     arrowEdge: .trailing) {
                                BubbleDetail(p: p, reviewing: reviewing.contains(p.card.sessionId), run: { act($0, p.card) })
                                    .onHover { overPop = $0; if !$0 { closeSoon() } }
                            }
                    }
                    if !fit.hidden.isEmpty && fit.visible.count < fit.slots {
                        // 放不下的不切一半，收成一格（10-13 Kang：底下被遮掉）；角色還在島上，點角色一樣能跳、停留一樣能看
                        Text("還有 \(fit.hidden.count) 個⋯").font(.system(size: 12 * k, weight: .medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: fit.height, maxHeight: fit.height)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .help("視窗拉大就看得到：\n" + fit.hidden.map(\.card.title).joined(separator: "\n"))
                    }
                }
                .padding(.top, 4).padding(.bottom, 6).padding(.leading, 8).padding(.trailing, 3)
                .frame(maxWidth: .infinity, maxHeight: area.height, alignment: .topLeading)
            }
        }
        .padding(Self.pad)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()                                       // 再怎樣都不撐出卡片
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .quaternarySystemFill)))
        .onAppear {     // 截圖驗證用：SHOWORK_OPEN=<專案名> 開著那座島第一個角色的放大對話框（不動使用者的滑鼠）
            if ProcessInfo.processInfo.environment["SHOWORK_OPEN"] == island.project {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { overPop = true; open = shown.first?.id }
            }
        }
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { overSource = true; open = id } else { overSource = false; closeSoon() }
    }
    private func closeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if !overSource && !overPop { open = nil } }
    }

    private func act(_ a: BubbleDetail.Action, _ c: BoardCard) {
        open = nil; overPop = false
        switch a {
        case .jump: jump(c)
        case .approve: BoardActions.approve(c); onToast("已放行「\(c.title)」")
        case .sendBack: onSendBack(c)
        case .park: onPark(c)
        case .wrapUp:
            let r = BoardActions.wrapUp(c)
            onToast(r == "typed" ? "已請「\(c.title)」收尾" : r)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(island.project).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            if island.count(.waiting) > 0 {
                Text("\(island.count(.waiting)) 件等你").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: Look.color(.input))))
            }
            dot(.working, island.count(.working), "進行中")
            dot(.finished, island.count(.finished), "做完沒看")
            if island.count(.stuck) > 0 { dot(.stuck, island.count(.stuck), "卡住") }
            if island.queued > 0 {
                Label("\(island.queued)", systemImage: "tray").font(.caption).foregroundStyle(.secondary).help("排隊中的訊息 \(island.queued) 則")
            }
            if island.people.count > Self.maxPeople {
                Text("+\(island.people.count - Self.maxPeople)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    private func dot(_ m: Mood, _ n: Int, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color(nsColor: KuboArt.tint(m))).frame(width: 7, height: 7)
            Text("\(n)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .help("\(label) \(n)")
    }

    private func jump(_ c: BoardCard) {
        if !BoardActions.focus(pid: c.pid) {
            onToast(c.kind == "bg" ? "這是背景 session，沒有視窗；用 claude attach 打開" : "找不到這個 session 的視窗")
        }
    }

    @ViewBuilder private func menu(_ c: BoardCard) -> some View {
        Button("跳到這個視窗") { jump(c) }
        if !c.captain { Button("派工給它⋯") { onDispatch(c) } }
        Button("退回並補指示⋯") { onSendBack(c) }
        Button("丟回待辦⋯") { onPark(c) }
        Button("重新審核") { Reviewer.shared.start(c, force: true) }.disabled(reviewing.contains(c.sessionId) || c.lastActivity == nil)
        Divider()
        Button("拷貝 Session ID") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.sessionId, forType: .string)
        }
    }
}

// MARK: - 對話框

/// 右側放得下幾個對話框：全部放得下就平分高度；放不下就顯示前幾個（最急的排前面）＋「還有 N 個」一格
struct BubbleFit {
    let visible: [Islander]
    let hidden: [Islander]
    let slots: Int
    let height: CGFloat

    init(people: [Islander], height H: CGFloat) {
        let gap = IslandCard.bubbleGap, minH = IslandCard.minBubble
        let avail = H - 10                                       // 上 4、下 6 留給外框線（線畫在邊上，貼齊會被裁掉）
        let cap = max(1, Int((avail + gap) / (minH + gap)))
        let n = max(people.count, 1)
        if n <= cap {
            slots = n; visible = people; hidden = []
        } else {
            slots = cap
            let show = cap >= 2 ? cap - 1 : 1                    // 留一格寫「還有 N 個」
            visible = Array(people.prefix(show)); hidden = Array(people.dropFirst(show))
        }
        height = max(minH, (avail - gap * CGFloat(slots - 1)) / CGFloat(slots))
    }
}

/// 📈 完成度、🎯 信心度、🧠 ctx（自報優先，沒有自報用審核的數字）
struct Gauges: View {
    let card: BoardCard
    var font: Font = .caption

    var body: some View {
        let prog = card.report?.progress ?? card.review?.progress
        let conf = card.report?.confidence ?? card.review?.confidence
        HStack(spacing: 10) {
            item("📈", prog, "完成度")
            item("🎯", conf, "信心度")
            if let x = card.ctx {
                Text("🧠 \(Int(x.percent))%").foregroundStyle(ContextGuard.over(x) ? .red : x.percent >= 70 ? .orange : .primary)
                    .fontWeight(x.percent >= 70 ? .semibold : .regular)
                    .help("ctx（context 用量）\(Int(x.percent))%")
            } else {
                item("🧠", nil, "ctx")
            }
            if let h = card.handover {    // 自動交接（Handover.swift）：收尾完到 /clear 之間
                Text("🔁 \(h)").foregroundStyle(.orange).fontWeight(.semibold).help("ctx 自動交接：\(h)")
            }
        }
        .font(font).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
    }

    private func item(_ e: String, _ v: Int?, _ name: String) -> some View {
        Text("\(e) \(v.map { "\($0)%" } ?? "—")").help("\(name) \(v.map { "\($0)%" } ?? "還沒有")")
    }
}

/// 一句話任務回報：要你決定的事 ＞ AI 自報摘要 ＞ AI 最後說的話 ＞ 欄位理由
func bubbleLine(_ c: BoardCard) -> String {
    if let h = c.handover, c.report?.ask == nil { return "🔁 \(h)" + (c.report?.summary.map { "：\($0)" } ?? "") }
    return c.report?.ask.map { "要你決定：\($0)" } ?? c.report?.summary ?? c.detail ?? c.reason
}

struct SpeechBubble: View {
    let p: Islander
    let lit: Bool
    var height: CGFloat = 74
    var scale: CGFloat = 1          // 卡片放大時字跟著放大

    /// 框太矮（一座島好幾個人、視窗又小）⇒ 只留標題＋數字
    private var compact: Bool { height < 56 }

    var body: some View {
        let tint = Color(nsColor: KuboArt.tint(p.mood))
        VStack(alignment: .leading, spacing: compact ? 1 : 3 * scale) {
            HStack(spacing: 5) {
                if p.card.captain { Text("👑").font(.system(size: 11 * scale)) }
                Text(p.card.title).font(.system(size: 13 * scale, weight: .semibold)).lineLimit(height < 80 ? 1 : 2)
            }
            Gauges(card: p.card, font: .system(size: 11 * scale))
            if !compact {
                // 不限行數：框多高就顯示多少，放不下才在最後一行「…」
                Text(bubbleLine(p.card)).font(.system(size: 11.5 * scale)).foregroundStyle(.secondary)
                    .layoutPriority(-1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()                                      // 字永遠留在框裡（10-13：小視窗摘要畫到框外）
        .padding(.horizontal, 10 * scale).padding(.vertical, compact ? 4 : 7 * scale)
        .frame(height: height)
        .background(BubbleShape().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(BubbleShape().stroke(tint.opacity([.idle, .asleep].contains(p.mood) ? 0.35 : 0.9), lineWidth: lit ? 2.5 : 1.5))
        .contentShape(BubbleShape())
        .help("按一下跳到這個終端機")
    }
}

/// 圓角框＋左邊一個小尾巴（指向島上的角色）
struct BubbleShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: 10, style: .continuous)
        let y = min(r.minY + 22, r.midY)
        p.move(to: CGPoint(x: r.minX + 0.5, y: y - 6))
        p.addLine(to: CGPoint(x: r.minX - 7, y: y))
        p.addLine(to: CGPoint(x: r.minX + 0.5, y: y + 6))
        return p
    }
}

/// 滑鼠停上去放大的對話框：詳細內容＋四個決定按鈕（跟看板卡片同一套動作）
struct BubbleDetail: View {
    enum Action { case jump, approve, sendBack, park, wrapUp }
    let p: Islander
    let reviewing: Bool
    let run: (Action) -> Void

    private var c: BoardCard { p.card }
    private var queueOnly: Bool { c.id.contains("#") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if c.captain { Text("👑") }
                Text(c.title).font(.headline).lineLimit(2)
            }
            Text([c.project, c.name].compactMap { $0 }.joined(separator: "・")).font(.caption).monospaced().foregroundStyle(.secondary)
            if c.report?.ask == nil {      // 有「要你決定」就只在下面的框講一次
                Label { Text(c.reason).lineLimit(3) } icon: {
                    Image(systemName: c.column.symbol).foregroundStyle(Color(nsColor: KuboArt.tint(p.mood)))
                }
                .font(.callout)
            }
            Gauges(card: c, font: .title3)
            if let ask = c.report?.ask {
                Text("要你決定：\(ask)").font(.callout.weight(.semibold))
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Look.color(.input)).opacity(0.15)))
            }
            if let s = c.report?.summary {
                Text(s).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let d = c.detail, d != c.report?.summary {
                Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(8).fixedSize(horizontal: false, vertical: true)
            }
            if let x = c.ctx, ContextGuard.over(x) {
                HStack {
                    Label(CtxGuard.shared.wasSent(c.sessionId) ? "已請它收尾" : "context 快滿，該收尾了", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("收尾") { run(.wrapUp) }.controlSize(.small).help(ContextGuard.wrapUpPrompt(percent: x.percent))
                }
            }
            if reviewing {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("審核中⋯").font(.caption).foregroundStyle(.secondary) }
            } else if let v = c.review, let e = v.error {
                Label(e, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else if let v = c.review {
                VStack(alignment: .leading, spacing: 2) {
                    Text("審核：\(Self.verdict(v.verdict))").font(.caption.weight(.semibold))
                    ForEach(v.issues.prefix(3), id: \.self) { Text("・\($0)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !c.tasks.isEmpty { TaskList(tasks: c.tasks, captain: c.captain, expanded: true) }
            if let r = c.report?.report { Text("報告：\(r)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2) }
            Divider()
            HStack(spacing: 8) {
                Button("跳到視窗") { run(.jump) }
                    .buttonStyle(.borderedProminent)
                Button("放行") { run(.approve) }
                    .disabled(c.column != .review || p.mood == .waiting)
                    .help(p.mood == .waiting ? "它在等你回答，要到視窗裡回" : c.column != .review ? "只有待審的才能放行" : "看過了，收進完成")
                Button("退回⋯") { run(.sendBack) }
                Button("丟待辦⋯") { run(.park) }
            }
            .controlSize(.regular)
            .disabled(queueOnly)
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }

    static func verdict(_ v: String) -> String {
        switch v { case "pass": "✅ 通過"; case "concern": "⚠️ 有疑慮"; case "fail": "❌ 不通過"; case "skip": "略過（這輪沒動手）"; default: v }
    }
}

/// 島的大小與每個座位的位置（座位排成 side×side 的等角格子）
struct IslandGeometry {
    static let k: CGFloat = 0.9               // 單張卡（160 寬）縮到島上的比例
    static let dx: CGFloat = 58, dy: CGFloat = 29
    static let top: CGFloat = 62              // 最後排角色＋泡泡要的高度
    static let depth: CGFloat = 14
    let side: Int
    let halfW: CGFloat
    var halfH: CGFloat { halfW / 2 }
    var center: CGPoint { CGPoint(x: halfW + 6, y: Self.top + halfH) }
    var size: CGSize { CGSize(width: halfW * 2 + 12, height: Self.top + halfW + Self.depth + 6) }

    init(count: Int) {
        side = max(1, Int(ceil(sqrt(Double(max(count, 1))))))
        halfW = CGFloat(side - 1) * Self.dx + 80
    }

    /// 第 n 個座位的地板中心；由後往前排，畫的順序就是 n 的順序
    func spot(_ n: Int) -> CGPoint {
        let r = n / side, c = n % side
        return CGPoint(x: center.x + CGFloat(c - r) * Self.dx,
                       y: center.y + CGFloat(c + r - (side - 1)) * Self.dy)
    }
}

/// 島的動畫用 AppKit 畫：計時器只叫這塊 needsDisplay，不經過 SwiftUI。
/// （10-13 實測：TimelineView＋Canvas 每跳一格整個視窗都要重新排版，看板開著 CPU 21–27%，什麼都不畫也 24%；
///   縮到 Dock 也照跑。換成這樣只重畫島本身，而且視窗看不到就停。）
struct IslandCanvas: NSViewRepresentable {
    let island: Island
    let people: [Islander]
    let geo: IslandGeometry
    var scale: CGFloat = 1
    var focus: String? = nil

    func makeNSView(context: Context) -> IslandArtView { IslandArtView() }
    func updateNSView(_ v: IslandArtView, context: Context) {
        v.update(island: island, people: people, geo: geo, scale: scale, focus: focus)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: IslandArtView, context: Context) -> CGSize? {
        CGSize(width: geo.size.width * scale, height: geo.size.height * scale)
    }
}

final class IslandArtView: NSView {
    private var island: Island?
    private var people: [Islander] = []
    private var geo = IslandGeometry(count: 1)
    private var scale: CGFloat = 1
    private var focus: String?
    // 影分身出現／消失的時間：出現「噗」一下、走了淡出（10-13 Kang：像影分身之術，去別人家繞一繞就消失）
    private var born: [String: Date] = [:]
    private var gone: [String: (Islander, Date)] = [:]
    private var timer: Timer?
    private var motionObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        motionObserver = (NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retime(); self?.needsDisplay = true }
            })
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(island new: Island, people: [Islander], geo: IslandGeometry, scale: CGFloat, focus: String?) {
        let now = Date()
        let old = island?.ghosts ?? [], newIDs = Set(new.ghosts.map(\.id))
        for g in new.ghosts where born[g.id] == nil { born[g.id] = now; gone[g.id] = nil }
        for g in old where !newIDs.contains(g.id) { born[g.id] = nil; gone[g.id] = (g, now) }
        island = new; self.people = people; self.geo = geo; self.scale = scale; self.focus = focus
        retime()
        needsDisplay = true
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var visible: Bool { window?.occlusionState.contains(.visible) ?? false }
    private var moving: Bool {
        gone = gone.filter { Date().timeIntervalSince($0.value.1) < 0.8 }
        return people.contains { ![.idle, .asleep, .stuck].contains($0.mood) } || !(island?.ghosts.isEmpty ?? true) || !gone.isEmpty
    }

    /// 要動才開計時器：有人在動、視窗看得到（縮到 Dock、被蓋住、別的桌面都算看不到）、沒開「減少動態效果」
    private func retime() {
        let run = moving && visible && !reduceMotion && !HeatGate.shared.paused   // 機器熱就定格（10-20，跟 cool42 連動）
        if run, timer == nil {
            let t = Timer(timeInterval: 1.0 / 8, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.needsDisplay = true
                    if !self.gone.isEmpty { self.retime() }
                }
            }
            t.tolerance = 0.02
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !run, let t = timer {
            t.invalidate(); timer = nil
        }
    }

    private var heatObs: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        if heatObs == nil {
            heatObs = NotificationCenter.default.addObserver(forName: HeatGate.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retime(); self?.needsDisplay = true }
            }
        }
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        if let w = window {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retime(); self?.needsDisplay = true }
            }
        }
        retime()
    }

    override func removeFromSuperview() {
        timer?.invalidate(); timer = nil
        super.removeFromSuperview()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, let island else { return }
        let now = Date()
        let t = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
        var ctx = Pen(cg)
        ctx.scaleBy(x: scale, y: scale)
        KuboArt.island(ctx, geo: geo, color: KuboArt.islandColor(island.project))
        // 影分身在島的後半圈就先畫（被居民擋住），前半圈最後畫
        func ghosts(back: Bool) {
            for g in island.ghosts where KuboArt.ghostBehind(g, t: t) == back {
                KuboArt.ghost(ctx, geo: geo, who: g, t: t, age: now.timeIntervalSince(born[g.id] ?? .distantPast), fade: 1)
            }
            for (_, (g, at)) in gone where KuboArt.ghostBehind(g, t: t) == back {
                let f = 1 - now.timeIntervalSince(at) / 0.8
                if f > 0 { KuboArt.ghost(ctx, geo: geo, who: g, t: t, age: 10, fade: f) }
            }
        }
        ghosts(back: true)
        // 先畫後排（y 小的）再畫前排，前面的角色蓋住後面的
        let floor = KuboArt.islandColor(island.project).blended(withFraction: 0.45, of: .black) ?? .black
        for (n, p) in people.enumerated().sorted(by: { geo.spot($0.offset).y < geo.spot($1.offset).y }) {
            var c = ctx
            let pt = geo.spot(n)
            c.translateBy(x: pt.x, y: pt.y)
            c.scaleBy(x: IslandGeometry.k, y: IslandGeometry.k)
            KuboArt.tile(c, mood: p.mood, accessory: p.accessory, highlight: p.id == focus,
                         t: t + Double(abs(p.id.hashValue % 1000)) / 137, floor: floor)
        }
        ghosts(back: false)
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
            if let o = motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        }
    }
}

/// 跟 SwiftUI Pen 一樣的用法（值語意：複製一份再平移／縮放不影響原本的），底下畫在 CGContext 上
struct Pen {
    enum Shade { case color(Color) }
    enum Filter { case blur(radius: CGFloat) }
    let cg: CGContext
    private var m = CGAffineTransform.identity
    var opacity: Double = 1
    private var blur: CGFloat = 0

    init(_ cg: CGContext) { self.cg = cg }

    mutating func translateBy(x: CGFloat, y: CGFloat) { m = m.translatedBy(x: x, y: y) }
    mutating func scaleBy(x: CGFloat, y: CGFloat) { m = m.scaledBy(x: x, y: y) }
    mutating func rotate(by a: Angle) { m = m.rotated(by: a.radians) }
    mutating func addFilter(_ f: Filter) { if case .blur(let r) = f { blur = r } }

    private func cgColor(_ s: Shade) -> CGColor { if case .color(let c) = s { return NSColor(c).cgColor }; return .black }

    private func run(_ s: Shade, _ body: () -> Void) {
        cg.saveGState()
        cg.concatenate(m)
        cg.setAlpha(opacity)
        if blur > 0 {       // 模糊＝光暈：用同色陰影代替（只拿來畫影分身的紫光）
            cg.setShadow(offset: .zero, blur: blur * 2 * hypot(m.a, m.b), color: cgColor(s))
        }
        body()
        cg.restoreGState()
    }

    func fill(_ p: Path, with s: Shade) {
        run(s) { cg.addPath(p.cgPath); cg.setFillColor(cgColor(s)); cg.fillPath() }
    }
    func stroke(_ p: Path, with s: Shade, lineWidth: CGFloat) { stroke(p, with: s, style: StrokeStyle(lineWidth: lineWidth)) }
    func stroke(_ p: Path, with s: Shade, style: StrokeStyle) {
        run(s) {
            cg.addPath(p.cgPath)
            cg.setStrokeColor(cgColor(s)); cg.setLineWidth(style.lineWidth)
            cg.setLineCap(style.lineCap); cg.setLineJoin(style.lineJoin)
            cg.strokePath()
        }
    }
    /// 置中畫一個字（泡泡裡的「!」「?」）
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: CGPoint) {
        run(.color(.white)) {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
            let sz = a.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            a.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

// MARK: - 畫圖（座標跟決策板的 SVG 一樣：地板中心 (0,0)，腳底在 (0,14)）

enum KuboArt {
    static let clay = NSColor(srgbRed: 0xD9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
    static let clayDark = NSColor(srgbRed: 0xB3/255, green: 0x5C/255, blue: 0x3F/255, alpha: 1)
    static let clayLight = NSColor(srgbRed: 0xF2/255, green: 0xA0/255, blue: 0x7F/255, alpha: 1)
    static let ink = Color(red: 0x2a/255, green: 0x1d/255, blue: 0x18/255)
    static let stuckOrange = NSColor(srgbRed: 0xFF/255, green: 0x6A/255, blue: 0x00/255, alpha: 1)

    @MainActor static func tint(_ m: Mood) -> NSColor {
        switch m {
        case .working: Look.color(.working)
        case .waiting: Look.color(.input)
        case .finished: Look.color(.done)
        case .stuck: stuckOrange   // Kang 10-20：等待／卡住要亮橘，systemOrange 在深色底看起來偏黃
        case .idle, .asleep: .systemGray
        }
    }

    static let islandPalette: [NSColor] = [0x5c3a33, 0x2b5a54, 0x30477a, 0x5a4a2a, 0x4a3266, 0x3a5a33, 0x5a3350].map {
        NSColor(srgbRed: CGFloat($0 >> 16 & 0xff) / 255, green: CGFloat($0 >> 8 & 0xff) / 255, blue: CGFloat($0 & 0xff) / 255, alpha: 1)
    }
    /// 專案名固定配一個島色（不用 hashValue：每次啟動會變）
    static func islandColor(_ project: String) -> NSColor {
        islandPalette[Int(project.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } % UInt32(islandPalette.count))]
    }

    static func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
        p.closeSubpath()
        return p
    }
    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) -> Path {
        r > 0 ? Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r) : Path(CGRect(x: x, y: y, width: w, height: h))
    }

    static func island(_ ctx: Pen, geo: IslandGeometry, color: NSColor) {
        let c = geo.center, w = geo.halfW, h = geo.halfH, d = IslandGeometry.depth
        ctx.fill(poly([(c.x - w, c.y), (c.x, c.y + h), (c.x, c.y + h + d), (c.x - w, c.y + d)]), with: .color(Color(nsColor: color).opacity(0.75)))
        ctx.fill(poly([(c.x + w, c.y), (c.x, c.y + h), (c.x, c.y + h + d), (c.x + w, c.y + d)]), with: .color(Color(nsColor: color).opacity(0.55)))
        ctx.fill(poly([(c.x - w, c.y), (c.x, c.y + h), (c.x, c.y + h + d), (c.x - w, c.y + d)]), with: .color(.black.opacity(0.3)))
        ctx.fill(poly([(c.x + w, c.y), (c.x, c.y + h), (c.x, c.y + h + d), (c.x + w, c.y + d)]), with: .color(.black.opacity(0.45)))
        ctx.fill(poly([(c.x - w, c.y), (c.x, c.y - h), (c.x + w, c.y), (c.x, c.y + h)]), with: .color(Color(nsColor: color)))
    }

    /// 0…1…0 的三角波
    static func wave(_ t: Double, period: Double) -> Double { let x = (t / period).truncatingRemainder(dividingBy: 1); return x < 0.5 ? x * 2 : 2 - x * 2 }

    @MainActor static func tile(_ ctx: Pen, mood: Mood, accessory: Accessory?, highlight: Bool = false, t: Double, floor: NSColor) {
        let sc = Color(nsColor: tint(mood))
        // 地板
        ctx.fill(poly([(-70, 0), (0, -35), (70, 0), (0, 35)]), with: .color(Color(nsColor: floor)))
        ctx.fill(poly([(-70, 0), (0, 35), (0, 41), (-70, 6)]), with: .color(.black.opacity(0.28)))
        ctx.fill(poly([(70, 0), (0, 35), (0, 41), (70, 6)]), with: .color(.black.opacity(0.4)))
        if highlight {
            ctx.stroke(Path(ellipseIn: CGRect(x: -44, y: -7, width: 88, height: 34)), with: .color(.white.opacity(0.85)), lineWidth: 2.5)
        }
        if mood != .idle && mood != .asleep {
            let ring = Path(ellipseIn: CGRect(x: -34, y: -3, width: 68, height: 26))
            ctx.fill(ring, with: .color(sc.opacity(0.12)))
            let pulse = mood == .stuck ? 0.7 : 0.35 + 0.55 * wave(t, period: 1.6)
            ctx.stroke(ring, with: .color(sc.opacity(pulse)), lineWidth: 3)
        }
        // 桌子、螢幕、盆栽
        var desk = ctx
        desk.translateBy(x: 0, y: -14)
        desk.fill(poly([(-38, 0), (0, -19), (38, 0), (0, 19)]), with: .color(Color(red: 0.81, green: 0.65, blue: 0.50)))
        desk.fill(poly([(-38, 0), (0, 19), (0, 23), (-38, 4)]), with: .color(Color(red: 0.66, green: 0.52, blue: 0.37)))
        desk.fill(poly([(38, 0), (0, 19), (0, 23), (38, 4)]), with: .color(Color(red: 0.56, green: 0.42, blue: 0.29)))
        desk.fill(poly([(-24, -6), (-4, -16), (-4, -34), (-24, -24)]), with: .color(Color(red: 0.17, green: 0.15, blue: 0.20)))
        desk.fill(poly([(-22, -8), (-6, -16), (-6, -31), (-22, -23)]),
                  with: .color(mood == .idle || mood == .asleep ? Color(red: 0.23, green: 0.20, blue: 0.27) : sc.opacity(0.85)))
        desk.fill(Path(ellipseIn: CGRect(x: 19, y: -11, width: 10, height: 10)), with: .color(Color(red: 0.36, green: 0.64, blue: 0.36)))
        desk.fill(rect(21, -3, 6, 5), with: .color(Color(red: 0.55, green: 0.35, blue: 0.23)))
        // 角色
        var me = ctx
        me.translateBy(x: 0, y: 14)
        var body = me
        switch mood {
        case .waiting: body.translateBy(x: 0, y: -7 * max(0, sin(t / 0.7 * 2 * .pi)))
        case .finished: body.rotate(by: .degrees(3 * sin(t / 2.4 * 2 * .pi)))
        default: break
        }
        if mood == .asleep { body.opacity = 0.8 }
        kubo(body, mood: mood, t: t)
        if let a = accessory { self.accessory(body, a) }
        bubble(me, mood: mood, t: t, color: sc)
    }

    static func kubo(_ ctx: Pen, mood: Mood, t: Double) {
        let c0 = Color(nsColor: clay), c1 = Color(nsColor: clayDark), c2 = Color(nsColor: clayLight)
        for x in [-16.0, -7, 2, 11] { ctx.fill(rect(x, -12, 5, 12), with: .color(c1)) }
        ctx.fill(rect(-20, -40, 40, 29), with: .color(c0))
        ctx.fill(rect(-20, -40, 40, 4), with: .color(c2.opacity(0.55)))
        let typing = mood == .working ? -3 * wave(t, period: 0.5) : 0
        ctx.fill(rect(-27, -27 + typing, 7, 7), with: .color(c0))
        ctx.fill(rect(20, -27 + (mood == .working ? -3 - typing : 0), 7, 7), with: .color(c0))
        switch mood {
        case .finished:
            var p = Path()
            p.move(to: CGPoint(x: -12, y: -28)); p.addLine(to: CGPoint(x: -9, y: -32)); p.addLine(to: CGPoint(x: -6, y: -28))
            p.move(to: CGPoint(x: 6, y: -28)); p.addLine(to: CGPoint(x: 9, y: -32)); p.addLine(to: CGPoint(x: 12, y: -28))
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2.5, lineCap: .square))
        case .asleep:
            ctx.fill(rect(-12, -30, 6, 2.5), with: .color(ink)); ctx.fill(rect(6, -30, 6, 2.5), with: .color(ink))
        case .idle:     // 休息：眼睛睜開、右手拿一杯冒熱氣的咖啡
            ctx.fill(rect(-11, -35, 4, 9), with: .color(ink)); ctx.fill(rect(7, -35, 4, 9), with: .color(ink))
            let cup = Color(red: 0.96, green: 0.94, blue: 0.90)
            ctx.fill(rect(22, -36, 10, 11, r: 1.5), with: .color(cup))
            ctx.fill(rect(22, -36, 10, 2.5), with: .color(Color(red: 0.42, green: 0.27, blue: 0.18)))   // 咖啡面
            ctx.stroke(Path(roundedRect: CGRect(x: 31, y: -33, width: 5, height: 5), cornerRadius: 2), with: .color(cup), lineWidth: 2)
            for (i, x) in [25.0, 29].enumerated() {
                var p = Path()
                p.move(to: CGPoint(x: x, y: -39)); p.addQuadCurve(to: CGPoint(x: x, y: -47), control: CGPoint(x: x + 3, y: -43))
                p.addQuadCurve(to: CGPoint(x: x, y: -54), control: CGPoint(x: x - 3, y: -51))
                ctx.stroke(p, with: .color(Color(red: 0.62, green: 0.66, blue: 0.76).opacity(0.45 + 0.4 * wave(t + Double(i) * 0.6, period: 1.8))),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        default:
            ctx.fill(rect(-11, -35, 4, 9), with: .color(ink)); ctx.fill(rect(7, -35, 4, 9), with: .color(ink))
        }
    }

    /// 影分身：半透明、沒有腳（下襬波浪）、飄著繞島走；本尊照樣坐在自己島上打字
    static func ghostAngle(_ who: Islander, t: Double) -> Double {
        let phase = Double(who.id.unicodeScalars.reduce(UInt32(3)) { $0 &* 31 &+ $1.value } % 628) / 100
        return t / 9 * 2 * .pi + phase                                 // 9 秒繞一圈
    }
    static func ghostBehind(_ who: Islander, t: Double) -> Bool { sin(ghostAngle(who, t: t)) < 0 }

    @MainActor static func ghost(_ base: Pen, geo: IslandGeometry, who: Islander, t: Double, age: Double, fade: Double) {
        let a = ghostAngle(who, t: t)
        let c = geo.center
        let x = c.x + geo.halfW * 0.72 * cos(a)                         // 沿著島的外圈飄
        let y = c.y + geo.halfH * 0.72 * sin(a) + 4
        let lift = 10 + 5 * wave(t, period: 1.8)                        // 飄在半空
        let alpha = min(1, max(0, age / 0.5)) * fade
        var shadow = base
        shadow.opacity = alpha
        shadow.fill(Path(ellipseIn: CGRect(x: x - 14, y: y - 3, width: 28, height: 8)), with: .color(.black.opacity(0.3)))
        var ctx = base
        ctx.translateBy(x: x, y: y - lift)
        ctx.scaleBy(x: IslandGeometry.k * 0.85, y: IslandGeometry.k * 0.85)
        ctx.opacity = 0.8 * alpha
        let tintC = Color(nsColor: tint(.working))
        let pale = Color(nsColor: clayLight.blended(withFraction: 0.55, of: .white) ?? clayLight)
        if -sin(a) < 0 { ctx.scaleBy(x: -1, y: 1) }                     // 往哪飄就面向哪（逆時針繞）
        var body = Path()
        body.move(to: CGPoint(x: -20, y: -40)); body.addLine(to: CGPoint(x: 20, y: -40)); body.addLine(to: CGPoint(x: 20, y: -6))
        let sway = 2 * sin(t * 5)
        for i in 0..<4 {                                                // 波浪下襬
            let x0 = 20 - Double(i) * 10
            body.addQuadCurve(to: CGPoint(x: x0 - 10, y: -6), control: CGPoint(x: x0 - 5, y: (i % 2 == 0 ? 2 : -10) + sway))
        }
        body.closeSubpath()
        var glow = ctx                                                  // 一圈紫光（影分身的查克拉）
        glow.addFilter(.blur(radius: 5))
        glow.stroke(body, with: .color(tintC), lineWidth: 6)
        ctx.fill(body, with: .color(pale))
        ctx.stroke(body, with: .color(tintC.opacity(0.9)), lineWidth: 1.5)
        ctx.fill(rect(-27, -24, 7, 7), with: .color(pale))              // 手往前伸，飄的樣子
        ctx.fill(rect(20, -24, 7, 7), with: .color(pale))
        ctx.fill(rect(-11, -35, 4, 9), with: .color(ink)); ctx.fill(rect(7, -35, 4, 9), with: .color(ink))
        if let acc = who.accessory { accessory(ctx, acc) }
        // 出現時「噗」一團煙
        if age < 0.6 {
            let k = age / 0.6
            var puff = base
            puff.translateBy(x: x, y: y - 18)
            puff.opacity = (1 - k) * 0.8
            for i in 0..<6 {
                let r = 10 + 26 * k, ang = Double(i) / 6 * 2 * .pi
                puff.fill(Path(ellipseIn: CGRect(x: r * cos(ang) - 7, y: r * sin(ang) * 0.6 - 7, width: 14, height: 14)), with: .color(.white))
            }
        }
    }

    static func accessory(_ ctx: Pen, _ a: Accessory) {
        let dark = Color(red: 0.23, green: 0.20, blue: 0.27)
        switch a {
        case .crown:
            let p = poly([(-9, -41), (-11, -51), (-5, -46), (0, -54), (5, -46), (11, -51), (9, -41)])
            ctx.fill(p, with: .color(Color(red: 1, green: 0.78, blue: 0.24)))
            ctx.stroke(p, with: .color(Color(red: 0.79, green: 0.57, blue: 0.10)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        case .headset:
            var band = Path()
            band.move(to: CGPoint(x: -20, y: -30))
            band.addQuadCurve(to: CGPoint(x: 0, y: -48), control: CGPoint(x: -20, y: -48))
            band.addQuadCurve(to: CGPoint(x: 20, y: -30), control: CGPoint(x: 20, y: -48))
            ctx.stroke(band, with: .color(dark), lineWidth: 3)
            ctx.fill(rect(-24, -35, 7, 11, r: 3), with: .color(dark)); ctx.fill(rect(17, -35, 7, 11, r: 3), with: .color(dark))
            var mic = Path()
            mic.move(to: CGPoint(x: -21, y: -25)); mic.addQuadCurve(to: CGPoint(x: -7, y: -15), control: CGPoint(x: -19, y: -16))
            ctx.stroke(mic, with: .color(dark), lineWidth: 1.6)
            ctx.fill(Path(ellipseIn: CGRect(x: -9, y: -17, width: 4, height: 4)), with: .color(dark))
        case .glasses:
            var g = Path()
            g.addEllipse(in: CGRect(x: -14.5, y: -36, width: 11, height: 11))
            g.addEllipse(in: CGRect(x: 3.5, y: -36, width: 11, height: 11))
            g.move(to: CGPoint(x: -3.5, y: -30.5)); g.addLine(to: CGPoint(x: 3.5, y: -30.5))
            ctx.stroke(g, with: .color(Color(red: 0.16, green: 0.13, blue: 0.20)), lineWidth: 1.8)
        }
    }

    static func bubble(_ ctx: Pen, mood: Mood, t: Double, color: Color) {
        var b = ctx
        b.translateBy(x: 0, y: -3 * wave(t, period: 1.4))
        switch mood {
        case .working:
            b.fill(rect(12, -68, 30, 16, r: 8), with: .color(color))
            for (i, x) in [20.0, 27, 34].enumerated() {
                let o = 0.25 + 0.75 * wave(t + Double(i) * 0.2, period: 1.0)
                b.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: -62.2, width: 4.4, height: 4.4)), with: .color(.white.opacity(o)))
            }
        case .finished:
            b.fill(Path(ellipseIn: CGRect(x: 16, y: -70, width: 20, height: 20)), with: .color(color))
            var p = Path()
            p.move(to: CGPoint(x: 21, y: -60)); p.addLine(to: CGPoint(x: 24.5, y: -56.5)); p.addLine(to: CGPoint(x: 31, y: -63.5))
            b.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
        case .waiting, .stuck:
            b.fill(rect(16, -72, 20, 20, r: 10), with: .color(color))
            b.text(mood == .waiting ? "!" : "?", size: 15, weight: .heavy, color: .white, at: CGPoint(x: 26, y: -62))
        case .idle:
            break
        case .asleep:   // 睡覺：頭上斜斜往上三個 z，一個比一個大（10-15 Kang）；整島都睡時計時器停，就停在這一格，不多耗 CPU
            let zz = NSColor(srgbRed: 0.62, green: 0.68, blue: 0.88, alpha: 1)
            for (i, (x, y, s)) in [(17.0, -52.0, 11.0), (28, -64, 15), (42, -79, 20)].enumerated() {
                var z = ctx
                z.opacity = 0.55 + 0.45 * wave(t + Double(i) * 0.5, period: 2.4)
                z.translateBy(x: 0, y: -2 * wave(t + Double(i) * 0.5, period: 2.4))
                z.text("z", size: s, weight: .heavy, color: zz, at: CGPoint(x: x, y: y))
            }
        }
    }
}
