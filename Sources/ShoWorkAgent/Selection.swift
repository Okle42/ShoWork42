import AppKit

/// "Is this tab the one the user is looking at right now?" — tab selected in its window,
/// window is the focused window of the frontmost app.
@MainActor
enum Selection {
    static func isLooking(at p: Placement) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == p.pid,
              focusedWID(pid: p.pid) == p.wid else { return false }
        return isSelected(p)
    }

    static func focusedWID(pid: pid_t) -> CGWindowID? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &v) == .success,
              let w = v else { return nil }
        return AXQuery.wid(w as! AXUIElement)
    }

    static func isSelected(_ p: Placement) -> Bool {
        switch p.app {
        case .terminal:
            return Script.string("tell application id \"com.apple.Terminal\" to get tty of selected tab of (first window whose id is \(p.wid))") == p.tabTTY
        case .iterm:
            return Script.string("tell application id \"com.googlecode.iterm2\" to get tty of current session of (first window whose id is \(p.wid))") == p.tabTTY
        case .ghostty:
            guard let tid = p.ghosttyTerminalID else { return true }   // unknown ⇒ treat window focus as enough
            return Script.string("""
                tell application id "com.mitchellh.ghostty"
                  repeat with w in windows
                    if (id of terminals of w) contains "\(tid)" then return id of focused terminal of selected tab of w
                  end repeat
                end tell
                """) == tid
        }
    }
}
