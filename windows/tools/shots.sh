#!/bin/bash
# Mac／JS 3D 同鏡頭各拍一張、左右並排（11-01 P0 量尺）。只在 Mac 上跑（要 swift、SceneKit、Google Chrome）。
#
#   windows/tools/shots.sh <輸出資料夾> [--kit] [--no-mac] [--dump]
#     預設：6 個鏡頭 × 日夜（Mac --office-bench city 1 ＋ JS bench.html），輸出 sbs-<day|night>-<鏡頭>.png
#     --kit     改拍地基小測試場景（Mac --office-bench kit），輸出 sbs-kit-<day|night>.png，並印亮度探針對照
#     --no-mac  不重跑 Mac（沿用資料夾裡已經有的 Mac 圖）
#     --dump    兩邊都出 dump，跑 scene_diff（城市：--skip 還沒搬的子樹交給呼叫者自己加）
#   環境變數 MAC_REPO＝Mac 版 worktree（預設 ~/github-repos/ShoWork42/.claude/worktrees/agent-ad77ee3f0de4c6495）
set -euo pipefail
OUT="${1:?用法：shots.sh <輸出資料夾> [--kit] [--no-mac] [--dump]}"; shift
KIT=0; MAC=1; DUMP=0
for a in "$@"; do case "$a" in --kit) KIT=1;; --no-mac) MAC=0;; --dump) DUMP=1;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
MAC_REPO="${MAC_REPO:-$HOME/github-repos/ShoWork42/.claude/worktrees/agent-ad77ee3f0de4c6495}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [ $MAC = 1 ]; then
  (cd "$MAC_REPO" && swift build >/dev/null)
  if [ $KIT = 1 ]; then
    (cd "$MAC_REPO" && SHOWORK_SCENE_DUMP="$OUT" .build/debug/ShoWorkAgent --office-bench kit | grep -E "shot|dump" || true)
  else
    if [ $DUMP = 1 ]; then export SHOWORK_SCENE_DUMP="$OUT"; fi
    (cd "$MAC_REPO" && SHOWORK_BENCH_DIR="$OUT" .build/debug/ShoWorkAgent --office-bench city 1 | grep -E "city shot|dump" || true)
    unset SHOWORK_SCENE_DUMP
  fi
fi

if [ $KIT = 1 ]; then
  node "$HERE/js_bench.mjs" --out "$OUT" --kit $([ $DUMP = 1 ] && echo --dump)
  for n in day night; do
    python3 "$HERE/pngkit.py" sbs "$OUT/mac-kit-$n.png" "$OUT/js-kit-$n.png" "$OUT/sbs-kit-$n.png"
    if [ -f "$OUT/mac-kit-$n.json" ]; then
      echo "== 亮度探針（$n）"; python3 "$HERE/pngkit.py" probe "$OUT/mac-kit-$n.json" "$OUT/mac-kit-$n.png" "$OUT/js-kit-$n.png"
    fi
    if [ $DUMP = 1 ]; then echo "== scene_diff kit $n"; python3 "$HERE/scene_diff.py" "$OUT/mac-kit-$n.json" "$OUT/js-kit-$n.json" --skip basement || true; fi
  done
else
  node "$HERE/js_bench.mjs" --out "$OUT" --all $([ $DUMP = 1 ] && echo --dump)
  for n in day night; do
    for c in default overview top branch airship port; do
      python3 "$HERE/pngkit.py" sbs "$OUT/$n-$c.png" "$OUT/js-$n-$c.png" "$OUT/sbs-$n-$c.png"
    done
    if [ $DUMP = 1 ]; then echo "== scene_diff $n"; python3 "$HERE/scene_diff.py" "$OUT/mac-scene-$n.json" "$OUT/js-scene-$n.json" --top 12 || true; fi
  done
fi
echo "完成：$OUT"
