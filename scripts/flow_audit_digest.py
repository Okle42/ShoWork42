#!/usr/bin/env python3
"""流量自檢報告彙整（11-22 Keng：自動彙整所有人的報告，產出統一優化建議）

讀 Okle42 Discord #自檢回報 裡每台電腦送上來的 report.json（flow_audit.py --send 的附件，已去隱私），
每台只取最新一份，算出：每台的關鍵數字、跟中位數比誰偏高、大家共通的問題（出現在一半以上的台數），
再產出「統一優化建議」，印出來；加 --post 就貼回頻道。

用法（只在管理者電腦跑；要 Discord 機器人權杖，放在 ~/.discord42/bot_token，不進 repo）：
  python3 scripts/flow_audit_digest.py                 # 印總表
  python3 scripts/flow_audit_digest.py --post          # 印總表並貼到 #自檢回報
  python3 scripts/flow_audit_digest.py --days 7        # 只看最近 7 天的報告（預設 14）
環境變數：FLOW_AUDIT_CHANNEL（頻道 id）、DISCORD_BOT_TOKEN（不想用檔案時）
"""
import argparse, json, os, re, statistics, sys, urllib.request
from datetime import datetime, timedelta, timezone

CHANNEL = os.environ.get("FLOW_AUDIT_CHANNEL", "1574003208366460988")
API = "https://discord.com/api/v10"


def token():
    t = os.environ.get("DISCORD_BOT_TOKEN")
    if t:
        return t.strip()
    p = os.path.expanduser("~/.discord42/bot_token")
    if not os.path.exists(p):
        sys.exit("找不到機器人權杖（~/.discord42/bot_token 或 DISCORD_BOT_TOKEN）")
    return open(p).read().strip()


def api(path, tok, method="GET", body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bot " + tok, "Content-Type": "application/json", "User-Agent": "DiscordBot (okle42, 1)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"null")


def fetch_reports(tok, days):
    since = datetime.now(timezone.utc) - timedelta(days=days)
    out, before = [], None
    for _ in range(10):        # 最多讀 1000 則
        q = f"/channels/{CHANNEL}/messages?limit=100" + (f"&before={before}" if before else "")
        msgs = api(q, tok)
        if not msgs:
            break
        for m in msgs:
            if datetime.fromisoformat(m["timestamp"]) < since:
                return out
            for a in m.get("attachments", []):
                if a["filename"].endswith("report.json"):
                    try:
                        r = json.loads(urllib.request.urlopen(urllib.request.Request(a["url"], headers={"User-Agent": "okle42"}), timeout=30).read())
                        if r.get("version") == 1 and "claude" in r:
                            out.append(r)
                    except Exception:
                        pass
        before = msgs[-1]["id"]
    return out


def latest_per_machine(reports):
    best = {}
    for r in reports:
        k = r.get("label", "?")
        if k not in best or r.get("at", "") > best[k].get("at", ""):
            best[k] = r
    return sorted(best.values(), key=lambda r: r.get("label", ""))


def metrics(r):
    c, t, s = r["claude"], r["claude"]["today"], r["claude"]["standing"]
    ss = c["sessions"]
    rl = c.get("rate_limits") or {}
    return {
        "5h%": (rl.get("five_hour") or {}).get("used"),
        "7d%": (rl.get("seven_day") or {}).get("used"),
        "session": len(ss),
        "空殼/預備": sum(1 for x in ss if x["cat"].startswith(("停放", "預備"))),
        "大記憶閒置": sum(1 for x in ss if x["ctx"] >= 150_000 and x["idle_min"] >= 60 and not x["cat"].startswith(("停放", "預備"))),
        "今日US$": round(t.get("cost") or 0, 1),
        "子agent%": round(100 * (t.get("sub_cost") or 0) / t["cost"]) if t.get("cost") else 0,
        "快取%": round(100 * t["cache_hit"]) if t.get("cache_hit") is not None else None,
        "開場k": round((t.get("opener_median") or 0) / 1000),
        "記憶索引k": round((s.get("memory_index") or 0) / 1000, 1),
        "MCP": s.get("mcp_servers"),
        "hooks": s.get("hooks"),
    }


