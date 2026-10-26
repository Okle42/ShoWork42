import Testing
@testable import ShoWorkCore

@Suite("拖檔案進輸入框")
struct FileDropTests {
    @Test("路徑接在字後面；有空白或特殊字元用單引號包；中文不包")
    func paths() {
        #expect(Inbox.withPaths("", ["/tmp/a.png"]) == "/tmp/a.png ")
        #expect(Inbox.withPaths("看這張", ["/tmp/a.png"]) == "看這張 /tmp/a.png ")
        #expect(Inbox.withPaths("看這張 ", ["/tmp/a.png", "/tmp/b.png"]) == "看這張 /tmp/a.png /tmp/b.png ")
        #expect(Inbox.withPaths("", ["/Users/小明/桌面/報告.pdf"]) == "/Users/小明/桌面/報告.pdf ")
        #expect(Inbox.withPaths("", ["/Users/x/Screen Shot 1.png"]) == "'/Users/x/Screen Shot 1.png' ")
        #expect(Inbox.withPaths("", ["/tmp/it's (1).txt"]) == #"'/tmp/it'\''s (1).txt' "#)
        #expect(Inbox.withPaths("原本的字", []) == "原本的字")
    }
}
