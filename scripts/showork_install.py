#!/usr/bin/env python3
"""ShoWork42 installer / uninstaller.

  showork_install.py install   [--settings PATH] [--no-agent] [--force]
  showork_install.py uninstall [--settings PATH] [--no-agent]
  showork_install.py status    [--settings PATH]

Safety rules (M1 plan §6):
  • back up settings.json before every write (Application Support/ShoWork42/backup/)
  • merge only: append our hook groups; never touch, reorder or rewrite anyone else's
  • idempotent: installing twice changes nothing
  • uninstall removes exactly the groups whose command runs OUR showork binary
  • write atomically and re-parse before replacing the file

安裝版本守門（10-25 隊長 Penny：同 repo 多個 session 各自從 worktree 安裝，舊的蓋掉新的）：
  • 每次安裝把 commit 號記在 board/installed.json（commit、有沒有未提交改動、從哪個資料夾、時間）
  • 要安裝的 HEAD 必須包含「已安裝的 commit」和「本機 main」——比已安裝的舊、或少了 main 上別人已經 commit 的東西就拒絕
  • 確定要（例如故意退版）帶 --force
"""
import json, os, shutil, subprocess, sys, tempfile, time

HOME = os.path.expanduser("~")
SUPPORT = os.path.join(HOME, "Library/Application Support/ShoWork42")
BIN = os.path.join(SUPPORT, "bin")
SHOWORK = os.path.join(BIN, "showork")
# 10-25：agent 改成 .app 包（系統聽寫要 App 身分；Support/ShoWorkAgent-Info.plist）。bin/ShoWorkAgent 留成指到包裡的符號連結，舊呼叫照樣能用
AGENT_APP = os.path.join(SUPPORT, "ShoWorkAgent.app")
AGENT = os.path.join(AGENT_APP, "Contents/MacOS/ShoWorkAgent")
AGENT_LINK = os.path.join(BIN, "ShoWorkAgent")
AGENT_ID = "ai.okle42.showork.agent"     # 固定不換：輔助使用等授權綁這個身分
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LABEL = "ai.okle42.showork.agent"
PLIST = os.path.join(HOME, "Library/LaunchAgents", LABEL + ".plist")
APP = "/Applications/ShoWork42.app"     # 點了就打開戰情中心（Spotlight、Launchpad、Dock 都找得到）
MARK = "/ShoWork42/bin/showork"          # how we recognise our own hook commands
ASK_TOOL = "AskUserQuestion"             # Claude's built-in "ask the user" tool
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

INSTALLED = os.path.join(SUPPORT, "board/installed.json")

def git(args, cwd=ROOT):
    r = subprocess.run(["git", "-C", cwd] + args, capture_output=True, text=True)
    return r.returncode, r.stdout.strip()

def is_ancestor(a, b, cwd=ROOT):
    """a 是 b 的祖先（或同一個）"""
    return git(["merge-base", "--is-ancestor", a, b], cwd)[0] == 0

def install_check(head, installed, main, ancestor):
    """要不要擋這次安裝：回傳擋的原因（list，空的＝可以裝）。純函式，ancestor(a, b) 由呼叫端給（測試用假的）"""
    why = []
    if not head:
        return ["看不出要安裝的 commit（不是 git 資料夾？）"]
    if installed and installed != head and not ancestor(installed, head):
        why.append(f"已安裝的是 {installed[:7]}，這次的 {head[:7]} 不包含它（比較舊或在別的分支），裝了會把別人的改動蓋掉")
    if main and main != head and not ancestor(main, head):
        why.append(f"本機 main 在 {main[:7]}，這次的 {head[:7]} 不包含它；先 rebase／merge 到 main 最新再裝")
    return why

def guard_install(force):
    """安裝前檢查；擋下就印原因並結束（exit 3）。回傳這次的紀錄（裝完再寫）"""
    _, head = git(["rev-parse", "HEAD"])
    _, main = git(["rev-parse", "--verify", "--quiet", "refs/heads/main"])
    dirty = bool(git(["status", "--porcelain", "--untracked-files=no"])[1])
    prev = {}
    try:
        with open(INSTALLED) as f: prev = json.load(f)
    except (OSError, ValueError):
        pass
    why = install_check(head, prev.get("commit"), main, is_ancestor)
    if why and not force:
        print("拒絕安裝：")
        for w in why: print("  •", w)
        print("確定要（例如故意退版）請加 --force")
        sys.exit(3)
    for w in why: print("（--force）照裝，但注意：", w)
    print(f"安裝 commit {head[:7]}" + ("（含未提交的改動）" if dirty else "") + f"，來源 {ROOT}")
    return {"commit": head, "dirty": dirty, "root": ROOT, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "forced": bool(why)}

def record_install(rec):
    os.makedirs(os.path.dirname(INSTALLED), exist_ok=True)
    tmp = INSTALLED + ".tmp"
    with open(tmp, "w") as f: json.dump(rec, f, ensure_ascii=False, indent=1)
    os.replace(tmp, INSTALLED)

