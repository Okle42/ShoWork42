import AppKit

// 編輯選單（10-25 Kang：「在戰情中心回答時沒法用語音輸入」）：agent 是 .accessory、從來沒設 mainMenu，
// 而 macOS 的「開始聽寫」（按兩下 Control）、⌘X／⌘C／⌘V／⌘A／⌘Z 都是掛在 App 的編輯選單上的快捷鍵——沒有選單就沒反應。
// 選單列不會出現（.accessory 沒有選單列），但快捷鍵照樣走 mainMenu；系統會自己在編輯選單尾端補「開始聽寫⋯」「表情與符號」。

@MainActor
enum EditMenu {
    static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "隱藏 ShoWork42", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編輯")
        edit.addItem(withTitle: "還原", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }

    /// 測試用：編輯選單現在有哪些項目（含系統補上的）
    static func dump() -> [String] {
        NSApplication.shared.mainMenu?.items.dropFirst().first?.submenu?.items.map { $0.isSeparatorItem ? "—" : "\($0.title) [\($0.action.map(NSStringFromSelector) ?? "-")]" } ?? []
    }
}
