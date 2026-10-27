import Foundation
import Testing
@testable import ShoWorkCore

@Suite("名字下方的進度條（run/progress）")
struct RunProgressTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func p(_ s: String) -> RunProgress? { RunProgress.parse(Data(s.utf8)) }

    @Test("新格式：name＋done/total；舊格式：label 開頭的名字＋pct")
    func formats() throws {
        let a = try #require(p(#"{"name":"小明","label":"稽核（畫面）","done":12,"total":37,"updatedAt":1800000000,"pct":32,"eta":"4 分","updated":1800000000}"#))
        #expect(a.fraction == 12.0 / 37)
        #expect(a.caption(for: "小明") == "稽核（畫面） 12/37 還要 4 分")
        let b = try #require(p(#"{"label":"小華 稽核 10/37 畫面","pct":27,"eta":"","updated":1800000000}"#))
        #expect(b.belongs(to: "小華") && !b.belongs(to: "小明"))
        #expect(b.caption(for: "小華") == "稽核 10/37 畫面 27%")
        #expect(p(#"{"label":"x"}"#) == nil)            // 沒時間、沒進度不算
    }

    @Test("有 name 就只看 name；挑沒過期裡最新的一個")
    func pick() throws {
        let old = try #require(p(#"{"name":"小明","label":"舊","done":1,"total":2,"updatedAt":1799999000}"#))   // 1000 秒前：過期
        let x = try #require(p(#"{"name":"小明","label":"甲","done":1,"total":4,"updatedAt":1799999900}"#))
        let y = try #require(p(#"{"name":"小明","label":"乙","done":3,"total":4,"updatedAt":1799999950}"#))
        let z = try #require(p(#"{"name":"小華","label":"小明 冒名","pct":50,"updatedAt":1799999990}"#))
        #expect(RunProgress.pick([old, x, y, z], for: "小明", now: now)?.label == "乙")
        #expect(RunProgress.pick([old], for: "小明", now: now) == nil)
        #expect(RunProgress.pick([x], for: "", now: now) == nil)
    }
}
