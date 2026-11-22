#!/usr/bin/env python3
"""ShoWork42 流量架構自檢（11-22 Keng：我們建好、push，學弟那邊拉下來就有一套一樣的檢測，兩台互當對照組）

檢查兩種「流量」：
  1. Claude 額度：這台開了哪些 session（互動／背景／預備程序／停放空殼）、誰的記憶量（context）大、
     今天的 token 花在哪個專案／主 session 還是子 agent、快取命中率、每開一個 session 的開場成本、
     常駐設定（CLAUDE.md、記憶索引、MCP、hooks）有多重 ⇒ 給省額度的建議
  2. 網路流量：取樣 N 秒，各程式的進出量、網卡總量、每個程式開了幾條連線

用法：
  python3 scripts/flow_audit.py                 # 跑一次，印報告，存 JSON 到 ~/.claude/flow-audit/
  python3 scripts/flow_audit.py --label 學弟    # 報告／檔名標上這台是誰
  python3 scripts/flow_audit.py --net 20        # 網路取樣 20 秒（預設 10；0＝不量網路）
  python3 scripts/flow_audit.py --names         # JSON 裡保留專案名（預設只留代號，方便傳給別人比對）
  python3 scripts/flow_audit.py --compare A.json B.json   # 兩台並排比對
  python3 scripts/flow_audit.py --send          # 跑完把「去隱私版」報告＋優化建議送到 Okle42 Discord 的自檢回報頻道
  python3 scripts/flow_audit.py --set-webhook <網址>       # 第一次設定回報網址（存在本機 ~/.claude/flow-audit/config.json，不進 repo）

隱私（11-22 Keng：排除隱私內容再收集）：送出去的版本只有數字和類別——
  session 名換成 S1、S2…，專案名換成代號，程式名換成類別（Claude／瀏覽器／通訊／同步／開發／系統／其他），
  沒有任何對話內容、檔案路徑、電腦名稱、帳號、IP；--names 只影響本機存的那份。

只讀不改：不會停任何 session、不會改設定。只用 Python 標準庫，Mac／Windows／Linux 都能跑（網路那段 Mac 最完整）。
"""
import argparse, glob, hashlib, json, os, platform, re, socket, statistics, subprocess, sys, time
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
CLAUDE = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
IS_WIN = platform.system() == "Windows"
IS_MAC = platform.system() == "Darwin"

# 等效單價（每百萬 token，輸入／輸出），跟 ~/.claude/scripts/usage_stats.py 同一張；快取讀 0.1 倍、5 分鐘寫 1.25 倍、1 小時寫 2 倍
PRICES = {"claude-opus": (5.0, 25.0), "claude-sonnet": (3.0, 15.0), "claude-haiku": (1.0, 5.0), "claude-fable": (5.0, 25.0)}
DEFAULT_PRICE = (5.0, 25.0)


def price(model):
    m = (model or "").lower()
    for k, v in PRICES.items():
        if m.startswith(k):
            return v
    return DEFAULT_PRICE


def cost_of(u, model):
    i, o = price(model)
    cc = u.get("cache_creation") or {}
    w5, w1 = cc.get("ephemeral_5m_input_tokens"), cc.get("ephemeral_1h_input_tokens")
    if w5 is None and w1 is None:
        w5, w1 = u.get("cache_creation_input_tokens", 0), 0
    t = u.get("input_tokens", 0) * i + u.get("cache_read_input_tokens", 0) * i * 0.1 + (w5 or 0) * i * 1.25 + (w1 or 0) * i * 2.0 + u.get("output_tokens", 0) * o
    return t / 1e6


def pid_alive(pid):
    if not pid:
        return False
    if IS_WIN:   # ⚠ Windows 的 os.kill(pid, 0) 會真的把程式關掉，只能用 tasklist 問
        try:
            out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True, timeout=10).stdout
            return str(pid) in out
        except Exception:
            return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def fmt_tok(n):
    return f"{n/1e6:.1f}M" if n >= 1e6 else f"{n/1e3:.0f}k" if n >= 1e3 else str(int(n))


def slug_of(cwd):
    return re.sub(r"[^A-Za-z0-9-]", "-", cwd or "")


