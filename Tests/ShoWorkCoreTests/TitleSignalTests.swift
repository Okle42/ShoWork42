import Testing
@testable import ShoWorkCore

@Suite("TitleSignal")
struct TitleSignalTests {
    @Test("spinner frames are busy", arguments: ["◐ Fix bug", "◑ Long running task", "◒ x", "◓ y", "⠋ old braille", "  ◐ leading space"])
    func busy(t: String) { #expect(TitleSignal.classify(t) == .busy) }

    @Test("static sparkle is idle", arguments: ["✳ Apple-design skill", "✶ done"])
    func idle(t: String) { #expect(TitleSignal.classify(t) == .idle) }

    @Test("anything else is not a Claude title", arguments: ["", "/Users/someone", "zsh", "SW42-test", "⠀blank braille"])
    func unknown(t: String) { #expect(TitleSignal.classify(t) == .unknown) }

    @Test("claude agents view (background conversation)")
    func agentsView() {
        #expect(TitleSignal.classify("1 awaiting input · claude agents") == .input)
        #expect(TitleSignal.classify("2 working · claude agents") == .busy)
        #expect(TitleSignal.classify("claude agents") == .idle)
        #expect(TitleSignal.event(from: .idle, to: .input) == .input)
        #expect(TitleSignal.event(from: .unknown, to: .input) == .input)   // first sight of a waiting session: red right away
        #expect(TitleSignal.event(from: .input, to: .busy) == .working)
    }

    @Test("edges")
    func edges() {
        #expect(TitleSignal.event(from: .idle, to: .busy) == .working)
        #expect(TitleSignal.event(from: .unknown, to: .busy) == .working)
        #expect(TitleSignal.event(from: .busy, to: .idle) == .done)
        #expect(TitleSignal.event(from: .busy, to: .busy) == nil)
        #expect(TitleSignal.event(from: .idle, to: .idle) == nil)
        #expect(TitleSignal.event(from: .unknown, to: .idle) == nil)    // first sight of a finished session: no gold
        #expect(TitleSignal.event(from: .busy, to: .unknown) == nil)
    }
}
