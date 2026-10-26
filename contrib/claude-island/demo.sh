#!/bin/bash
# 在自己的 Mac 上看動畫：編譯後依序跑 處理中 → 需要授權 → 處理中 → 完成（約 15 秒）
# 請看螢幕右上角；光暈會亮在目前最前面的終端機視窗上。
set -e
cd "$(dirname "$0")"
[ -x claude-island ] || swiftc -O -framework AppKit -framework SwiftUI island.swift -o claude-island
export ISLAND_SESSION=demo ISLAND_TTY= ISLAND_PID=0
echo '{"cwd":"/tmp/my-project"}' | ./claude-island run;  sleep 5
echo '{"cwd":"/tmp/my-project","message":"Claude needs your permission"}' | ./claude-island wait; sleep 4
./claude-island tick </dev/null; sleep 2
echo '{"cwd":"/tmp/my-project"}' | ./claude-island done
echo "完成的膠囊會一直留著：點它一下，或到選單列的 ● 選單「清除所有完成了」。"