def project_name(slug):
    home = slug_of(HOME)
    s = slug[len(home):] if slug.startswith(home) else slug
    s = s.strip("-")
    for pre in ("github-repos-", "Desktop-", "Documents-"):
        if s.startswith(pre):
            s = s[len(pre):]
    s = re.sub(r"^-*wt-", "", s).strip("-")          # worktree 資料夾 _wt-xxx
    return s or "（家目錄）"


def code(name):
    return "P" + hashlib.sha1(name.encode()).hexdigest()[:6]


# ───────────────────────── Claude 額度 ─────────────────────────

def transcript_path(sid, cwd):
    p = os.path.join(CLAUDE, "projects", slug_of(cwd), f"{sid}.jsonl")
    if os.path.exists(p):
        return p
    hits = glob.glob(os.path.join(CLAUDE, "projects", "*", f"{sid}.jsonl"))
    return hits[0] if hits else None


def last_ctx(path):
    """最後一則 AI 回覆時的 context 大小（輸入＋快取讀＋快取寫），只看檔尾 2MB"""
    if not path:
        return 0
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 2_000_000))
            tail = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return 0
    for line in reversed(tail):
        if '"usage"' not in line or '"assistant"' not in line:
            continue
        try:
            u = json.loads(line)["message"]["usage"]
            return u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
        except Exception:
            continue
    return 0


def sessions():
    recs = []
    for f in glob.glob(os.path.join(CLAUDE, "sessions", "*.json")):
        try:
            r = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        if pid_alive(r.get("pid")):
            recs.append(r)
    jobs = {r.get("jobId") for r in recs if r.get("jobId")}
    now = time.time() * 1000
    out = []
    for r in recs:
        sid, cwd = r.get("sessionId", ""), r.get("cwd", "")
        tp = transcript_path(sid, cwd)
        has_talk = bool(tp) and os.path.getsize(tp) > 0
        kind = r.get("kind") or "interactive"
        if r.get("entrypoint") == "sdk-cli":
            cat = "無頭呼叫（claude -p）"
        elif r.get("parkedJobId") in jobs:
            cat = "停放空殼（對話已轉到背景）"
        elif kind == "bg" and (not r.get("name") or r.get("name") == sid[:8]) and not has_talk:
            cat = "預備程序（Claude 內建、空的）"
        elif kind == "bg":
            cat = "背景 session"
        else:
            cat = "互動 session"
        idle = (now - (r.get("statusUpdatedAt") or r.get("updatedAt") or now)) / 60000
        out.append({"pid": r.get("pid"), "name": r.get("name") or sid[:8], "cat": cat, "status": r.get("status") or "?",
                    "idle_min": round(max(0, idle)), "ctx": last_ctx(tp), "project": project_name(slug_of(cwd))})
    return out


