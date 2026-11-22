import Foundation
import Testing
@testable import ShoWorkCore

// 11-22 自動停掉空轉的背景 session：只停「從沒接過工作」＋閒置 10 分鐘以上；做過事、/clear 過、比記帳早出生的都不動
@Suite("BgJanitor")
struct BgJanitorTests {
    let t0 = Date(timeIntervalSince1970: 1_795_300_000)
    func rec(_ pid: Int32 = 100, sid: String = "s1", kind: String = "bg", status: String = "idle", born: Date, idleFrom: Date? = nil, former: [String]? = nil) -> SessionRecord {
        var r = SessionRecord(pid: pid, sessionId: sid, cwd: "/tmp", status: status, kind: kind,
                              statusUpdatedAt: (idleFrom ?? born).timeIntervalSince1970 * 1000)
        r.startedAt = born.timeIntervalSince1970 * 1000
        r.formerNames = former.map { $0.map { SessionRecord.FormerName(name: "x", until: nil, sessionId: $0) } }
        return r
    }
    func run(_ recs: [SessionRecord], _ L: BgJanitor.Ledger, at: Date, work: Set<String> = [], cards: Set<String> = []) -> ([BgJanitor.Verdict], BgJanitor.Ledger) {
        let (v, l) = BgJanitor.review(recs, ledger: L, now: at, hasWork: { work.contains($0.sessionId) }, hasCard: { cards.contains($0) })
        return (v.map(\.1), l)
    }
    func isStop(_ v: BgJanitor.Verdict) -> Bool { if case .stop = v { return true }; return false }

    @Test func emptyIdleTenMinutesIsStopped() {
        var (_, L) = run([rec(born: t0)], .init(), at: t0.addingTimeInterval(30))          // 出生 30 秒就被看到
        var v: [BgJanitor.Verdict]
        (v, L) = run([rec(born: t0)], L, at: t0.addingTimeInterval(9 * 60))
        #expect(!isStop(v[0]))                                                           // 9 分鐘：還不停
        (v, L) = run([rec(born: t0)], L, at: t0.addingTimeInterval(11 * 60))
        #expect(isStop(v[0]))                                                            // 11 分鐘：停
    }
    @Test func workedThenIdleForHoursIsKept() {
        var (_, L) = run([rec(born: t0)], .init(), at: t0.addingTimeInterval(30), work: ["s1"])
        let (v, _) = run([rec(born: t0)], L, at: t0.addingTimeInterval(5 * 3600), work: ["s1"])
        #expect(!isStop(v[0]))
        _ = L
    }
    @Test func clearedSessionIsKept() {
        // 做過事 → /clear（session id 換新、新的對話紀錄是空的）→ 閒置很久：記帳本記得這個程序做過事
        var (_, L) = run([rec(sid: "old", born: t0)], .init(), at: t0.addingTimeInterval(30), work: ["old"])
        let (v, _) = run([rec(sid: "new", born: t0)], L, at: t0.addingTimeInterval(3 * 3600))
        #expect(!isStop(v[0]))
        _ = L
    }
    @Test func clearedSessionSeenOnlyAfterClearIsKeptByFormerNames() {
        // 戰情中心沒看過 /clear 前的樣子，但 formerNames 留著舊 session id
        let r = rec(sid: "new", born: t0, former: ["old"])
        var (_, L) = run([r], .init(), at: t0.addingTimeInterval(30))
        let (v, _) = run([r], L, at: t0.addingTimeInterval(3 * 3600))
        #expect(!isStop(v[0]))
        _ = L
    }
    @Test func bornBeforeWatchingIsKept() {
        let (v1, L) = run([rec(born: t0)], .init(), at: t0.addingTimeInterval(20 * 60))   // 第一次看到時它已經活了 20 分鐘
        let (v2, _) = run([rec(born: t0)], L, at: t0.addingTimeInterval(3 * 3600))
        #expect(!isStop(v1[0]) && !isStop(v2[0]))
    }
    @Test func interactiveAndBusyAndCardAreKept() {
        var (_, L) = run([rec(1, sid: "a", kind: "interactive", born: t0), rec(2, sid: "b", status: "busy", born: t0), rec(3, sid: "c", born: t0)], .init(), at: t0.addingTimeInterval(10))
        let (v, _) = run([rec(1, sid: "a", kind: "interactive", born: t0), rec(2, sid: "b", status: "busy", born: t0), rec(3, sid: "c", born: t0)], L,
                         at: t0.addingTimeInterval(2 * 3600), cards: ["c"])
        #expect(v.allSatisfy { !isStop($0) })
        _ = L
    }
    @Test func idleCountsFromLastStatusChange() {
        // 出生很久，但 3 分鐘前才剛變閒置（之前在忙卻沒寫對話紀錄的極端情況）⇒ 還不停
        var (_, L) = run([rec(born: t0)], .init(), at: t0.addingTimeInterval(10))
        let (v, _) = run([rec(born: t0, idleFrom: t0.addingTimeInterval(57 * 60))], L, at: t0.addingTimeInterval(60 * 60))
        #expect(!isStop(v[0]))
        _ = L
    }
    @Test func transcriptDetection() {
        #expect(!BgJanitor.transcriptHasWork(Data(#"{"type":"summary","summary":"x"}"#.utf8)))
        #expect(BgJanitor.transcriptHasWork(Data(#"{"type":"user","message":{"role":"user","content":"hi"}}"#.utf8)))
    }
}

