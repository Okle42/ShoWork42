#!/usr/bin/env python3
"""Print the Claude Code hooks block that wires Claude to ShoWork42.

   python3 adapters/claude/hooks.py /abs/path/to/showork  > settings-fragment.json

Only permission prompts / questions turn the glow red. The 60-second "waiting for your input"
idle notification is deliberately NOT mapped — it would turn a finished (green) window red.
"""
import json, sys

showork = sys.argv[1] if len(sys.argv) > 1 else "showork"
def cmd(event): return {"type": "command", "command": f"{json.dumps(showork)[1:-1]} emit {event} --agent claude", "timeout": 2}
# 視窗標題「英文名-正在做的任務」（10-19）：Claude Code 代寫 hook 回傳的 terminalSequence
def title(done=False): return {"type": "command", "command": f"{json.dumps(showork)[1:-1]} title" + (" --done" if done else ""), "timeout": 2}

hooks = {
    "UserPromptSubmit": [{"hooks": [cmd("working"), title()]}],
    # AskUserQuestion: red right when the question appears (the Notification is ~6 s late);
    # the catch-all excludes it so a parallel "working" can't race past "input".
    "PreToolUse":       [{"matcher": "AskUserQuestion", "hooks": [cmd("input")]},
                         {"matcher": "^(?!AskUserQuestion$)", "hooks": [cmd("working")]},
                         # 1 樓保全的 push 守門（10-22）：git push 之前檢查，該擋的回 deny
                         {"matcher": "Bash", "hooks": [{"type": "command", "command": f"{json.dumps(showork)[1:-1]} guard-push", "timeout": 60}]}],
    "PostToolUse":      [{"matcher": "*", "hooks": [cmd("working"), title()]}],
    "Stop":             [{"hooks": [cmd("done"), title(done=True)]}],
    "Notification":     [{"matcher": "permission_prompt|elicitation_dialog", "hooks": [cmd("input")]}],
    "SessionEnd":       [{"hooks": [cmd("clear")]}],
    # 權限允許搬到戰情中心（10-21）：hook 等你在收件匣按，終端機對話框照常出現（先按的算）
    "PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": f"{json.dumps(showork)[1:-1]} permit", "timeout": 3660}]}],
    # 戰情中心：告訴每個新 session 每輪用 `showork card` 自報
    "SessionStart":     [{"hooks": [{"type": "command", "command": f"{json.dumps(showork)[1:-1]} brief", "timeout": 2}]}],
}
print(json.dumps({"hooks": hooks}, indent=2, ensure_ascii=False))