def usage_today(days=1):
    """今天（本地時間）的 token：依專案、主 session／子 agent 分；同一則訊息只算一次"""
    start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=days - 1)
    cutoff = start.timestamp() - 3600
    files = [p for p in glob.glob(os.path.join(CLAUDE, "projects", "**", "*.jsonl"), recursive=True) if os.path.getmtime(p) >= cutoff]
    seen, by_proj, tot = set(), {}, {"msgs": 0, "input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "cost": 0.0, "sub_cost": 0.0}
    openers = []
    for p in files:
        rel = os.path.relpath(p, os.path.join(CLAUDE, "projects"))
        slug, is_sub = rel.split(os.sep)[0], "subagents" in rel
        first = True
        try:
            fh = open(p, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    o = json.loads(line)
                    m = o.get("message") or {}
                    u = m.get("usage")
                    ts = o.get("timestamp")
                    if not u or not ts:
                        continue
                    t = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().replace(tzinfo=None)
                except Exception:
                    continue
                if not is_sub and first:
                    first = False
                    if t >= start:   # 今天新開的 session：第一則回覆的 context＝開場成本
                        openers.append(u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0))
                if t < start:
                    continue
                key = m.get("id") or o.get("uuid")
                if key in seen:
                    continue
                seen.add(key)
                c = cost_of(u, m.get("model"))
                d = by_proj.setdefault(slug, {"cost": 0.0, "msgs": 0, "sub_cost": 0.0})
                d["cost"] += c; d["msgs"] += 1
                if is_sub:
                    d["sub_cost"] += c; tot["sub_cost"] += c
                tot["msgs"] += 1; tot["cost"] += c
                tot["input"] += u.get("input_tokens", 0); tot["output"] += u.get("output_tokens", 0)
                tot["cache_read"] += u.get("cache_read_input_tokens", 0); tot["cache_write"] += u.get("cache_creation_input_tokens", 0)
    denom = tot["input"] + tot["cache_read"] + tot["cache_write"]
    tot["cache_hit"] = round(tot["cache_read"] / denom, 3) if denom else None
    tot["opener_median"] = int(statistics.median(openers)) if openers else None
    tot["sessions_started"] = len(openers)
    return tot, by_proj


def file_tokens(path):
    try:
        s = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return 0
    cjk = len(re.findall(r"[　-鿿＀-￯]", s))
    return int(cjk * 1.0 + (len(s) - cjk) / 4)       # 粗估：中文一字約 1 token、英文 4 字元 1 token


def standing_config():
    """每個 session 一開就會載入的東西（越重，每次開場、每輪都越貴）"""
    conf = {"claude_md": file_tokens(os.path.join(CLAUDE, "CLAUDE.md")), "memory_index": 0, "mcp_servers": 0, "hooks": 0, "plugins": 0, "skills": 0}
    mem = glob.glob(os.path.join(CLAUDE, "projects", "*", "memory", "MEMORY.md"))
    conf["memory_index"] = max([file_tokens(m) for m in mem] or [0])
    names = set()
    for f in (os.path.join(HOME, ".claude.json"), os.path.join(CLAUDE, "settings.json"), os.path.join(CLAUDE, "settings.local.json")):
        try:
            j = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        names |= set((j.get("mcpServers") or {}).keys())
        for proj in (j.get("projects") or {}).values():
            if isinstance(proj, dict):
                names |= set((proj.get("mcpServers") or {}).keys())
        for ev in (j.get("hooks") or {}).values():
            for grp in ev or []:
                conf["hooks"] += len((grp or {}).get("hooks") or [])
        conf["plugins"] += sum(1 for v in (j.get("enabledPlugins") or {}).values() if v)
    conf["mcp_servers"] = len(names)
    conf["skills"] = len(glob.glob(os.path.join(CLAUDE, "skills", "*", "SKILL.md")))
    return conf


def rate_limits():
    try:
        r = json.load(open(os.path.join(CLAUDE, "cache", "rate_limits.json"), encoding="utf-8"))["rate_limits"]
        return {k: {"used": v.get("used_percentage"), "resets": datetime.fromtimestamp(v["resets_at"]).strftime("%m-%d %H:%M") if v.get("resets_at") else None} for k, v in r.items()}
    except Exception:
        return None   # 沒裝 ShoWork42 的狀態列就沒有這份


# ───────────────────────── 網路流量 ─────────────────────────

def proc_names(pids):
    names = {}
    if not pids:
        return names
    if IS_WIN:
        try:
            for line in subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True, timeout=20).stdout.splitlines():
                parts = [x.strip('"') for x in line.split('","')]
                if len(parts) >= 2 and parts[1].isdigit():
                    names[int(parts[1])] = parts[0]
        except Exception:
            pass
        return names
    try:
        out = subprocess.run(["ps", "-o", "pid=,comm=", "-p", ",".join(map(str, pids))], capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            pid, _, comm = line.strip().partition(" ")
            if pid.isdigit():
                names[int(pid)] = os.path.basename(comm.strip())
    except Exception:
        pass
    return names


def pretty_proc(name):
    if re.fullmatch(r"\d+\.\d+\.\d+", name or "") or name in ("claude", "node"):
        return "Claude Code" if re.fullmatch(r"\d+\.\d+\.\d+", name or "") or name == "claude" else name
    return name


def iface_bytes():
    tot_in = tot_out = 0
    try:
        if IS_WIN:
            out = subprocess.run(["netstat", "-e"], capture_output=True, text=True, timeout=10).stdout
            m = re.search(r"Bytes\s+(\d+)\s+(\d+)", out) or re.search(r"位元組\s+(\d+)\s+(\d+)", out)
            return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
        out = subprocess.run(["netstat", "-ib"], capture_output=True, text=True, timeout=10).stdout
        seen = set()
        for line in out.splitlines()[1:]:
            c = line.split()
            if len(c) < 10 or not c[2].startswith("<Link") or c[0].startswith(("lo", "utun", "awdl", "llw", "bridge", "anpi", "gif", "stf")) or c[0] in seen:
                continue
            seen.add(c[0])
            # 欄位：… Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll（Address 可能空著，所以從尾巴數）
            if len(c) >= 7 and c[-5].isdigit() and c[-2].isdigit():
                tot_in += int(c[-5]); tot_out += int(c[-2])
    except Exception:
        pass
    return tot_in, tot_out


def per_process(seconds):
    """Mac：nettop 取樣 seconds 秒的每個程式進出量"""
    if not IS_MAC:
        return []
    try:
        out = subprocess.run(["nettop", "-P", "-d", "-L", "2", "-s", str(seconds), "-x", "-J", "bytes_in,bytes_out"],
                             capture_output=True, text=True, timeout=seconds + 20).stdout
    except Exception:
        return []
    blocks, cur = [], []
    for line in out.splitlines():
        if line.startswith(",bytes_in"):
            if cur:
                blocks.append(cur)
            cur = []
        elif line.strip():
            cur.append(line)
    if cur:
        blocks.append(cur)
    if not blocks:
        return []
    rows = []
    for line in blocks[-1]:          # 最後一段＝這 seconds 秒的增量
        p = line.rstrip(",").split(",")
        if len(p) < 3:
            continue
        name, _, pid = p[0].rpartition(".")
        try:
            rows.append({"pid": int(pid), "name": name, "in": int(p[1]), "out": int(p[2])})
        except ValueError:
            continue
    rows = [r for r in rows if r["in"] + r["out"] > 0]
    real = proc_names([r["pid"] for r in rows])
    for r in rows:
        r["name"] = pretty_proc(real.get(r["pid"], r["name"]))
    merged = {}
    for r in rows:
        m = merged.setdefault(r["name"], {"name": r["name"], "in": 0, "out": 0, "procs": 0})
        m["in"] += r["in"]; m["out"] += r["out"]; m["procs"] += 1
    return sorted(merged.values(), key=lambda r: -(r["in"] + r["out"]))


def connections():
    counts = {}
    try:
        if IS_WIN:
            out = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, text=True, timeout=20).stdout
            pids = [int(l.split()[-1]) for l in out.splitlines() if "ESTABLISHED" in l and l.split()[-1].isdigit()]
            names = proc_names(pids)
            for pid in pids:
                n = names.get(pid, str(pid)); counts[n] = counts.get(n, 0) + 1
        else:
            out = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:ESTABLISHED"], capture_output=True, text=True, timeout=20).stdout
            pids = {}
            for l in out.splitlines()[1:]:
                c = l.split()
                if len(c) > 1 and c[1].isdigit():
                    pids[int(c[1])] = pids.get(int(c[1]), 0) + 1
            names = proc_names(list(pids))
            for pid, n in pids.items():
                k = pretty_proc(names.get(pid, str(pid))); counts[k] = counts.get(k, 0) + n
    except Exception:
        pass
    return sorted(([k, v] for k, v in counts.items()), key=lambda x: -x[1])