# 每個問題：判斷式＋統一建議（共通問題就變成大家一起改的規則）
RULES = [
    ("空殼/預備", lambda m: m["空殼/預備"] > 0, "停放後的終端機空殼、Claude 預備程序要定期收：空殼視窗直接關；背景 session 用 claude stop，不要 kill"),
    ("大記憶閒置", lambda m: m["大記憶閒置"] > 0, "大記憶量（≥150k）閒置超過 1 小時的 session：做完就 /clear 或關掉，不要隔很久再回一句（快取過期會整段重寫，最貴）"),
    ("快取%", lambda m: m["快取%"] is not None and m["快取%"] < 85, "快取命中低於 85%：一件事一口氣做完、少在多個專案間來回切，回覆間隔不要超過 5 分鐘"),
    ("子agent%", lambda m: m["子agent%"] > 40, "子 agent 花費超過四成：小事自己做，平行派工只用在真的獨立的工作"),
    ("開場k", lambda m: m["開場k"] > 40, "每開一個 session 的開場 context 超過 40k：精簡 CLAUDE.md、記憶索引，關掉沒在用的 MCP／外掛"),
    ("記憶索引k", lambda m: m["記憶索引k"] > 6, "記憶索引超過 6k token：一則一行、細節搬進主題檔，索引控制在 200 行內"),
    ("MCP", lambda m: (m["MCP"] or 0) >= 8, "MCP 伺服器 8 個以上：沒用到的關掉，工具清單每輪都要付 token"),
    ("5h%", lambda m: (m["5h%"] or 0) >= 80, "5 小時額度常衝到 80% 以上：重的工作（大量子 agent、長 build）錯開時段"),
]


def digest(reps):
    rows = [(r["label"], r.get("at", ""), metrics(r)) for r in reps]
    keys = list(rows[0][2].keys())
    med = {}
    for k in keys:
        vals = [m[k] for _, _, m in rows if isinstance(m[k], (int, float))]
        med[k] = statistics.median(vals) if vals else None
    lines = [f"**流量自檢彙整｜{len(rows)} 台｜{datetime.now().strftime('%Y-%m-%d %H:%M')}**", "", "```"]
    w = max(8, *(len(l) for l, _, _ in rows))
    lines.append("項目".ljust(12) + "".join(l[:w].rjust(w + 2) for l, _, _ in rows) + "中位數".rjust(10))
    for k in keys:
        cells = []
        for _, _, m in rows:
            v = m[k]
            hi = isinstance(v, (int, float)) and isinstance(med[k], (int, float)) and len(rows) > 2 and med[k] and v > med[k] * 1.5
            cells.append(f"{'—' if v is None else v}{'↑' if hi else ''}".rjust(w + 2))
        lines.append(k.ljust(12) + "".join(cells) + f"{'—' if med[k] is None else round(med[k], 1)}".rjust(10))
    lines.append("```")
    common, single = [], []
    for key, test, tip in RULES:
        hit = [l for l, _, m in rows if test(m)]
        if not hit:
            continue
        (common if len(hit) * 2 >= len(rows) else single).append((tip, hit))
    lines.append("**統一優化（一半以上的台數都有）**")
    lines += [f"• {tip}（{len(hit)}/{len(rows)} 台）" for tip, hit in common] or ["• 沒有共通問題"]
    if single:
        lines.append("**個別提醒**")
        lines += [f"• {'、'.join(hit)}：{tip}" for tip, hit in single]
    lines.append(f"_資料：各台最新一份報告（{', '.join(f'{l} {a}' for l, a, _ in rows)}）；全部是去隱私的數字_")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="流量自檢報告彙整")
    ap.add_argument("--post", action="store_true", help="貼回 #自檢回報")
    ap.add_argument("--days", type=int, default=14)
    a = ap.parse_args()
    tok = token()
    reps = latest_per_machine(fetch_reports(tok, a.days))
    if not reps:
        sys.exit("最近沒有任何報告")
    text = digest(reps)
    print(text)
    if a.post:
        chunks, cur = [], ""
        for line in text.split("\n"):      # Discord 一則上限 2000 字
            if len(cur) + len(line) + 1 > 1900:
                chunks.append(cur); cur = ""
            cur += line + "\n"
        chunks.append(cur)
        open_code = False
        for ch in chunks:
            body = ("```\n" if open_code else "") + ch
            open_code = (body.count("```") % 2 == 1)
            if open_code:
                body += "```"
            api(f"/channels/{CHANNEL}/messages", tok, "POST", {"content": body, "allowed_mentions": {"parse": []}})
        print(f"\n已貼到 #自檢回報（{len(chunks)} 則）")


if __name__ == "__main__":
    main()
