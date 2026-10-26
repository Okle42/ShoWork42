import Foundation
import Testing
@testable import ShoWorkCore

@Suite("GraphPrune")
struct GraphPruneTests {
    let now = Date(timeIntervalSince1970: 1_792_650_000)
    let mb: Int64 = 1024 * 1024

    @Test("不在大樓上超過 14 天的丟掉；在大樓上的再舊也留")
    func age() {
        let d = [GraphPrune.Dir(name: "專案A-1", bytes: 20 * mb, modified: now - 20 * 86400, active: false),
                 GraphPrune.Dir(name: "專案B-2", bytes: 20 * mb, modified: now - 20 * 86400, active: true),
                 GraphPrune.Dir(name: "專案C-3", bytes: 20 * mb, modified: now - 3 * 86400, active: false)]
        #expect(GraphPrune.pick(d, now: now) == ["專案A-1"])
    }

    @Test("超過上限：從最舊、不在大樓上的丟到不超過；都在大樓上就不動")
    func cap() {
        let d = [GraphPrune.Dir(name: "新", bytes: 200 * mb, modified: now - 86400, active: false),
                 GraphPrune.Dir(name: "舊", bytes: 200 * mb, modified: now - 2 * 86400, active: false),
                 GraphPrune.Dir(name: "用中", bytes: 200 * mb, modified: now - 9 * 86400, active: true)]
        #expect(GraphPrune.pick(d, now: now) == ["舊", "新"])
        #expect(GraphPrune.pick(d.map { var x = $0; x.active = true; return x }, now: now).isEmpty)
    }
}