def network(seconds):
    if seconds <= 0:
        return None
    a = iface_bytes()
    t0 = time.time()
    procs = per_process(seconds)
    if not procs:
        time.sleep(max(0, seconds - (time.time() - t0)))
    b = iface_bytes()
    dt = max(1e-6, time.time() - t0)
    return {"seconds": round(dt, 1), "total_in_Bps": round((b[0] - a[0]) / dt), "total_out_Bps": round((b[1] - a[1]) / dt),
            "top": [dict(r, in_Bps=round(r["in"] / dt), out_Bps=round(r["out"] / dt)) for r in procs[:12]], "connections": connections()[:12]}


# ───────────────────────── 隱私：送出去的版本只留數字與類別 ─────────────────────────

CATS = [("Claude", r"claude|anthropic|^Claude Code$|bg-spare"), ("瀏覽器", r"chrome|safari|firefox|edge|arc|brave|webkit"),
        ("通訊", r"discord|line|slack|telegram|whatsapp|mail|messages|zoom|teams|wechat"),
        ("同步／雲端", r"icloud|bird|cloudd|dropbox|onedrive|google ?drive|nsurlsessiond|syncthing"),
        ("開發", r"node|python|git|ssh|docker|xcode|swift|code|cursor|adb|cloudflared|tailscale|npm|ollama"),
        ("系統", r"mdns|apsd|rapportd|identityservices|trustd|launchd|kernel|svchost|system|networkd|softwareupdate|configd|sharingd")]


