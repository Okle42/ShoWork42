namespace ShoWork;

/// What an AI session is doing, as far as the glow is concerned. Same as the Mac ShoWorkCore/WorkState.swift.
public enum WorkState { Idle, Working, Done, Input }

public enum WorkEvent { Working, Done, Input, Clear }

/// Pure state transitions, so they can be tested without any UI.
public static class StateMachine
{
    /// Higher wins when several AI sessions share one window (red > green > purple > none).
    public static int Priority(WorkState s) => s switch { WorkState.Working => 1, WorkState.Done => 2, WorkState.Input => 3, _ => 0 };

    public static WorkState Next(WorkState current, WorkEvent e) => e switch
    {
        WorkEvent.Working => WorkState.Working,
        WorkEvent.Done => WorkState.Done,       // stays green until a key/click in that window, even if it's in front
        WorkEvent.Input => WorkState.Input,     // red even while looking: the AI is blocked on you
        _ => WorkState.Idle,
    };

    /// A key/click inside the window: green is seen and goes away; red stays until the AI moves on.
    public static WorkState Acknowledge(WorkState s) => s == WorkState.Done ? WorkState.Idle : s;

    /// One window can host several sessions (tabs); it shows the most urgent one.
    public static WorkState WindowState(IEnumerable<WorkState> tabs) =>
        tabs.Aggregate(WorkState.Idle, (a, b) => Priority(b) > Priority(a) ? b : a);

    public static WorkEvent? ParseEvent(string s) => s switch
    {
        "working" => WorkEvent.Working, "done" => WorkEvent.Done, "input" => WorkEvent.Input, "clear" => WorkEvent.Clear, _ => null,
    };
}
