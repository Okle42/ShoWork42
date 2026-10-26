import Foundation
import Testing
@testable import ShoWorkCore

@Suite("NebulaPage")
struct NebulaPageTests {
    // 假名資料（10-22 規矩：測試不用真實專案／客戶名）
    let json = Data(#"""
    {"nodes":[{"id":"a","label":"小明Service","source_file":"src/a.swift","community":1},
              {"id":"b","label":"ACMEClient","source_file":"src/b.swift","community":1},
              {"id":"c","label":"Helper","community":2},
              {"id":"lonely","label":"孤星"}],
     "links":[{"source":"a","target":"b"},{"source":"b","target":"a"},{"source":"a","target":"c"},{"source":"c","target":"c"}]}
    """#.utf8)

    @Test("精簡：去孤點、去重複邊與自己連自己、依連線數排序、上限")
    func slim() throws {
        let d = try #require(NebulaPage.data(json: json))
        let g = try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
        let ns = try #require(g["nodes"] as? [[String: Any]]), ls = try #require(g["links"] as? [[String: String]])
        #expect(ns.map { $0["id"] as! String } == ["a", "b", "c"])
        #expect(ls.count == 2 && (ns[0]["deg"] as! Int) == 3 && (ns[0]["file"] as! String) == "src/a.swift")
        let one = try #require(NebulaPage.data(json: json, limit: 1))
        let g1 = try #require(try JSONSerialization.jsonObject(with: one) as? [String: Any])
        #expect((g1["nodes"] as! [Any]).count == 1 && (g1["links"] as! [Any]).isEmpty)
        #expect(NebulaPage.data(json: Data("not json".utf8)) == nil)
    }

    @Test("整棟合併：每個專案平分名額、id 加專案前綴、顏色＝專案")
    func merged() throws {
        let other = Data(#"{"nodes":[{"id":"a","label":"x"},{"id":"z","label":"y"}],"links":[{"source":"a","target":"z"}]}"#.utf8)
        let d = try #require(NebulaPage.merge([(name: "專案B", json: other), (name: "專案A", json: json)], limit: 4))
        let g = try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
        let ns = try #require(g["nodes"] as? [[String: Any]]), ls = try #require(g["links"] as? [[String: String]])
        #expect((g["projects"] as! [String]) == ["專案A", "專案B"])
        #expect(ns.map { $0["id"] as! String } == ["專案A\u{1F}a", "專案A\u{1F}b", "專案B\u{1F}a", "專案B\u{1F}z"])   // 專案A 取前 2 顆、同名 a 不撞
        #expect(ns.map { $0["c"] as! Int } == [0, 0, 1, 1] && (ns[3]["p"] as! String) == "專案B")
        #expect(ls.count == 2 && ls.allSatisfy { $0["source"]!.prefix(3) == $0["target"]!.prefix(3) })
        #expect(NebulaPage.merge([]) == nil)
    }

    @Test("套範本：標題跳脫、資料裡的 </ 不會結束 script")
    func page() {
        let h = NebulaPage.html(template: "<title>__TITLE__</title><script>__DATA__</script>", title: "專案<A>",
                                data: Data(#"{"x":"</script>"}"#.utf8))
        #expect(h == #"<title>專案&lt;A&gt;</title><script>{"x":"<\/script>"}</script>"#)
    }
}