def category(name):
    n = (name or "").lower()
    for cat, pat in CATS:
        if re.search(pat, n):
            return cat
    return "其他"


def scrub(r):
    """去隱私版：session 名 → S1…、專案 → 代號、程式 → 類別；不含電腦名、路徑、對話"""
    x = json.loads(json.dumps(r))
    for i, s in enumerate(sorted(x["claude"]["sessions"], key=lambda s: -s["ctx"]), 1):
        s["name"] = f"S{i}"; s["project"] = code(s["project"]); s.pop("pid", None)
    x["claude"]["by_project"] = [[code(n), v] for n, v in x["claude"]["by_project"]]
    n = x.get("network")
    if n:
        cats = {}
        for p in n["top"]:
            c = cats.setdefault(category(p["name"]), {"name": category(p["name"]), "in_Bps": 0, "out_Bps": 0, "procs": 0})
            c["in_Bps"] += p["in_Bps"]; c["out_Bps"] += p["out_Bps"]; c["procs"] += p.get("procs", 1)
        n["top"] = sorted(cats.values(), key=lambda c: -(c["in_Bps"] + c["out_Bps"]))
        conn = {}
        for k, v in n["connections"]:
            conn[category(k)] = conn.get(category(k), 0) + v
        n["connections"] = sorted(([k, v] for k, v in conn.items()), key=lambda x: -x[1])
    x["advice"] = advice(x["claude"]["sessions"], x["claude"]["today"], x["claude"]["standing"], x["claude"]["rate_limits"], n)
    x["private"] = False
    return x


CONF = os.path.join(CLAUDE, "flow-audit", "config.json")


def webhook():
    url = os.environ.get("FLOW_AUDIT_WEBHOOK")
    if url:
        return url
    try:
        return json.load(open(CONF, encoding="utf-8")).get("webhook")
    except Exception:
        return None


def set_webhook(url):
    if not re.match(r"^https://(ptb\.|canary\.)?discord(app)?\.com/api/webhooks/\d+/[\w-]+$", url):
        sys.exit("這不像 Discord webhook 網址（https://discord.com/api/webhooks/…）")
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    json.dump({"webhook": url}, open(CONF, "w", encoding="utf-8"))
    try:
        os.chmod(CONF, 0o600)
    except Exception:
        pass
    print(f"已存回報網址（只在這台：{CONF}）")


def send(shared, text):
    """送到 Discord：摘要＋建議當訊息內文，去隱私版 JSON 與完整報告當附件"""
    import urllib.request, uuid
    url = webhook()
    if not url:
        sys.exit("還沒設定回報網址：python3 scripts/flow_audit.py --set-webhook <Discord webhook 網址>（網址向 Keng 要）")
    t, c = shared["claude"]["today"], shared["claude"]
    rl = c["rate_limits"] or {}
    head = (f"**流量架構自檢｜{shared['label']}｜{shared['at']}｜{shared['os']}**\n"
            f"額度：5h {(rl.get('five_hour') or {}).get('used', '—')}%、7d {(rl.get('seven_day') or {}).get('used', '—')}%　"
            f"session {len(c['sessions'])} 個　今天 {t['msgs']} 則、等效 US${t['cost']:.2f}　快取命中 {round((t['cache_hit'] or 0)*100)}%　"
            f"開場 context {fmt_tok(t['opener_median'] or 0)}\n**優化方向**\n" + "\n".join(f"• {a}" for a in shared["advice"]))
    files = [("report.json", json.dumps(shared, ensure_ascii=False, indent=1).encode()), ("report.txt", text.encode())]
    b = uuid.uuid4().hex
    body = bytearray()
    def part(h, data):
        body.extend(f"--{b}\r\n{h}\r\n\r\n".encode()); body.extend(data); body.extend(b"\r\n")
    part('Content-Disposition: form-data; name="payload_json"\r\nContent-Type: application/json',
         json.dumps({"content": head[:1990], "username": "流量自檢", "allowed_mentions": {"parse": []}}, ensure_ascii=False).encode())
    for i, (fn, data) in enumerate(files):
        safe = re.sub(r"[^\w.\-]", "_", f"{shared['label']}-{shared['at'].replace(' ', '_').replace(':', '')}-{fn}")
        part(f'Content-Disposition: form-data; name="files[{i}]"; filename="{safe}"\r\nContent-Type: application/octet-stream', data)
    body.extend(f"--{b}--\r\n".encode())
    url += ("&" if "?" in url else "?") + "wait=true"      # 等 Discord 回傳訊息，確認附件真的有上去
    req = urllib.request.Request(url, data=bytes(body), method="POST", headers={"Content-Type": f"multipart/form-data; boundary={b}", "User-Agent": "ShoWork42-flow-audit/1"})
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            msg = json.loads(res.read() or b"{}")
            print(f"已送出到回報頻道（HTTP {res.status}，附件：{'、'.join(x.get('filename', '') for x in msg.get('attachments', [])) or '無'}）")
    except Exception as e:
        sys.exit(f"送出失敗：{e}")


