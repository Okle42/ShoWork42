import Foundation
import Testing
@testable import ShoWorkCore

// 10-21 CPU 突波：對話紀錄改成增量解析、檔案戳記改 lstat。增量的結果必須跟整段一次解析完全一樣
@Suite("Incremental")
struct IncrementalTests {
    func use(_ id: String, _ name: String) -> String {
        #"{"type":"assistant","timestamp":"2026-10-21T01:00:00.000Z","cwd":"/Users/x/github-repos/A","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]}}"#
    }
    func result(_ id: String) -> String {
        #"{"type":"user","timestamp":"2026-10-21T01:00:01.000Z","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"ok"}]}}"#
    }
    let lines: [String] = [
        #"{"type":"user","timestamp":"2026-10-21T00:59:00.000Z","cwd":"/Users/x/github-repos/A","message":{"role":"user","content":"幫我改一下"}}"#,
        #"{"type":"queue-operation","operation":"enqueue","content":"等一下也看這個"}"#,
        #"{"type":"ai-title","aiTitle":"改一下"}"#,
    ]

    @Test("分好幾次餵＝一次解析（工具、排隊、標題、等你接話）")
    func feedEqualsParse() {
        let all = lines + [use("a", "Read"), result("a"), use("b", "Edit"),
                           #"{"type":"queue-operation","operation":"dequeue"}"#,
                           #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好了"}]}}"#]
        let whole = TranscriptInfo.parse(Data(all.joined(separator: "\n").utf8))
        for cut in 1..<all.count {
            var p = TranscriptInfo.Parser()
            p.feed(Data((all[..<cut].joined(separator: "\n") + "\n").utf8))
            p.feed(Data(all[cut...].joined(separator: "\n").utf8))
            #expect(p.info == whole, "cut at \(cut)")
        }
        #expect(whole.title == "改一下" && whole.queued.isEmpty && whole.pending.map(\.id) == ["b"] && !whole.awaitingReply)
    }

    @Test("lstat：大小、種類、mtime；不存在＝nil；符號連結不跟隨")
    func fileStat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.json").path
        try Data("hello".utf8).write(to: URL(fileURLWithPath: f))
        let st = try #require(FileStat.lstat(f))
        #expect(st.size == 5 && st.isRegular && !st.isDirectory)
        #expect(abs(st.date.timeIntervalSinceNow) < 60)
        #expect(FileStat.lstat(dir.path)?.isDirectory == true)
        #expect(FileStat.lstat(dir.path + "/nope") == nil)
        let link = dir.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir.path)
        #expect(FileStat.lstat(link)?.isSymlink == true && FileStat.lstat(link)?.isDirectory == false)
    }

    @Test("頂樓長椅前的站位不插進椅面（椅面 z 1.55 起，角色身體深 0.8）")
    func roofBench() {
        for i in 0..<3 { #expect(TowerLayout.roofSlot(i).z + 0.4 <= 1.55) }
    }
}
