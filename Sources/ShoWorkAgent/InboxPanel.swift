import AppKit
import SwiftUI
import ShoWorkCore

// 收件匣（10-21 Kang：「我一直在操作終端機，戰情中心是不是失去使用意義？」）：
// 所有在等你的 AI 列在右邊，按選項或打字就把答案送進那個 session（tmux 打字／看板直送），不用切回終端機。
// 底下是「交給隊長」：隊長不在就開一個背景隊長（模型 captain.model，預設 Opus 5.5，10-26 由 Fable 改）。
// 權限對話框（第 2 步）：允許／一律允許／拒絕，寫回答檔給等著的 PermissionRequest hook（Permit.swift）。
// 選擇題（AskUserQuestion）與計畫確認（ExitPlanMode）也走同一條 hook（10-25）：按選項／勾多選／打「其他」、核准／退回計畫。
// 規則在 ShoWorkCore/Inbox.swift；送出走 BoardActions.answer／permit／askCaptain。

struct InboxPanel: View {
    let items: [InboxItem]
    let captain: BoardCard?
    let onAnswer: (InboxItem, String) -> Void
    let onPermit: (InboxItem, PermitAnswer) -> Void
    let onJump: (String) -> Void
    let onFocus: (String) -> Void
    let onCaptain: (String) -> Void
    var onClose: (() -> Void)? = nil
    var captainBusy = false
    var thread: [CaptainLine] = []        // 隊長對話（10-22 第 3 步）
    var tasks: [CaptainTask] = []         // 還沒結的派工單
    // 右側對話窗格（10-25）：點了某個 AI，下半部改成跟它的對話；nil＝隊長
    var person: BoardCard? = nil
    var personThread: [CaptainLine] = []
    var onPersonSend: (String) -> Void = { _ in }
    var onBack: () -> Void = {}
    var runs: [RunProgress] = []          // 背景長工作的即時進度（名字下方的進度條；10-26）

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full").foregroundStyle(.secondary)
                Text("等你回答").font(.headline)
                let open = items.filter { $0.answered == nil }.count
                if open > 0 {
                    Text("\(open)").font(.caption.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(nsColor: KuboArt.tint(.waiting)).opacity(0.3), in: Capsule())
                }
                Spacer()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("收起")
                }
            }
            if items.isEmpty {
                Label("現在沒有 AI 在等你", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { it in
                            InboxRow(item: it, onAnswer: { onAnswer(it, $0) }, onPermit: { onPermit(it, $0) }, onJump: { onJump(it.id) }, onFocus: { onFocus(it.id) }, runs: runs)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let p = person {
                CaptainPanel(captain: p, busy: false, thread: personThread, tasks: [], onSend: onPersonSend, onFocus: onFocus,
                             person: true, onBack: onBack, onJump: { onJump(p.id) }, runs: runs)
                    .id(p.sessionId)                  // 換人：輸入框、捲動位置重來
                    .frame(maxHeight: .infinity)
            } else {
                CaptainPanel(captain: captain, busy: captainBusy, thread: thread, tasks: tasks, onSend: onCaptain, onFocus: onFocus, runs: runs)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AnswerCard.cardBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct InboxRow: View {
    let item: InboxItem
    let onAnswer: (String) -> Void
    let onPermit: (PermitAnswer) -> Void
    let onJump: () -> Void
    let onFocus: () -> Void
    var runs: [RunProgress] = []
    @State private var text = ""
    @State private var sentText: String?   // 送出後顯示的那行

    private var done: Bool { item.answered != nil || sentText != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: KuboArt.tint(done ? .idle : .waiting))).frame(width: 8, height: 8)
                Button(action: onFocus) { Text(item.card.title).font(.subheadline.weight(.semibold)).lineLimit(1) }
                    .buttonStyle(.plain).help("在大樓裡找到它")
                Spacer(minLength: 4)
                if let t = item.since {
                    // 每分鐘才更新（10-21：Text(style: .relative) 每秒重算，電視寬時整個視窗跟著重排版，閒置 CPU 9%）
                    TimelineView(.everyMinute) { ctx in
                        Text(InboxRow.ago(t, now: ctx.date)).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }
            }
            Text(item.card.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(RunBar(card: item.card, name: item.card.title.split(separator: "-").first.map(String.init) ?? item.card.title, runs: runs, thickness: 2))
            Text(item.question).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).lineLimit(6)
            if let c = item.context, item.kind != .reply || item.generic {
                Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if done {
                Label(sentText ?? "已回答，等它回應", systemImage: "paperplane")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if item.kind == .permit, let p = item.card.permit {
                PermitBox(permit: p, text: $text, decide: decide)
            } else if item.kind == .ask, let qs = item.card.permit?.questions {
                AskBox(questions: qs, decide: decide)
            } else if item.kind == .plan, let p = item.card.permit {
                PlanBox(plan: p.plan ?? p.summary, text: $text, decide: decide)
            } else if item.kind == .reply {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.options, id: \.self) { o in
                        Button { send(o) } label: {
                            Text(o).font(.callout).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 6) {
                    ChatInput(text: $text, placeholder: "或直接打字回答⋯", onSubmit: { send(text) })
                    Button("送出") { send(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
            } else {
                HStack {
                    Text(item.card.blockedReason == .permission ? "這個對話框沒接到戰情中心（session 開在安裝前），要在終端機裡按" : "選單要在終端機裡選")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("跳到視窗", action: onJump).controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(done ? 0.03 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fileDrop($text)
        .opacity(done ? 0.7 : 1)
        .onChange(of: item.since) { _, _ in if item.answered == nil { sentText = nil } }
        .onChange(of: item.card.permit?.id) { _, _ in sentText = nil }   // 下一個權限對話框：重新可按   // 它又問了新的：重新可答
    }

    private func send(_ s: String) {
        let t = Inbox.message(s)
        guard !t.isEmpty, sentText == nil else { return }
        sentText = "已送出「\(t)」，等它回應"; text = ""
        onAnswer(t)
    }

    static func ago(_ t: Date, now: Date) -> String {
        let m = Int(now.timeIntervalSince(t) / 60)
        if m < 1 { return "剛剛" }
        if m < 60 { return "\(m) 分鐘前" }
        return m < 24 * 60 ? "\(m / 60) 小時前" : "\(m / 1440) 天前"
    }

    private func decide(_ a: PermitAnswer) {
        guard sentText == nil else { return }
        if let p = item.card.permit, p.isAsk || p.isPlan {
            sentText = "已回答：\(Permit.answerText(p, a))"; text = ""
            onPermit(a); return
        }
        switch a.decision {
        case .allow: sentText = "已允許"
        case .always: sentText = "已允許，以後同類不再問"
        case .deny: sentText = a.message.map { "已拒絕：\($0)" } ?? "已拒絕"
        }
        text = ""
        onPermit(a)
    }
}

/// 權限對話框：要做什麼＋三個按鈕；打字＝拒絕並告訴它改怎麼做
private struct PermitBox: View {
    let permit: PermitRequest
    @Binding var text: String
    let decide: (PermitAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(permit.summary).font(.system(.caption, design: .monospaced)).lineLimit(5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            // 自己畫底色：電視上的戰情中心通常不是前景視窗，系統的 prominent 按鈕會變灰
            HStack(spacing: 6) {
                choice("允許", Color(nsColor: KuboArt.tint(.finished)), strong: true) { decide(PermitAnswer(.allow)) }
                if let rule = permit.alwaysLabel {
                    choice("一律允許", Color(nsColor: KuboArt.tint(.finished))) { decide(PermitAnswer(.always)) }
                        .help("以後不再問：\(rule)")
                }
                choice("拒絕", Color(nsColor: KuboArt.tint(.waiting))) { decide(PermitAnswer(.deny)) }
            }
            HStack(spacing: 6) {
                TextField("或拒絕並告訴它改怎麼做⋯", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    .onSubmit(denyWithText)
                Button("送出", action: denyWithText)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            Text("終端機那邊也能按，先按的算").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func choice(_ title: String, _ color: Color, strong: Bool = false, action: @escaping () -> Void) -> some View {
        inboxChoice(title, color, strong: strong, action: action)
    }

    private func denyWithText() {
        let t = Inbox.message(text)
        guard !t.isEmpty else { return }
        decide(PermitAnswer(.deny, message: t))
    }
}

/// 拖檔案進來（10-25）：把路徑接到這個輸入框的字後面（Inbox.withPaths）；拖進來時框框亮起來
struct FileDrop: ViewModifier {
    @Binding var text: String
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).opacity(over ? 1 : 0))
            .dropDestination(for: URL.self) { urls, _ in
                let paths = urls.filter(\.isFileURL).map(\.path)
                guard !paths.isEmpty else { return false }
                text = Inbox.withPaths(text, paths)
                return true
            } isTargeted: { over = $0 }
    }
}

extension View {
    /// 檔案拖到這一區：路徑填進 text
    func fileDrop(_ text: Binding<String>) -> some View { modifier(FileDrop(text: text)) }
}

/// 收件匣的大按鈕：自己畫底色（電視上的戰情中心通常不是前景視窗，系統的 prominent 按鈕會變灰）
private func inboxChoice(_ title: String, _ color: Color, strong: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title).font(.callout.weight(strong ? .semibold : .regular))
            .frame(maxWidth: .infinity).padding(.vertical, 5)
            .background(color.opacity(strong ? 0.55 : 0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

/// 選擇題（AskUserQuestion）：單選按一下、多選打勾、不在選項裡的打在「其他」。
/// 只有一題又是單選：按選項就送出；其他情況每題都答了才能按「送出」。
private struct AskBox: View {
    let questions: [AskQuestion]
    let decide: (PermitAnswer) -> Void
    @State private var picks: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    private var quick: Bool { questions.count == 1 && !questions[0].multiSelect }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions, id: \.self) { q in question(q) }
            if !quick {
                inboxChoice("送出", Color(nsColor: KuboArt.tint(.finished)), strong: true, action: send)
                    .disabled(!complete).opacity(complete ? 1 : 0.5)
            }
            Text("終端機那邊也能答，先答的算").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func question(_ q: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let h = q.header {
                Text(h).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Text(q.question).font(.callout.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if q.multiSelect { Text("可以選多個").font(.caption2).foregroundStyle(.secondary) }
            ForEach(q.options, id: \.self) { o in
                if q.multiSelect {
                    Toggle(isOn: Binding(get: { picks[q.question, default: []].contains(o.label) },
                                         set: { on in if on { picks[q.question, default: []].insert(o.label) } else { picks[q.question]?.remove(o.label) } })) {
                        label(o)
                    }
                    .toggleStyle(.checkbox)
                } else {
                    let on = picks[q.question]?.contains(o.label) == true
                    Button {
                        picks[q.question] = [o.label]; other[q.question] = nil
                        if quick { send() }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.accentColor : .secondary)
                            label(o)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.accentColor.opacity(on ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(o.label)
                }
            }
            HStack(spacing: 6) {
                TextField("其他⋯（自己打）", text: Binding(get: { other[q.question] ?? "" }, set: { other[q.question] = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    .onSubmit { if quick { send() } }
                if quick {
                    Button("送出", action: send).disabled(typed(q).isEmpty)
                }
            }
            .controlSize(.small)
        }
    }

    private func label(_ o: AskQuestion.Option) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(o.label).font(.callout)
            if let d = o.description { Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func typed(_ q: AskQuestion) -> String { Inbox.message(other[q.question] ?? "") }

    /// 每題的答案：多選＝勾的＋「其他」；單選＝「其他」有字就用它，不然用按的那個（照選項順序）
    private func answer(_ q: AskQuestion) -> [String] {
        let chosen = q.options.map(\.label).filter { picks[q.question]?.contains($0) == true }
        let t = typed(q)
        if q.multiSelect { return chosen + (t.isEmpty ? [] : [t]) }
        return t.isEmpty ? chosen : [t]
    }

    private var complete: Bool { questions.allSatisfy { !answer($0).isEmpty } }

    private func send() {
        guard complete else { return }
        decide(PermitAnswer(.allow, answers: Dictionary(questions.map { ($0.question, answer($0)) }, uniquingKeysWith: { a, _ in a })))
    }
}

/// 計畫確認（ExitPlanMode）：看計畫、核准，或退回並說要改什麼
private struct PlanBox: View {
    let plan: String
    @Binding var text: String
    let decide: (PermitAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(CaptainBubble.markdown(plan)).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 220)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 6) {
                inboxChoice("核准，開始做", Color(nsColor: KuboArt.tint(.finished)), strong: true) { decide(PermitAnswer(.allow)) }
                inboxChoice("退回", Color(nsColor: KuboArt.tint(.waiting))) { decide(PermitAnswer(.deny, message: Inbox.message(text).isEmpty ? nil : Inbox.message(text))) }
            }
            HStack(spacing: 6) {
                TextField("退回並告訴它要改什麼⋯", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    .onSubmit(sendBack)
                Button("送出", action: sendBack)
                    .disabled(Inbox.message(text).isEmpty)
            }
            .controlSize(.small)
            Text("終端機那邊也能按，先按的算").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sendBack() {
        let t = Inbox.message(text)
        guard !t.isEmpty else { return }
        decide(PermitAnswer(.deny, message: t))
    }
}

/// 隊長對話（10-22 第 3 步：直接派工給隊長）：你送的話、隊長每輪最後講給你聽的話、其他 AI 的回報（灰色一行），
/// 下面是還沒結的派工單和輸入框。隊長不在：送出時開一個（BoardActions.askCaptain）。資料來自隊長的對話紀錄（CaptainThread）。
/// person＝true（10-25 右側對話窗格）：同一個面板看任何一個 AI——多了每輪中途的話、工具一行摘要；回到隊長、跳到終端機兩顆鈕。
private struct CaptainPanel: View {
    let captain: BoardCard?
    let busy: Bool
    let thread: [CaptainLine]
    let tasks: [CaptainTask]
    let onSend: (String) -> Void
    let onFocus: (String) -> Void
    var person = false
    var onBack: () -> Void = {}
    var onJump: () -> Void = {}
    var runs: [RunProgress] = []
    @State private var text = ""
    @State private var paneHeight: CGFloat = 400     // 輸入框最多拉到窗格一半
    @State private var pending: (text: String, at: Date)?
    @State private var showReports = true

    private var name: String { captain.map { $0.title.split(separator: "-").first.map(String.init) ?? "隊長" } ?? "隊長" }
    private var thinking: Bool { captain?.column == .active }
    /// 隱藏鈕（person 模式）：只看你和它講的話，工具摘要和回報收起來
    private var shown: [CaptainLine] { showReports ? thread : thread.filter { $0.role != .report && $0.role != .tool } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                if person {
                    Button(action: onBack) { Image(systemName: "chevron.backward") }
                        .buttonStyle(.borderless).help("回到隊長對話").accessibilityLabel("回到隊長對話")
                }
                Image(systemName: person ? "person.crop.circle" : "person.crop.circle.badge.checkmark").foregroundStyle(.secondary)
                Text(person ? name : captain == nil ? "隊長" : "隊長 \(name)").font(.subheadline.weight(.semibold)).lineLimit(1)
                if captain != nil, thinking {
                    ProgressView().controlSize(.mini)
                    Text("思考中⋯").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if person {
                    Button(action: onJump) { Image(systemName: "terminal") }
                        .buttonStyle(.borderless).help("跳到它的終端機視窗").accessibilityLabel("跳到終端機")
                    Button { showReports.toggle() } label: {
                        Image(systemName: showReports ? "list.bullet.rectangle" : "list.bullet.rectangle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help(showReports ? "只看你和它講的話（收起工具與回報）" : "顯示工具與回報")
                } else if captain == nil {
                    Text("不在：送出時開 \(BoardActions.modelTitle(BoardActions.captainModel)) 隊長").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Button { showReports.toggle() } label: {
                        Image(systemName: showReports ? "text.bubble" : "text.bubble.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help(showReports ? "隱藏其他 AI 的回報，只看你和隊長的對話" : "顯示其他 AI 的回報")
                }
            }
            if person, let c = captain {
                HStack(spacing: 6) {
                    Text("\(c.project)・\(c.reason)").lineLimit(1)
                    Spacer(minLength: 4)
                    if let r = RunProgress.pick(runs, for: name) {
                        Text(r.caption(for: name)).monospacedDigit().lineLimit(1).layoutPriority(1)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .modifier(RunBar(card: c, name: name, runs: runs))
            } else if let c = captain {
                Color.clear.frame(height: 0).modifier(RunBar(card: c, name: name, runs: runs))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if shown.isEmpty && pending == nil {
                            Text(person ? "讀取對話中⋯（還沒有對話的話，在下面打一句話給它）" : captain == nil ? "還沒有隊長。在下面打一句話，戰情中心會開一個隊長來接。" : "還沒有對話。在下面打一句話交給隊長。")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(shown) { CaptainBubble(line: $0, speaker: person ? name : "隊長") }
                        if let p = pending {
                            CaptainBubble(line: CaptainLine(id: "pending", at: p.at, role: .kang, text: p.text, via: "送出中⋯"), speaker: name)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .scrollIndicators(.automatic)
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: thread.last?.id) { _, _ in
                    // 隊長那邊出現了剛送的話：拿掉「送出中」
                    if let p = pending, thread.contains(where: { $0.role == .kang && $0.text == p.text }) || Date().timeIntervalSince(p.at) > 180 { pending = nil }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: pending?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            if !tasks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("派工中（\(tasks.count)）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(tasks.prefix(4)) { t in
                        Button { if let sid = t.toSession { onFocus(sid) } } label: {
                            HStack(spacing: 5) {
                                Circle().fill(color(t.state)).frame(width: 6, height: 6)
                                Text("→ \(t.to.split(separator: "-").first.map(String.init) ?? t.to)").font(.caption.weight(.semibold))
                                Text(t.text.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(t.state.title).font(.caption2).foregroundStyle(color(t.state))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("\(t.id)：在大樓裡找到它")
                    }
                    if tasks.count > 4 { Text("還有 \(tasks.count - 4) 張（showork tasks）").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                ChatInput(text: $text, placeholder: person ? "跟 \(name) 說⋯" : captain == nil ? "要做什麼？會開一個隊長來決定給哪個 AI" : "跟隊長說⋯（交辦、追問、拍板都可以）",
                          resizable: true, maxHeight: max(80, paneHeight / 2), onSubmit: send)
                if busy { ProgressView().controlSize(.small) }
                Button("送出", action: send)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .fileDrop($text)          // 檔案拖到對話區任何地方：路徑填進下面的輸入框
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
    }

    private func color(_ s: CaptainTask.State) -> Color {
        switch s {
        case .blocked: Color(nsColor: KuboArt.tint(.waiting))
        case .review: .orange
        case .done: Color(nsColor: KuboArt.tint(.finished))
        default: Color(nsColor: KuboArt.tint(.working))
        }
    }

    private func send() {
        let t = Inbox.message(text)
        guard !t.isEmpty, !busy else { return }
        text = ""
        pending = (t, Date())
        onSend(t)
    }
}

private struct CaptainBubble: View {
    let line: CaptainLine
    var speaker = "隊長"

    var body: some View {
        switch line.role {
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "wrench.and.screwdriver").font(.caption2)
                Text(line.text).font(.caption).lineLimit(1)
                Spacer(minLength: 2)
            }
            .foregroundStyle(.secondary)
            .help(line.text)
        case .report:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "doc.text").font(.caption2)
                Text(line.text).font(.caption).lineLimit(1)
                Spacer(minLength: 2)
                time
            }
            .foregroundStyle(.secondary)
            .help(line.text)
        case .kang:
            VStack(alignment: .trailing, spacing: 2) {
                Text(line.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 4) { Text("你" + (line.via.map { "・" + $0 } ?? "")); time }.font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 24)
        case .captain:
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.markdown(line.text)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 4) { Text(speaker); time }.font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.trailing, 12)
        }
    }

    @ViewBuilder private var time: some View {
        if let t = line.at { Text(t.formatted(date: .omitted, time: .shortened)).monospacedDigit() }
    }

    /// **粗體**、`code` 這類行內語法；換行照原樣
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// 名字下方的細進度條（10-26）：背景長工作在跑時卡片每輪才更新、看起來像停了。
/// 優先用 AI 即時寫的 run/progress（10 分鐘沒更新就不算），沒有就退回這一輪自報的 --progress，兩個都沒有不畫。
/// 條畫在那一行下緣，只多 4pt 高；進度的字放在滑鼠提示和 VoiceOver。
struct RunBar: ViewModifier {
    let card: BoardCard
    let name: String
    let runs: [RunProgress]
    var thickness: CGFloat = 3          // 收件匣卡片用 2

    func body(content: Content) -> some View {
        let run = RunProgress.pick(runs, for: name)
        let f: Double? = run?.fraction ?? card.report?.progress.map { Double($0) / 100 }
        let tip = run.map { "\($0.caption(for: name))（即時）" } ?? card.report?.progress.map { "這一輪自報完成度 \($0)%" } ?? ""
        if let f {
            content.padding(.bottom, thickness + 1).overlay(alignment: .bottomLeading) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(run != nil ? Color.accentColor : Color.secondary.opacity(0.7))
                            .frame(width: max(3, g.size.width * f))
                    }
                }
                .frame(height: thickness)
                .animation(.smooth, value: f)
            }
            .help(tip)
            .accessibilityElement(children: .combine)
            .accessibilityValue(tip)
        } else {
            content
        }
    }
}
