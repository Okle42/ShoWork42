#!/usr/bin/env python3
"""Mac／JS 場景 dump 比對（11-01 P0 量尺）。只用標準庫。

  python3 windows/tools/scene_diff.py <mac-scene.json> <js-scene.json> [--only 路徑開頭] [--skip 路徑,路徑] [--top N] [--samples N] [--json 輸出.json]
    --only  只比方塊／geometry 路徑以這個開頭的（燈光、鏡頭照比）
    --skip  整棵子樹不比（方塊、geometry、燈光、被藏的節點都略過），逗號分隔；例：--skip basement（B1 還沒搬）

dump 格式見 Mac Sources/ShoWorkAgent/SceneDump.swift 與 Web/kit.js walkScene()。比的東西：
  方塊（VoxelMesh）：世界座標中心、大小、yaw 配對（容差 0.011 公尺、yaw 0.002 弧度；yaw 先正規化到 [0, π/2)，轉 90° 的長寬互換），
                     配到之後再比材質（側面、頂面、底面）與 hidden。
  其他 geometry（SCNPlane、SCNBox…）：型別＋位置＋尺寸參數。
  燈光：依（型別, 路徑）分組後照順序配對，比強度、顏色、方向、位置、位元、衰減、hidden。
  鏡頭：依名字配對，比位置、朝向、fov、近遠裁切、霧距、後製參數、被藏的節點。
輸出「Mac 有、JS 沒有」與「JS 多出來」，依節點路徑分組計數，最後一行是總差異數（0＝一模一樣）。結束碼：0＝沒差異、1＝有差異。
"""
import json
import math
import sys
from collections import Counter, defaultdict

TOL, YTOL = 0.011, 0.002


def canon(b):
    """方塊的正規形：yaw 正規化到 [0, π/2)；轉 90°（或 270°）時長寬互換"""
    s = list(b["s"])
    y = b.get("yaw", 0.0)
    if abs(abs(y) - math.pi) < YTOL: y = 0.0
    y = y % math.pi
    if y >= math.pi / 2 - YTOL / 2:
        y -= math.pi / 2
        s[0], s[2] = s[2], s[0]
    if abs(y - math.pi / 2) < YTOL or y < 0 and abs(y) < YTOL:
        y = 0.0
    return b["c"], s, y


def mats(b):
    m = b.get("m", "")
    return (m, b.get("mt", m), b.get("mb", m))


def group(p, depth=2):
    parts = (p or "(root)").split("/")
    return "/".join(parts[:depth])


def match_boxes(A, B):
    """回傳 pairs（i, j）、A 沒配到的、B 沒配到的"""
    grid = defaultdict(list)
    cb = [canon(b) for b in B]
    for j, (c, s, y) in enumerate(cb):
        grid[(round(c[0] / 0.01), round(c[1] / 0.01), round(c[2] / 0.01))].append(j)
    used = [False] * len(B)
    pairs, miss = [], []
    for i, a in enumerate(A):
        c, s, y = canon(a)
        k = (round(c[0] / 0.01), round(c[1] / 0.01), round(c[2] / 0.01))
        best, bestScore = None, None
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for j in grid.get((k[0] + dx, k[1] + dy, k[2] + dz), ()):
                        if used[j]:
                            continue
                        c2, s2, y2 = cb[j]
                        if max(abs(c[t] - c2[t]) for t in range(3)) > TOL or max(abs(s[t] - s2[t]) for t in range(3)) > TOL:
                            continue
                        dyaw = abs(y - y2) % (math.pi / 2)
                        if min(dyaw, math.pi / 2 - dyaw) > YTOL:
                            continue
                        score = (mats(a) != mats(B[j])) * 2 + (a.get("h") != B[j].get("h"))
                        if best is None or score < bestScore:
                            best, bestScore = j, score
        if best is None:
            miss.append(i)
        else:
            used[best] = True
            pairs.append((i, best))
    extra = [j for j in range(len(B)) if not used[j]]
    return pairs, miss, extra