# ───────────────────────── 判讀與建議 ─────────────────────────

def advice(ss, tot, conf, rl, net):
    tips = []
    spare = [s for s in ss if s["cat"].startswith("預備")]
    shell = [s for s in ss if s["cat"].startswith("停放")]
    big_idle = [s for s in ss if s["ctx"] >= 150_000 and s["idle_min"] >= 60 and not s["cat"].startswith(("預備", "停放"))]
    busy = [s for s in ss if s["status"] == "busy"]
    if spare:
        tips.append(f"有 {len(spare)} 個 Claude 預備程序（空的，不花 token、各吃一點記憶體）；不想要可以 claude stop <id>")
    if shell:
        tips.append(f"有 {len(shell)} 個停放後的終端機空殼：對話已在背景繼續，這幾個視窗可以關")
    if big_idle:
        tips.append("閒置超過 1 小時、記憶量又大（≥150k）的 session：" + "、".join(f"{s['name']}（{fmt_tok(s['ctx'])}）" for s in big_idle[:5])
                    + "。快取過期後再問一句會整段重寫快取，最貴；不用了就 /clear 或關掉")
    if len(busy) >= 4:
        tips.append(f"同時有 {len(busy)} 個 session 在跑，額度消耗會疊加；不急的排隊做")
    if tot.get("cache_hit") is not None and tot["cache_hit"] < 0.8:
        tips.append(f"快取命中率 {tot['cache_hit']*100:.0f}% 偏低（健康約 90% 以上）：常常隔很久才回一句、或頻繁切換專案都會讓快取失效")
    if tot["cost"] and tot["sub_cost"] / tot["cost"] > 0.4:
        tips.append(f"子 agent 佔今天花費 {tot['sub_cost']/tot['cost']*100:.0f}%：多開的子 agent／工作流程是主要開銷")
    if tot.get("opener_median") and tot["opener_median"] > 40_000:
        tips.append(f"每開一個 session 的開場 context 中位數 {fmt_tok(tot['opener_median'])}：CLAUDE.md、記憶索引、MCP、技能清單太重，每次開場、每一輪都要付")
    if conf["memory_index"] > 6000:
        tips.append(f"記憶索引 MEMORY.md 約 {fmt_tok(conf['memory_index'])} token，每個 session 都會載入；可以精簡")
    if conf["mcp_servers"] >= 8:
        tips.append(f"設定了 {conf['mcp_servers']} 個 MCP 伺服器，沒在用的關掉可以減少工具清單的 token")
    if rl and (rl.get("five_hour") or {}).get("used", 0) and rl["five_hour"]["used"] >= 80:
        tips.append(f"5 小時額度已用 {rl['five_hour']['used']}%，重置時間 {rl['five_hour']['resets']}")
    if net and net["top"]:
        t = net["top"][0]
        if (t["in_Bps"] + t["out_Bps"]) > 2_000_000:
            tips.append(f"網路最大宗是 {t['name']}（約 {(t['in_Bps']+t['out_Bps'])/1e6:.1f} MB/s），確認是不是該在跑")
    return tips or ["沒看到明顯的浪費"]


def human(n):
    return f"{n/1e6:.1f} MB" if n >= 1e6 else f"{n/1e3:.0f} KB" if n >= 1e3 else f"{n} B"


