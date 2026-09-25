/// Fallback work signal for AI sessions that send no hook events (e.g. a Claude started before
/// ShoWork42 was installed): the terminal title Claude Code maintains.
/// Rules measured by the ghosts project (2026-08-17, sampled against the official registry):
///   • a ROTATING spinner frame first ⇒ busy  — ◐◑◒◓ (U+25D0–25D3, CC 2.1.232+), Braille U+2800–28FF (≤2.1.228)
///   • a STATIC ✳ / ✶ first            ⇒ idle (finished, last task title kept)
///   • anything else                    ⇒ not a Claude title — no opinion
public enum TitleSignal: Equatable, Sendable {
    case busy, idle, input, unknown

    public static func classify(_ title: String) -> TitleSignal {
        // "claude agents" view (conversation moved to the background, 09-26): the title carries counts,
        // e.g. "1 awaiting input · claude agents" / "2 working · claude agents"
        if title.contains("claude agents") {
            if title.range(of: #"\d+ awaiting input"#, options: .regularExpression) != nil { return .input }
            if title.range(of: #"\d+ working"#, options: .regularExpression) != nil { return .busy }
            return .idle
        }
        guard let first = title.drop(while: { $0.isWhitespace }).unicodeScalars.first else { return .unknown }
        let v = first.value
        if (0x25D0...0x25D3).contains(v) || (0x2801...0x28FF).contains(v) { return .busy }
        if v == 0x2733 || v == 0x2736 { return .idle }
        return .unknown
    }

    /// busy → idle is a finished turn; anything → busy is work. Other edges carry no event.
    public static func event(from old: TitleSignal, to new: TitleSignal) -> WorkEvent? {
        switch (old, new) {
        case (_, .input) where old != .input: return .input
        case (_, .busy) where old != .busy: return .working
        case (.busy, .idle), (.input, .idle): return .done
        default: return nil
        }
    }
}
