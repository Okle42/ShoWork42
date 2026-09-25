#!/usr/bin/env python3
"""ShoWork42 installer / uninstaller.

  showork_install.py install   [--settings PATH] [--no-agent]
  showork_install.py uninstall [--settings PATH] [--no-agent]
  showork_install.py status    [--settings PATH]

Safety rules (M1 plan §6):
  • back up settings.json before every write (Application Support/ShoWork42/backup/)
  • merge only: append our hook groups; never touch, reorder or rewrite anyone else's
  • idempotent: installing twice changes nothing
  • uninstall removes exactly the groups whose command runs OUR showork binary
  • write atomically and re-parse before replacing the file
"""
import json, os, shutil, subprocess, sys, tempfile, time

HOME = os.path.expanduser("~")
SUPPORT = os.path.join(HOME, "Library/Application Support/ShoWork42")
BIN = os.path.join(SUPPORT, "bin")
SHOWORK = os.path.join(BIN, "showork")
AGENT = os.path.join(BIN, "ShoWorkAgent")
LABEL = "ai.okle42.showork.agent"
PLIST = os.path.join(HOME, "Library/LaunchAgents", LABEL + ".plist")
MARK = "/ShoWork42/bin/showork"          # how we recognise our own hook commands
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def our_hooks():
    def cmd(ev): return {"type": "command", "command": f'"{SHOWORK}" emit {ev} --agent claude', "timeout": 2}
    return {
        "UserPromptSubmit": [{"hooks": [cmd("working")]}],
        "PreToolUse":       [{"matcher": "*", "hooks": [cmd("working")]}],
        "PostToolUse":      [{"matcher": "*", "hooks": [cmd("working")]}],
        "Stop":             [{"hooks": [cmd("done")]}],
        # permission prompts / questions only — the 60 s idle reminder would turn gold into red
        "Notification":     [{"matcher": "permission_prompt|elicitation_dialog", "hooks": [cmd("input")]}],
        "SessionEnd":       [{"hooks": [cmd("clear")]}],
    }

def is_ours(group):
    return any(MARK in (h.get("command") or "") for h in group.get("hooks", []))

def load(path):
    if not os.path.exists(path): return {}
    with open(path) as f: return json.load(f)

def save(path, data):
    os.makedirs(os.path.join(SUPPORT, "backup"), exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, os.path.join(SUPPORT, "backup", f"settings.{time.strftime('%Y%m%d-%H%M%S')}.json"))
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings.", suffix=".json")
    with os.fdopen(fd, "w") as f: json.dump(data, f, indent=2, ensure_ascii=False); f.write("\n")
    with open(tmp) as f: json.load(f)                       # re-parse before replacing
    if os.path.exists(path): shutil.copymode(path, tmp)
    os.replace(tmp, path)

def merge(data):
    hooks = data.setdefault("hooks", {})
    changed = False
    for ev, groups in our_hooks().items():
        lst = hooks.setdefault(ev, [])
        if not any(is_ours(g) for g in lst):
            lst.extend(groups); changed = True
    return changed

def unmerge(data):
    hooks = data.get("hooks") or {}
    changed = False
    for ev in list(hooks):
        keep = [g for g in hooks[ev] if not is_ours(g)]
        if len(keep) != len(hooks[ev]):
            changed = True
            if keep: hooks[ev] = keep
            else: del hooks[ev]                               # we created this list; leave no trace
    if changed and "hooks" in data and not data["hooks"]: del data["hooks"]
    return changed

def install_agent():
    subprocess.run(["swift", "build", "-c", "release"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    os.makedirs(BIN, exist_ok=True)
    for name in ("showork", "ShoWorkAgent"):
        src = os.path.join(ROOT, ".build/release", name)
        tmp = os.path.join(BIN, "." + name + ".new")
        shutil.copy2(src, tmp); os.replace(tmp, os.path.join(BIN, name))   # atomic swap, never a half-copied binary
    os.makedirs(os.path.dirname(PLIST), exist_ok=True)
    plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key><array><string>{AGENT}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>{SUPPORT}/agent.log</string>
</dict></plist>
"""
    with open(PLIST, "w") as f: f.write(plist)
    uid = str(os.getuid())
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], stderr=subprocess.DEVNULL)
    subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", PLIST], check=True)

def uninstall_agent():
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], stderr=subprocess.DEVNULL)
    for p in (PLIST, SHOWORK, AGENT, os.path.join(SUPPORT, "agent.sock")):
        if os.path.exists(p): os.remove(p)

def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("install", "uninstall", "status"): print(__doc__); sys.exit(2)
    settings = os.path.join(HOME, ".claude/settings.json")
    if "--settings" in args: settings = args[args.index("--settings") + 1]
    agent = "--no-agent" not in args
    data = load(settings)
    if args[0] == "install":
        if agent: install_agent()
        print("settings:", "merged" if merge(data) and (save(settings, data) or True) else "already installed")
    elif args[0] == "uninstall":
        print("settings:", "removed" if unmerge(data) and (save(settings, data) or True) else "nothing to remove")
        if agent: uninstall_agent()
    else:
        n = sum(is_ours(g) for gs in (data.get("hooks") or {}).values() for g in gs)
        running = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], capture_output=True).returncode == 0
        print(f"hooks installed: {n}/6   agent loaded: {running}   binaries: {os.path.exists(AGENT)}")

if __name__ == "__main__":
    main()