def report(r):
    L = [f"━━ 流量架構自檢｜{r['label']}｜{r['at']}｜{r['os']} ━━", ""]
    rl = r["claude"]["rate_limits"]
    if rl:
        L.append("額度：" + "　".join(f"{'5 小時' if k == 'five_hour' else '7 天'} {v['used']}%（{v['resets']} 重置）" for k, v in rl.items()))
    else:
        L.append("額度：讀不到（這台沒有 ShoWork42 狀態列寫的 rate_limits.json）")
    L += ["", "【這台開著的 Claude】"]
    cats = {}
    for s in r["claude"]["sessions"]:
        cats[s["cat"]] = cats.get(s["cat"], 0) + 1
    L.append("　" + "、".join(f"{k} {v}" for k, v in cats.items()) if cats else "　（沒有）")
    for s in sorted(r["claude"]["sessions"], key=lambda s: -s["ctx"])[:12]:
        L.append(f"　- {s['name']:<14} {s['cat']:<14} {s['status']:<5} 閒置 {s['idle_min']:>4} 分　記憶量 {fmt_tok(s['ctx']):>6}　{s['project']}")
    t = r["claude"]["today"]
    L += ["", "【今天的 token】",
          f"　訊息 {t['msgs']}　輸入 {fmt_tok(t['input'])}　輸出 {fmt_tok(t['output'])}　快取讀 {fmt_tok(t['cache_read'])}　快取寫 {fmt_tok(t['cache_write'])}",
          f"　等效花費 US${t['cost']:.2f}（子 agent US${t['sub_cost']:.2f}）　快取命中 {('%.0f%%' % (t['cache_hit']*100)) if t['cache_hit'] is not None else '—'}"
          f"　今天新開 {t['sessions_started']} 個 session，開場 context 中位數 {fmt_tok(t['opener_median']) if t['opener_median'] else '—'}"]
    for name, d in r["claude"]["by_project"][:8]:
        L.append(f"　- {name:<28} US${d['cost']:>7.2f}　{d['msgs']:>5} 則" + (f"（子 agent US${d['sub_cost']:.2f}）" if d["sub_cost"] else ""))
    c = r["claude"]["standing"]
    L += ["", "【每個 session 一開就載入的常駐設定】",
          f"　CLAUDE.md 約 {fmt_tok(c['claude_md'])} token　記憶索引約 {fmt_tok(c['memory_index'])}　MCP {c['mcp_servers']} 個　hooks {c['hooks']} 個　外掛 {c['plugins']} 個　技能 {c['skills']} 個"]
    n = r["network"]
    if n:
        L += ["", f"【網路（取樣 {n['seconds']} 秒）】", f"　網卡合計：下載 {human(n['total_in_Bps'])}/s　上傳 {human(n['total_out_Bps'])}/s"]
        for p in n["top"][:8]:
            L.append(f"　- {p['name']:<24} ↓ {human(p['in_Bps']):>9}/s　↑ {human(p['out_Bps']):>9}/s")
        if n["connections"]:
            L.append("　連線最多：" + "、".join(f"{k} {v}" for k, v in n["connections"][:6]))
    L += ["", "【建議】"] + [f"　• {x}" for x in r["advice"]]
    return "\n".join(L)


