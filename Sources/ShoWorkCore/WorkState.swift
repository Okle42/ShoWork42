import Foundation

/// What a terminal tab's AI is doing, as far as the glow is concerned.
public enum WorkState: String, Codable, Sendable, CaseIterable {
    case idle      // no glow
    case working   // purple, breathing
    case done      // gold, steady — waits for the user to look
    case input     // red, pulsing — the AI is blocked on the user

    /// Higher wins when several tabs share one window (red > gold > purple > none).
    public var priority: Int {
        switch self {
        case .idle: 0
        case .working: 1
        case .done: 2
        case .input: 3
        }
    }

    /// States that stay lit until the user has actually seen them.
    public var needsAcknowledgement: Bool { self == .done || self == .input }
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
    /// - Parameter userIsLooking: the tab is selected AND its window is focused right now.
    ///   A turn that finishes while you're watching it needs no reminder.
    public static func next(_ current: WorkState, on event: WorkEvent, userIsLooking: Bool) -> WorkState {
        switch event {
        case .working: return .working
        case .done: return userIsLooking ? .idle : .done
        case .input: return .input          // red even while looking: the AI is blocked on you
        case .clear: return .idle
        }
    }

    /// The user looked at the tab (focus + selected, or a key/click inside it).
    public static func acknowledge(_ current: WorkState) -> WorkState {
        current == .done ? .idle : current  // red stays until the AI moves on (next event)
    }

    /// One window can host several tabs; it shows the most urgent one.
    public static func windowState<S: Sequence>(_ tabs: S) -> WorkState where S.Element == WorkState {
        tabs.max(by: { $0.priority < $1.priority }) ?? .idle
    }
}
