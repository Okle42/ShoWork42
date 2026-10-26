import Foundation

/// What a terminal tab's AI is doing, as far as the glow is concerned.
public enum WorkState: String, Codable, Sendable, CaseIterable {
    case idle      // no glow
    case working   // purple, breathing
    case done      // green, steady — until the user types in that window
    case input     // red, pulsing — the AI is blocked on the user
    case waiting   // orange — turn ended but the AI is waiting on something external (Kang 10-20：等回信、等背景工作)

    /// Higher wins when several tabs share one window (red > orange > green > purple > none).
    public var priority: Int {
        switch self {
        case .idle: 0
        case .working: 1
        case .done: 2
        case .waiting: 3
        case .input: 4
        }
    }

    /// States that stay lit until the user has actually seen them.
    public var needsAcknowledgement: Bool { self == .done || self == .waiting || self == .input }
}

/// An event sent by an adapter (`showork emit …`).
public enum WorkEvent: String, Codable, Sendable, CaseIterable {
    case working   // prompt submitted / tool running
    case done      // turn finished
    case input     // permission prompt or question
    case clear     // session ended or user explicitly cleared
}

/// Pure state transitions, so they can be tested without any UI.
public enum StateMachine {
    /// - Parameter userIsLooking: kept for adapters/tests; the glow no longer auto-clears on focus alone
    ///   (09-26: a focused window is not proof you saw it — clear only on a key/click inside it).
    public static func next(_ current: WorkState, on event: WorkEvent, userIsLooking: Bool) -> WorkState {
        switch event {
        case .working: return .working
        case .done: return .done            // Kang: stays green until you type in that window, even if it's in front
        case .input: return .input          // red even while looking: the AI is blocked on you
        case .clear: return .idle
        }
    }

    /// The user did something in the tab. Looking or clicking clears nothing (09-26: a focused window is
    /// not proof you saw it). Kang 10-20: typing in it clears green — you've taken over, so "done, waiting
    /// for you" no longer means anything (10-09 had kept it lit until the reply was sent). Red stays until
    /// the AI moves on.
    public static func acknowledge(_ current: WorkState, typing: Bool = false) -> WorkState {
        typing && (current == .done || current == .waiting) ? .idle : current      // orange clears like green
    }

    /// Turn ended (`done`): if this turn's self-report (`showork card --status blocked`) says it's stuck on
    /// something external, glow orange instead of green. `turnStart` = when this turn began; older cards don't count.
    public static func settle(_ s: WorkState, report: SelfReport?, turnStart: Date?) -> WorkState {
        guard s == .done, let t = turnStart, let r = CardRules.fresh(report, t), r.status == .blocked else { return s }
        return .waiting
    }

    /// One window can host several tabs; it shows the most urgent one.
    public static func windowState<S: Sequence>(_ tabs: S) -> WorkState where S.Element == WorkState {
        tabs.max(by: { $0.priority < $1.priority }) ?? .idle
    }
}
