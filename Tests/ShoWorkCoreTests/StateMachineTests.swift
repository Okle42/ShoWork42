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

    @Test("acknowledging clears green only")
    func acknowledge() {
        #expect(StateMachine.acknowledge(.done) == .idle)
        #expect(StateMachine.acknowledge(.input) == .input)
        #expect(StateMachine.acknowledge(.working) == .working)
        #expect(StateMachine.acknowledge(.idle) == .idle)
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
