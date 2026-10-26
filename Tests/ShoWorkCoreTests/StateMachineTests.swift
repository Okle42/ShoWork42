import Testing
@testable import ShoWorkCore

@Suite("StateMachine")
struct StateMachineTests {
    @Test("every event from every state, not looking", arguments: WorkState.allCases)
    func transitionsNotLooking(from s: WorkState) {
        #expect(StateMachine.next(s, on: .working, userIsLooking: false) == .working)
        #expect(StateMachine.next(s, on: .done, userIsLooking: false) == .done)
        #expect(StateMachine.next(s, on: .input, userIsLooking: false) == .input)
        #expect(StateMachine.next(s, on: .clear, userIsLooking: false) == .idle)
    }

    @Test("done stays green even if the window is in front (cleared only by a key/click)", arguments: WorkState.allCases)
    func doneWhileLooking(from s: WorkState) {
        #expect(StateMachine.next(s, on: .done, userIsLooking: true) == .done)
    }

    @Test("red stays red even while looking — the AI is blocked on you")
    func inputWhileLooking() {
        #expect(StateMachine.next(.working, on: .input, userIsLooking: true) == .input)
    }

    @Test("looking/typing clears nothing — green waits for the next prompt")
    func acknowledge() {
        #expect(StateMachine.acknowledge(.done) == .done)
        #expect(StateMachine.acknowledge(.input) == .input)
        #expect(StateMachine.acknowledge(.working) == .working)
        #expect(StateMachine.acknowledge(.idle) == .idle)
        // 10-20: typing in the window clears green only
        #expect(StateMachine.acknowledge(.done, typing: true) == .idle)
        #expect(StateMachine.acknowledge(.input, typing: true) == .input)
        #expect(StateMachine.acknowledge(.working, typing: true) == .working)
    }

    @Test("orange: a fresh blocked self-report turns Stop into waiting")
    func settleWaiting() {
        let turn = Date(timeIntervalSince1970: 1_000)
        let blocked = SelfReport(status: .blocked, at: turn.addingTimeInterval(30))
        #expect(StateMachine.settle(.done, report: blocked, turnStart: turn) == .waiting)
        // not blocked → stays green
        for st in [SelfReport.Status.done, .review, .working] {
            #expect(StateMachine.settle(.done, report: SelfReport(status: st, at: turn.addingTimeInterval(30)), turnStart: turn) == .done)
        }
        #expect(StateMachine.settle(.done, report: nil, turnStart: turn) == .done)
        // stale card (written before this turn) or unknown turn start → green
        #expect(StateMachine.settle(.done, report: SelfReport(status: .blocked, at: turn.addingTimeInterval(-1)), turnStart: turn) == .done)
        #expect(StateMachine.settle(.done, report: blocked, turnStart: nil) == .done)
        // only the turn-end event is settled
        #expect(StateMachine.settle(.working, report: blocked, turnStart: turn) == .working)
        #expect(StateMachine.settle(.input, report: blocked, turnStart: turn) == .input)
    }

    @Test("typing clears orange like green; looking doesn't")
    func acknowledgeWaiting() {
        #expect(StateMachine.acknowledge(.waiting) == .waiting)
        #expect(StateMachine.acknowledge(.waiting, typing: true) == .idle)
        #expect(WorkState.waiting.needsAcknowledgement)
    }

    @Test("window priority: red > orange > green > purple > none")
    func windowPriorityWaiting() {
        #expect(StateMachine.windowState([.done, .waiting]) == .waiting)
        #expect(StateMachine.windowState([.waiting, .working, .idle]) == .waiting)
        #expect(StateMachine.windowState([.waiting, .input, .done]) == .input)
        #expect(Board.column(status: nil, glow: .waiting, lastActivity: nil, now: Date()).0 == .stuck)
    }

    @Test("window shows the most urgent tab: red > green > purple > none")
    func windowPriority() {
        #expect(StateMachine.windowState([.working, .done]) == .done)
        #expect(StateMachine.windowState([.done, .input, .working]) == .input)
        #expect(StateMachine.windowState([.idle, .working]) == .working)
        #expect(StateMachine.windowState([WorkState]()) == .idle)
        #expect(StateMachine.windowState([.idle, .idle]) == .idle)
    }
}

@Suite("Wire")
struct WireTests {
    @Test("round trip")
    func roundTrip() throws {
        let m = WireMessage(event: .done, tty: "/dev/ttys009", agent: "claude", pid: 42)
        var line = try m.encodedLine()
        #expect(line.last == 0x0A)
        line.removeLast()
        #expect(WireMessage.decode(line: line) == m)
    }

    @Test("rejects non-tty paths and unknown versions")
    func rejects() {
        #expect(WireMessage.decode(line: Data(#"{"v":1,"event":"done","tty":"/etc/passwd","agent":"x","pid":1}"#.utf8)) == nil)
        #expect(WireMessage.decode(line: Data(#"{"v":2,"event":"done","tty":"/dev/ttys001","agent":"x","pid":1}"#.utf8)) == nil)
        #expect(WireMessage.decode(line: Data(#"{"v":1,"event":"explode","tty":"/dev/ttys001","agent":"x","pid":1}"#.utf8)) == nil)
        #expect(WireMessage.decode(line: Data("garbage".utf8)) == nil)
    }
}

import Foundation
@Suite("TTYFinder")
struct TTYFinderTests {
    @Test("finds a tty by walking up from this process when run in a terminal, never crashes otherwise")
    func walks() {
        let r = TTYFinder.find(startingAt: getpid())
        if let r { #expect(r.tty.hasPrefix("/dev/tty")) }
        #expect(TTYFinder.find(startingAt: 999_999) == nil)
    }
}