def our_hooks():
    def cmd(ev): return {"type": "command", "command": f'"{SHOWORK}" emit {ev} --agent claude', "timeout": 2}
    # 視窗標題「英文名-正在做的任務」（10-19 Kang）：hook 回傳 terminalSequence，Claude Code 代寫 OSC 0
    def title(done=False): return {"type": "command", "command": f'"{SHOWORK}" title' + (" --done" if done else ""), "timeout": 2}
    return {
        "UserPromptSubmit": [{"hooks": [cmd("working"), title()]}],
        # AskUserQuestion puts its question on screen at PreToolUse; Claude's elicitation Notification only
        # comes ~6 s later (agent.log 09-28), so red is sent here. The catch-all excludes it: hooks of one
        # event run in parallel, and a racing "working" could land after "input".
        "PreToolUse":       [{"matcher": ASK_TOOL, "hooks": [cmd("input")]},
                             {"matcher": f"^(?!{ASK_TOOL}$)", "hooks": [cmd("working")]},
                             # 1 樓保全的 push 守門（10-22）：git push 之前檢查，該擋的回 deny；不是 push 的指令馬上放行
                             {"matcher": "Bash", "hooks": [{"type": "command", "command": f'"{SHOWORK}" guard-push', "timeout": 60}]}],
        "PostToolUse":      [{"matcher": "*", "hooks": [cmd("working"), title()]}],
        "Stop":             [{"hooks": [cmd("done"), title(done=True)]}],
        # permission prompts / questions only — the 60 s idle reminder would turn green into red
        "Notification":     [{"matcher": "permission_prompt|elicitation_dialog", "hooks": [cmd("input")]}],
        "SessionEnd":       [{"hooks": [cmd("clear")]}],
        # 權限允許搬到戰情中心（10-21）：hook 等你在收件匣按，終端機對話框照常出現（兩邊先按的算）；最多等一小時
        "PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": f'"{SHOWORK}" permit', "timeout": 3660}]}],
        # 戰情中心：每個新 session（含 /clear、壓縮後）告訴 AI 每輪用 `showork card` 自報
        "SessionStart":     [{"hooks": [{"type": "command", "command": f'"{SHOWORK}" brief', "timeout": 2}]}],
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
    """Add our groups; if an older ShoWork42 left different ones, replace only ours (others untouched)."""
    hooks = data.setdefault("hooks", {})
    changed = False
    for ev, groups in our_hooks().items():
        lst = hooks.setdefault(ev, [])
        if [g for g in lst if is_ours(g)] == groups: continue
        lst[:] = [g for g in lst if not is_ours(g)] + groups
        changed = True
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

def signing_identity():
    """First "Apple Development"/"Developer ID Application" identity, else ad-hoc ("-")."""
    out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
    for key in ("Developer ID Application", "Apple Development"):
        for line in out.splitlines():
            if key in line: return line.split()[1]
    return "-"