// 11-22：終端機把對話停放到背景後，空殼不另外上看板（背景那個還活著時）
@Suite("ParkedHost")
struct ParkedHostTests {
    @Test func parkedHostIsHiddenWhileJobAlive() {
        var host = SessionRecord(pid: 1, sessionId: "host", cwd: "/tmp", status: "idle", kind: "interactive"); host.parkedJobId = "job1"
        var job = SessionRecord(pid: 2, sessionId: "job1-full", cwd: "/tmp", name: "Bella", status: "busy", kind: "bg"); job.jobId = "job1"
        let now = Date()
        func build(_ s: [SessionRecord]) -> [String] {
            Board.build(sessions: s, transcripts: [:], glows: [:], teams: [], inbox: [], now: now, home: "/Users/x", isRepo: { _ in false }).map(\.sessionId)
        }
        #expect(build([host, job]) == ["job1-full"])
        #expect(build([host]) == ["host"])            // 背景那個沒了：空殼照常顯示
    }
}

// 11-22：Claude 背景常駐程式的「預備程序」（bg、沒有 jobId、沒有對話）不上看板；真的背景工作（有 jobId）照常
@Suite("SpareHidden")
struct SpareHiddenTests {
    @Test func prewarmSpareIsHidden() {
        let spare = SessionRecord(pid: 3, sessionId: "spare", cwd: "/tmp", status: "idle", kind: "bg")
        var spare2 = SessionRecord(pid: 5, sessionId: "02da6c42-xxxx", cwd: "/tmp", status: "idle", kind: "bg"); spare2.jobId = "02da6c42"   // 帶 jobId 的預備程序
        var job = SessionRecord(pid: 4, sessionId: "job2", cwd: "/tmp", name: "Dora", status: "idle", kind: "bg"); job.jobId = "job2"
        let ids = Board.build(sessions: [spare, spare2, job], transcripts: [:], glows: [:], teams: [], inbox: [], now: Date(), home: "/Users/x", isRepo: { _ in false }).map(\.sessionId)
        #expect(ids == ["job2"])
    }
}

// 11-22 顯示名：職稱 > 專案 > 任務（家目錄不算專案）；英文名不上畫面
@Suite("DisplayName")
struct DisplayNameTests {
    @Test func labelAndTitle() {
        var n = Nickname(name: "Hana", doing: "全部測試")
        #expect(Nicknames.title(n, project: "Room42v2", fallback: "x") == "Room42v2 · 全部測試")
        #expect(Nicknames.title(n, project: "（家目錄）", fallback: "x") == "全部測試")
        n.role = "隊長"
        #expect(Nicknames.title(n, project: "Room42v2", fallback: "x") == "隊長 · 全部測試")
        #expect(Nicknames.label(n, project: "（家目錄）") == "隊長")
        #expect(Nicknames.title(nil, project: "Room42v2", fallback: "開場那句") == "Room42v2 · 開場那句")
    }
}

@Suite("InheritName")
struct InheritNameTests {
    func head(_ title: String) -> Data { Data(#"{"type":"custom-title","customTitle":"\#(title)"}"#.utf8) }
    @Test func onlyPoolNamesAreInherited() {
        #expect(Nicknames.inherited(head("Bella-點衛星開戰情卡")) == "Bella")
        #expect(Nicknames.inherited(head("Alex2-測試")) == "Alex2")
        #expect(Nicknames.inherited(head("clear-conversation")) == nil)        // Claude 自動標題不是英文名
    }
}

@Suite("DisplayName2")
struct DisplayName2Tests {
    @Test func worktreePrefixStripped() {
        #expect(Nicknames.label(nil, project: "_wt-ShoWork42-sphere") == "ShoWork42-sphere")
    }
}

@Suite("StripName")
struct StripNameTests {
    @Test func strip() {
        #expect(Nicknames.stripName("Dora") == nil)
        #expect(Nicknames.stripName("Bella-點衛星開戰情卡") == "點衛星開戰情卡")
        #expect(Nicknames.stripName("修 PDF 比例") == "修 PDF 比例")
        #expect(Nicknames.stripName("clear-conversation") == "clear-conversation")
    }
}