def compare(a, b):
    A, B = json.load(open(a, encoding="utf-8")), json.load(open(b, encoding="utf-8"))

    def g(r, *path):
        for k in path:
            r = (r or {}).get(k) if isinstance(r, dict) else None
        return r

    def cnt(r, prefix):
        return sum(1 for s in r["claude"]["sessions"] if s["cat"].startswith(prefix))
    rows = [
        ("5 小時額度 %", g(A, "claude", "rate_limits", "five_hour", "used"), g(B, "claude", "rate_limits", "five_hour", "used")),
        ("7 天額度 %", g(A, "claude", "rate_limits", "seven_day", "used"), g(B, "claude", "rate_limits", "seven_day", "used")),
        ("開著的互動 session", cnt(A, "互動"), cnt(B, "互動")),
        ("背景 session", cnt(A, "背景"), cnt(B, "背景")),
        ("預備程序／停放空殼", cnt(A, "預備") + cnt(A, "停放"), cnt(B, "預備") + cnt(B, "停放")),
        ("最大記憶量", fmt_tok(max([s["ctx"] for s in A["claude"]["sessions"]] or [0])), fmt_tok(max([s["ctx"] for s in B["claude"]["sessions"]] or [0]))),
        ("今天訊息數", g(A, "claude", "today", "msgs"), g(B, "claude", "today", "msgs")),
        ("今天等效花費 US$", round(g(A, "claude", "today", "cost") or 0, 2), round(g(B, "claude", "today", "cost") or 0, 2)),
        ("子 agent 佔比 %", round(100 * (g(A, "claude", "today", "sub_cost") or 0) / max(1e-9, g(A, "claude", "today", "cost") or 0)),
         round(100 * (g(B, "claude", "today", "sub_cost") or 0) / max(1e-9, g(B, "claude", "today", "cost") or 0))),
        ("快取命中 %", round(100 * (g(A, "claude", "today", "cache_hit") or 0)), round(100 * (g(B, "claude", "today", "cache_hit") or 0))),
        ("開場 context 中位數", fmt_tok(g(A, "claude", "today", "opener_median") or 0), fmt_tok(g(B, "claude", "today", "opener_median") or 0)),
        ("CLAUDE.md token", g(A, "claude", "standing", "claude_md"), g(B, "claude", "standing", "claude_md")),
        ("記憶索引 token", g(A, "claude", "standing", "memory_index"), g(B, "claude", "standing", "memory_index")),
        ("MCP 伺服器", g(A, "claude", "standing", "mcp_servers"), g(B, "claude", "standing", "mcp_servers")),
        ("hooks", g(A, "claude", "standing", "hooks"), g(B, "claude", "standing", "hooks")),
        ("網路下載 /s", human(g(A, "network", "total_in_Bps") or 0), human(g(B, "network", "total_in_Bps") or 0)),
        ("網路上傳 /s", human(g(A, "network", "total_out_Bps") or 0), human(g(B, "network", "total_out_Bps") or 0)),
    ]
    w = 22
    print(f"{'項目':<{w}}{A['label']:>16}{B['label']:>16}")
    print("─" * (w + 32))
    for k, x, y in rows:
        print(f"{k:<{w}}{str(x if x is not None else '—'):>16}{str(y if y is not None else '—'):>16}")


def main():
    ap = argparse.ArgumentParser(description="ShoWork42 流量架構自檢（Claude 額度＋網路）")
    ap.add_argument("--label", default=None, help="這台是誰（報告與檔名用）")
    ap.add_argument("--net", type=int, default=10, help="網路取樣秒數，0＝不量")
    ap.add_argument("--names", action="store_true", help="JSON 保留專案名（預設只留代號）")
    ap.add_argument("--out", default=os.path.join(CLAUDE, "flow-audit"), help="JSON 存放資料夾")
    ap.add_argument("--compare", nargs=2, metavar=("A.json", "B.json"))
    ap.add_argument("--send", action="store_true", help="把去隱私版報告＋優化建議送到回報頻道")
    ap.add_argument("--set-webhook", metavar="URL", help="設定回報網址（只存本機）")
    a = ap.parse_args()
    if a.set_webhook:
        return set_webhook(a.set_webhook)
    if a.compare:
        return compare(*a.compare)
    label = a.label or platform.system()
    ss = sessions()
    tot, by_proj = usage_today()
    conf = standing_config()
    rl = rate_limits()
    print(f"網路取樣 {a.net} 秒⋯", file=sys.stderr) if a.net else None
    net = network(a.net)
    proj = sorted(((project_name(k), v) for k, v in by_proj.items()), key=lambda x: -x[1]["cost"])
    r = {"version": 1, "label": label, "at": datetime.now().strftime("%Y-%m-%d %H:%M"), "os": f"{platform.system()} {platform.release()}",
         "claude": {"rate_limits": rl, "sessions": ss, "today": tot, "by_project": [[n, v] for n, v in proj], "standing": conf},
         "network": net}
    r["advice"] = advice(ss, tot, conf, rl, net)
    print(report(r))
    shared = r if a.names else scrub(r)
    os.makedirs(a.out, exist_ok=True)
    safe = re.sub(r"[^\w\-]", "_", label)
    path = os.path.join(a.out, f"flow-audit-{safe}-{datetime.now().strftime('%Y%m%d-%H%M')}.json")
    json.dump(shared, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"\n已存：{path}（{'含專案名，只給自己看' if a.names else '去隱私版：session、專案、程式都只剩代號和類別'}）")
    if a.send:
        pub = scrub(r)
        send(pub, report(pub))


if __name__ == "__main__":
    main()
