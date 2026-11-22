import AppKit
import SwiftUI
import ShoWorkCore

/// 對話輸入框（10-26 T1026031749）：SwiftUI 的 TextField 管不到游標，拖檔進來只會插一串路徑、游標留在原處。
/// 改用 NSTextView：
/// - 拖檔進來：路徑（含空白自動加引號、多個用空白隔開、後面補一個空白）插在游標處，游標停在路徑後、焦點留在框裡，直接接著打。
/// - Return 送出；Shift／Option＋Return 換行；選字中（注音、拼音還沒確定）的 Return 只是確定選字。
/// - 高度跟著內容長，到上限再捲動；resizable 時上緣有拖拉把手，拉的高度記在 UserDefaults。
/// 系統聽寫、拷貝貼上照 NSTextView 原本的行為。
struct ChatInput: View {
    @Binding var text: String
    var placeholder = ""
    var minLines = 1
    var maxLines = 4
    var resizable = false
    /// resizable 時能拉到多高（呼叫端給，例如窗格一半）
    var maxHeight: CGFloat = 400
    var onSubmit: () -> Void = {}

    static let heightKey = "ChatInputHeight"
    @AppStorage(ChatInput.heightKey) private var userHeight: Double = 0     // 0＝沒拉過
    @State private var contentHeight: CGFloat = 0
    @State private var dragStart: CGFloat?

    private var line: CGFloat { ceil(NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height) }
    private var inset: CGFloat { 10 }
    private func lines(_ n: Int) -> CGFloat { line * CGFloat(n) + inset }

    private var floor: CGFloat { resizable ? max(lines(max(minLines, 2)), CGFloat(userHeight)) : lines(minLines) }
    private var ceiling: CGFloat { resizable ? max(floor, maxHeight) : lines(maxLines) }
    private var height: CGFloat { min(max(contentHeight + inset, floor), ceiling) }

    var body: some View {
        VStack(spacing: 0) {
            if resizable { handle }
            ChatTextView(text: $text, placeholder: placeholder, onSubmit: onSubmit, contentHeight: $contentHeight)
                .frame(height: height)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        }
    }

    /// 上緣拖拉把手：往上拉變高。最小 2 行、最大 maxHeight；拉完記住
    private var handle: some View {
        Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 36, height: 4)
            .frame(maxWidth: .infinity).frame(height: 9)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let start = dragStart ?? height
                    if dragStart == nil { dragStart = start }
                    userHeight = Double(min(max(start - g.translation.height, lines(2)), maxHeight))
                }
                .onEnded { _ in dragStart = nil })
            .help("往上拉可以把輸入框拉高")
            .accessibilityLabel("調整輸入框高度")
    }
}

private struct ChatTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = DropTextView()
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .preferredFont(forTextStyle: .body)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.placeholder = placeholder
        tv.delegate = context.coordinator
        tv.string = text
        scroll.documentView = tv
        context.coordinator.tv = tv
        DispatchQueue.main.async { context.coordinator.measure() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.tv else { return }
        tv.placeholder = placeholder
        if tv.string != text, !tv.hasMarkedText() {
            // 外面改的（拖到對話區別處、送出後清空）：游標放到最後；變長了（拖進檔案）就把焦點拉回框裡
            let grew = text.count > tv.string.count
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
            if grew { tv.focus() }
            context.coordinator.measure()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextView
        weak var tv: DropTextView?
        init(_ p: ChatTextView) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv else { return }
            if parent.text != tv.string { parent.text = tv.string }
            tv.needsDisplay = true          // 佔位字
            measure()
        }

        func measure() {
            guard let tv, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height)
            let b = parent.$contentHeight
            if abs(h - b.wrappedValue) > 0.5 { DispatchQueue.main.async { b.wrappedValue = h } }   // 不在 SwiftUI 更新中途改 state
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.option) {
                    tv.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }
    }
}

/// 接得住檔案拖放的 NSTextView：路徑插在游標處、游標移到後面、焦點留著
final class DropTextView: NSTextView {
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }

    override func draw(_ r: NSRect) {
        super.draw(r)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let p = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: p, withAttributes: [.font: font ?? .preferredFont(forTextStyle: .body), .foregroundColor: NSColor.placeholderTextColor])
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        fileURLs(info).isEmpty ? super.draggingEntered(info) : .copy
    }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        fileURLs(info).isEmpty ? super.draggingUpdated(info) : .copy
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let urls = fileURLs(info)
        guard !urls.isEmpty else { return super.performDragOperation(info) }
        // 正在焦點裡：插在游標處；不在焦點：接在最後
        let at = window?.firstResponder === self ? selectedRange() : NSRange(location: (string as NSString).length, length: 0)
        insertPaths(urls.map(\.path), at: at)
        focus()
        return true
    }

    /// 拖檔共用：路徑插在 at，前面不是空白就補一個，後面補一個空白，游標放在空白後
    func insertPaths(_ paths: [String], at: NSRange) {
        let joined = Inbox.withPaths("", paths)          // 「'a b' c 」：加引號＋結尾空白
        guard !joined.isEmpty else { return }
        let ns = string as NSString
        let before = at.location > 0 ? ns.substring(with: NSRange(location: at.location - 1, length: 1)) : ""
        let ins = (before.isEmpty || before == " " || before == "\n" ? "" : " ") + joined
        if shouldChangeText(in: at, replacementString: ins) {
            replaceCharacters(in: at, with: ins)
            didChangeText()
        }
        setSelectedRange(NSRange(location: at.location + (ins as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// 焦點拉回來：App 叫到前面、視窗變主視窗、框成為第一回應者（從 Finder 拖檔時戰情中心不在前景）
    func focus() {
        guard let w = window else { return }
        if NSApp.activationPolicy() != .prohibited { NSApp.activate() }
        w.makeKey()
        w.makeFirstResponder(self)
    }
}