def close(a, b, tol=1e-3):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) and not isinstance(b, bool):
        return abs(a - b) <= tol * max(1.0, abs(a), abs(b))
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(close(x, y, tol) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(close(a[k], b[k], tol) for k in a)
    return a == b


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__); sys.exit(2)
    opt = lambda k, d=None: args[args.index(k) + 1] if k in args else d
    only, top, samples = opt("--only"), int(opt("--top", 25)), int(opt("--samples", 3))
    skips = [x for x in (opt("--skip") or "").split(",") if x]
    skipped = lambda p: any((p or "") == k or (p or "").startswith(k + "/") for k in skips)
    M, J = json.load(open(args[0])), json.load(open(args[1]))
    report = {}
    total = 0

    def filt(xs):
        return [x for x in xs if (only is None or (x.get("p") or "").startswith(only)) and not skipped(x.get("p"))]

    # ── 方塊
    A, B = filt(M.get("boxes", [])), filt(J.get("boxes", []))
    pairs, miss, extra = match_boxes(A, B)
    matdiff = [(i, j) for i, j in pairs if mats(A[i]) != mats(B[j])]
    hiddiff = [(i, j) for i, j in pairs if bool(A[i].get("h")) != bool(B[j].get("h"))]
    print(f"== 方塊：Mac {len(A)}、JS {len(B)}；位置配到 {len(pairs)}（材質不同 {len(matdiff)}、hidden 不同 {len(hiddiff)}）；"
          f"Mac 有 JS 沒有 {len(miss)}；JS 多出來 {len(extra)}")
    total += len(miss) + len(extra) + len(matdiff) + len(hiddiff)

    def show(title, idx, src):
        if not idx:
            return
        g = Counter(group(src[i]["p"]) for i in idx)
        print(f"-- {title}（依路徑前兩層）")
        for k, n in g.most_common(top):
            ex = [src[i] for i in idx if group(src[i]["p"]) == k][:samples]
            exs = "；".join(f"c={e['c']} s={e['s']} yaw={e.get('yaw', 0)} m={e['m'].split('|')[1]}" for e in ex)
            print(f"  {n:6d}  {k}    例：{exs}")
        if len(g) > top:
            print(f"  …另外 {len(g) - top} 組")
        report[title] = dict(g)

    show("Mac 有、JS 沒有", miss, A)
    show("JS 多出來", extra, B)
    if matdiff:
        g = Counter((group(A[i]["p"]), "／".join(sorted(set(mats(A[i])))), "／".join(sorted(set(mats(B[j]))))) for i, j in matdiff)
        print("-- 位置一樣、材質不同（路徑、Mac 材質 → JS 材質）")
        for (p, a, b), n in g.most_common(top):
            print(f"  {n:6d}  {p}\n          Mac {a}\n          JS  {b}")
        report["材質不同"] = len(matdiff)
    if hiddiff:
        g = Counter((group(A[i]["p"]), bool(A[i].get("h")), bool(B[j].get("h"))) for i, j in hiddiff)
        print("-- 位置一樣、hidden 不同（路徑、Mac、JS）")
        for (p, a, b), n in g.most_common(top):
            print(f"  {n:6d}  {p}  Mac hidden={a} JS hidden={b}")

    # ── 材質種類
    ma, mb = set(M.get("materials", [])), set(J.get("materials", []))
    if only is None and (ma - mb or mb - ma):
        print(f"== 材質種類：Mac {len(ma)}、JS {len(mb)}；Mac 有 JS 沒有 {len(ma - mb)}、JS 多 {len(mb - ma)}（材質 key：lm|diffuse|multiply|e強度|emission|a透明|雙面|寫深度|blend）")
        for k in sorted(ma - mb)[:top]:
            print("  Mac 有：", k)
        for k in sorted(mb - ma)[:top]:
            print("  JS 多：", k)

    # ── 其他 geometry
    GA, GB = filt(M.get("geoms", [])), filt(J.get("geoms", []))
    def gkey(g):
        return (g["type"], tuple(round(v, 2) for v in g["pos"]))
    used = [False] * len(GB)
    gmiss, gpar = [], []
    for g in GA:
        hit = None
        for j, h in enumerate(GB):
            if used[j] or h["type"] != g["type"] or max(abs(h["pos"][t] - g["pos"][t]) for t in range(3)) > TOL:
                continue
            hit = j
            if close(h.get("params"), g.get("params"), 2e-3):
                break
        if hit is None:
            gmiss.append(g)
        else:
            used[hit] = True
            h = GB[hit]
            wy = lambda y: (y + math.pi) % (2 * math.pi) - math.pi if isinstance(y, (int, float)) else y
            diffs = [k for k in ("params", "m", "h", "scale") if not close(g.get(k), h.get(k), 2e-3)]
            if abs(wy(g.get("yaw", 0) - h.get("yaw", 0) + 0.0)) > 2e-3: diffs.append("yaw")
            if diffs:
                gpar.append((g, h, diffs))
    gextra = [GB[j] for j in range(len(GB)) if not used[j]]
    print(f"== 其他 geometry：Mac {len(GA)}、JS {len(GB)}；Mac 有 JS 沒有 {len(gmiss)}；JS 多出來 {len(gextra)}；位置一樣但內容不同 {len(gpar)}")
    total += len(gmiss) + len(gextra) + len(gpar)
    for title, xs in (("Mac 有、JS 沒有", gmiss), ("JS 多出來", gextra)):
        if xs:
            print(f"-- {title}")
            for (p, t), n in Counter((group(x["p"]), x["type"]) for x in xs).most_common(top):
                print(f"  {n:6d}  {p}  {t}")
    for g, h, diffs in gpar[:top]:
        print(f"  不同 {g['p']} {g['type']} @{g['pos']}：" + "；".join(f"{k} Mac={g.get(k)} JS={h.get(k)}" for k in diffs))

    # ── 燈光
    LA = [l for l in M.get("lights", []) if not skipped(l.get("p"))]
    LB = [l for l in J.get("lights", []) if not skipped(l.get("p"))]
    print(f"== 燈光：Mac {len(LA)}、JS {len(LB)}")
    ga, gb = defaultdict(list), defaultdict(list)
    for l in LA: ga[(l["type"], l.get("p", ""))].append(l)
    for l in LB: gb[(l["type"], l.get("p", ""))].append(l)
    ldiff = 0
    for k in sorted(set(ga) | set(gb)):
        xs, ys = ga.get(k, []), gb.get(k, [])
        for n in range(max(len(xs), len(ys))):
            a = xs[n] if n < len(xs) else None
            b = ys[n] if n < len(ys) else None
            if a is None or b is None:
                ldiff += 1
                print(f"  {'JS 多出來' if a is None else 'Mac 有、JS 沒有'}：{k[0]} 路徑='{k[1]}' {(a or b)}")
                continue
            fields = ["intensity", "color", "mask", "h", "att"] + (["dir"] if k[0] in ("directional", "spot") else []) + (["pos"] if k[0] in ("omni", "spot") else [])
            bad = [f for f in fields if not close(a.get(f), b.get(f), 2e-3)]
            if bad:
                ldiff += 1
                print(f"  不同 {k[0]}#{n} 路徑='{k[1]}'：" + "；".join(f"{f} Mac={a.get(f)} JS={b.get(f)}" for f in bad))
    total += ldiff

    # ── 鏡頭
    CA = {c["name"]: c for c in M.get("cameras", [])}
    CB = {c["name"]: c for c in J.get("cameras", [])}
    print(f"== 鏡頭：Mac {sorted(CA)}、JS {sorted(CB)}")
    cdiff = 0
    for name in sorted(set(CA) | set(CB)):
        a, b = CA.get(name), CB.get(name)
        if a is None or b is None:
            cdiff += 1; print(f"  {name}：{'JS' if a is None else 'Mac'} 才有"); continue
        bad = []
        for f, tol in (("pos", 2e-3), ("front", 2e-3), ("up", 2e-3), ("target", 2e-3), ("fov", 1e-4), ("near", 2e-3), ("far", 2e-3),
                       ("fogStart", 2e-3), ("fogEnd", 2e-3), ("fogColor", 0), ("hdr", 0), ("bloom", 2e-3), ("vignette", 2e-3), ("vignettePower", 2e-3)):
            if not close(a.get(f), b.get(f), tol):
                bad.append(f"{f} Mac={a.get(f)} JS={b.get(f)}")
        ha = {x for x in a.get("hidden", []) if not skipped(x)}
        hb = {x for x in b.get("hidden", []) if not skipped(x)}
        if ha != hb:
            bad.append(f"被藏的節點 Mac 多 {len(ha - hb)}（例 {sorted(ha - hb)[:3]}）、JS 多 {len(hb - ha)}（例 {sorted(hb - ha)[:3]}）")
        if bad:
            cdiff += 1
            print(f"  {name}：" + "；".join(bad))
    total += cdiff

    ea, eb = M.get("env", {}), J.get("env", {})
    if ea != eb:
        total += 1
        print(f"== 環境：Mac {ea}  JS {eb}")

    print(f"== 總差異數 {total}")
    if opt("--json"):
        json.dump({"total": total, **{k: v for k, v in report.items()}}, open(opt("--json"), "w"), ensure_ascii=False, indent=1)
    sys.exit(0 if total == 0 else 1)


if __name__ == "__main__":
    main()
