#!/usr/bin/env python3
"""Print the Claude Code hooks block that wires Claude to ShoWork42.

   python3 adapters/claude/hooks.py /abs/path/to/showork  > settings-fragment.json

Only permission prompts / questions turn the glow red. The 60-second "waiting for your input"
idle notification is deliberately NOT mapped — it would turn a finished (gold) window red.
"""
import json, sys

showork = sys.argv[1] if len(sys.argv) > 1 else "showork"
def cmd(event): return {"type": "command", "command": f"{json.dumps(showork)[1:-1]} emit {event} --agent claude", "timeout": 2}

hooks = {
    "UserPromptSubmit": [{"hooks": [cmd("working")]}],
    "PreToolUse":       [{"matcher": "*", "hooks": [cmd("working")]}],
    "PostToolUse":      [{"matcher": "*", "hooks": [cmd("working")]}],
    "Stop":             [{"hooks": [cmd("done")]}],
    "Notification":     [{"matcher": "permission_prompt|elicitation_dialog", "hooks": [cmd("input")]}],
    "SessionEnd":       [{"hooks": [cmd("clear")]}],
}
print(json.dumps({"hooks": hooks}, indent=2, ensure_ascii=False))