def install_agent():
    subprocess.run(["swift", "build", "-c", "release"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    os.makedirs(BIN, exist_ok=True)
    ident = signing_identity()
    src = os.path.join(ROOT, ".build/release/showork")
    tmp = os.path.join(BIN, ".showork.new")
    shutil.copy2(src, tmp)
    # sign with a real identity + fixed identifier: macOS keys Accessibility on the signature's
    # designated requirement, so rebuilt binaries keep the permission (ad-hoc would lose it)
    subprocess.run(["codesign", "-f", "-s", ident, "--identifier", "ai.okle42.showork.showork", tmp],
                   check=True, stderr=subprocess.DEVNULL)
    os.replace(tmp, SHOWORK)                                    # atomic swap, never a half-copied binary
    install_agent_app(ident)
    # 3D 知識星雲頁的範本＋繪圖函式庫（10-22：打包在本機，不走 CDN）
    neb = os.path.join(SUPPORT, "nebula"); os.makedirs(neb, exist_ok=True)
    for f in ("nebula-vendor.js", "graph3d-template.html"):
        shutil.copy2(os.path.join(ROOT, "assets/nebula", f), os.path.join(neb, f))
    install_app(ident)
    os.makedirs(os.path.dirname(PLIST), exist_ok=True)
    plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key><array><string>{AGENT}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>{"" if not os.environ.get("SHOWORK_DEBUG") else chr(10) + "  <key>EnvironmentVariables</key><dict><key>SHOWORK_DEBUG</key><string>1</string></dict>"}
  <key>StandardErrorPath</key><string>{SUPPORT}/agent.log</string>
</dict></plist>
"""
    with open(PLIST, "w") as f: f.write(plist)
    uid = str(os.getuid())
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], stderr=subprocess.DEVNULL)
    # bootout is asynchronous; bootstrapping before it finishes fails with EIO (5)
    for _ in range(50):
        if subprocess.run(["launchctl", "print", f"gui/{uid}/{LABEL}"], capture_output=True).returncode != 0: break
        time.sleep(0.1)
    for attempt in range(5):
        r = subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", PLIST], capture_output=True, text=True)
        if r.returncode == 0: break
        time.sleep(0.5 * (attempt + 1))
    else:
        raise SystemExit(f"launchctl bootstrap failed: {r.stderr.strip()}")

def install_agent_app(ident):
    """Application Support/ShoWork42/ShoWorkAgent.app：常駐 agent 本體（10-25 起是 .app 包，系統聽寫才認得它）"""
    tmp = AGENT_APP + ".new"
    if os.path.exists(tmp): shutil.rmtree(tmp)
    os.makedirs(os.path.join(tmp, "Contents/MacOS")); os.makedirs(os.path.join(tmp, "Contents/Resources"))
    shutil.copy2(os.path.join(ROOT, ".build/release/ShoWorkAgent"), os.path.join(tmp, "Contents/MacOS/ShoWorkAgent"))
    shutil.copy2(os.path.join(ROOT, "Support/ShoWorkAgent-Info.plist"), os.path.join(tmp, "Contents/Info.plist"))
    shutil.copy2(os.path.join(ROOT, "assets/ShoWork42.icns"), os.path.join(tmp, "Contents/Resources/AppIcon.icns"))
    subprocess.run(["codesign", "-f", "-s", ident, "--identifier", AGENT_ID, tmp], check=True, stderr=subprocess.DEVNULL)
    old = None
    if os.path.exists(AGENT_APP):
        old = AGENT_APP + ".old"
        if os.path.exists(old): shutil.rmtree(old)
        os.replace(AGENT_APP, old)                              # 跑著的 agent 已經把執行檔載進記憶體，搬走不影響它
    os.replace(tmp, AGENT_APP)
    if old: shutil.rmtree(old)
    # bin/ShoWorkAgent：舊版是執行檔本身，改成指到包裡的符號連結（舊的那份先搬到 backup/）
    if os.path.lexists(AGENT_LINK) and not os.path.islink(AGENT_LINK):
        os.makedirs(os.path.join(SUPPORT, "backup"), exist_ok=True)
        os.replace(AGENT_LINK, os.path.join(SUPPORT, "backup", f"ShoWorkAgent.bare-{time.strftime('%Y%m%d-%H%M%S')}"))
    if os.path.islink(AGENT_LINK): os.remove(AGENT_LINK)
    os.symlink(AGENT, AGENT_LINK)
    subprocess.run([LSREGISTER, "-f", AGENT_APP], stderr=subprocess.DEVNULL)

def install_app(ident):
    """/Applications/ShoWork42.app：一個小啟動器，點下去叫常駐的 agent 打開戰情中心（沒在跑就先啟動）。"""
    tmp = APP + ".new"
    if os.path.exists(tmp): shutil.rmtree(tmp)
    os.makedirs(os.path.join(tmp, "Contents/MacOS")); os.makedirs(os.path.join(tmp, "Contents/Resources"))
    shutil.copy2(os.path.join(ROOT, ".build/release/ShoWorkLauncher"), os.path.join(tmp, "Contents/MacOS/ShoWork42"))
    shutil.copy2(os.path.join(ROOT, "assets/ShoWork42.icns"), os.path.join(tmp, "Contents/Resources/AppIcon.icns"))
    with open(os.path.join(tmp, "Contents/Info.plist"), "w") as f: f.write("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ai.okle42.showork.app</string>
  <key>CFBundleName</key><string>ShoWork42</string>
  <key>CFBundleDisplayName</key><string>ShoWork42</string>
  <key>CFBundleExecutable</key><string>ShoWork42</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Okle42</string>
</dict></plist>
""")
    subprocess.run(["codesign", "-f", "-s", ident, "--identifier", "ai.okle42.showork.app", tmp], check=True, stderr=subprocess.DEVNULL)
    if os.path.exists(APP): shutil.rmtree(APP)
    os.replace(tmp, APP)
    subprocess.run([LSREGISTER, "-f", APP], stderr=subprocess.DEVNULL)

def uninstall_agent():
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], stderr=subprocess.DEVNULL)
    for p in (PLIST, SHOWORK, AGENT_LINK, os.path.join(SUPPORT, "agent.sock")):
        if os.path.lexists(p): os.remove(p)
    for d in (APP, AGENT_APP):
        if os.path.exists(d): shutil.rmtree(d)

def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("install", "uninstall", "status"): print(__doc__); sys.exit(2)
    settings = os.path.join(HOME, ".claude/settings.json")
    if "--settings" in args: settings = args[args.index("--settings") + 1]
    agent = "--no-agent" not in args
    data = load(settings)
    if args[0] == "install":
        if agent:
            rec = guard_install("--force" in args)
            install_agent()
            record_install(rec)
        print("settings:", "merged" if merge(data) and (save(settings, data) or True) else "already installed")
    elif args[0] == "uninstall":
        print("settings:", "removed" if unmerge(data) and (save(settings, data) or True) else "nothing to remove")
        if agent: uninstall_agent()
    else:
        n = sum(is_ours(g) for gs in (data.get("hooks") or {}).values() for g in gs)
        running = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], capture_output=True).returncode == 0
        print(f"hooks installed: {n}/{sum(map(len, our_hooks().values()))}  agent loaded: {running}   binaries: {os.path.exists(AGENT)}")

if __name__ == "__main__":
    main()
