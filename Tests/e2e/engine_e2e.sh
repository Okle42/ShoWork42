#!/bin/zsh
# M1-3 e2e: showork emit → agent → glow state + geometry → clearing rules. Own socket, own windows.
set -u
ROOT=${0:A:h:h:h}
BIN=$ROOT/.build/debug
VERIFY=$ROOT/spikes/m0_glow/m0_verify
ST=$(mktemp -d /tmp/sw42-eng.XXXX)
export SHOWORK_SOCKET=$ST/agent.sock SHOWORK_STATUS_FILE=$ST/status.json
pass=0 fail=0
ok()  { (( pass++ )); print "ok   $*"; }
bad() { (( fail++ )); print "FAIL $*"; }

$BIN/ShoWorkAgent 2>$ST/agent.log &
AGENT=$!
cleanup() {
  kill $AGENT 2>/dev/null
  osascript -e 'tell application "Ghostty"
    set ids to id of (every window whose name contains "SW42G")
    repeat with i in ids
      close window (first window whose id is (contents of i))
    end repeat
  end tell' >/dev/null 2>&1
  rm -rf $ST
}
trap cleanup EXIT INT TERM
for _ in {1..30}; do [[ -S $SHOWORK_SOCKET ]] && break; sleep 0.1; done
[[ -S $SHOWORK_SOCKET ]] && ok "agent up" || { bad "agent did not start: $(cat $ST/agent.log)"; exit 1; }

osascript -e "tell application \"Ghostty\"
  set cfg to new surface configuration
  set command of cfg to \"/bin/zsh -c \\\"tty > $ST/tty; exec /bin/zsh -i\\\"\"
  new window with configuration cfg
end tell" >/dev/null
for _ in {1..25}; do [[ -s $ST/tty ]] && break; sleep 0.2; done
T=$(<$ST/tty); printf '\033]0;SW42G-engine\007' > $T; sleep 0.4
osascript -e 'tell application "System Events" to tell process "Ghostty"' -e 'set position of (first window whose name is "SW42G-engine") to {420, 220}' -e 'set size of (first window whose name is "SW42G-engine") to {720, 420}' -e 'end tell' >/dev/null

emit()   { $BIN/showork emit $1 --agent test --tty $T; sleep ${2:-0.8}; }
state()  { python3 -c "import json;d=json.load(open('$SHOWORK_STATUS_FILE'));print(d['glows'][0]['state'] if d['glows'] else 'none')" 2>/dev/null || print none; }
geom()   { rm -rf $ST/g; mkdir -p $ST/g
           python3 -c "import json;[open('$ST/g/glow-%d.json'%i,'w').write(json.dumps({k:g[k] for k in ('target','overlay','pad')})) for i,g in enumerate(json.load(open('$SHOWORK_STATUS_FILE'))['glows'])]"
           $VERIFY $ST/g > $ST/verify.out; local rc=$?; (( rc )) && cat $ST/verify.out; return $rc; }
away()   { osascript -e 'tell application "Finder" to activate' >/dev/null; sleep 0.8; }
look()   { osascript -e 'tell application "Ghostty" to activate' -e 'tell application "System Events" to tell process "Ghostty" to perform action "AXRaise" of (first window whose name is "SW42G-engine")' >/dev/null; sleep 1.0; }
expect() { local s=$(state); [[ $s == $2 ]] && ok "$1 → $s" || bad "$1 → $s (want $2)"; }

away
emit working;           expect "working (not looking)" working
geom && ok "purple glow geometry + stacking" || bad "purple glow geometry/stacking"
emit done;              expect "done while away" done
geom && ok "gold glow geometry + stacking" || bad "gold glow geometry/stacking"
look;                   expect "user looks at the window → gold cleared" none
emit working; emit done; expect "done while looking → no reminder" none
away; emit input;       expect "input → red" input
look;                   expect "looking does NOT clear red (AI is blocked on you)" input
emit working;           expect "AI resumes → purple" working
emit clear;             expect "clear → none" none

# key press inside the focused window clears gold (window already focused when done arrives
# counts as looking, so make it arrive while away, then come back and type)
away; emit done;        expect "done while away (2)" done
look;                   expect "focus clears it" none

# CLI latency with the agent up
python3 - <<EOF
import subprocess,time,statistics,os
ts=[]
for _ in range(20):
    s=time.perf_counter(); subprocess.run(["$BIN/showork","emit","working","--agent","test","--tty","$T"],stdin=subprocess.DEVNULL); ts.append((time.perf_counter()-s)*1000)
print("CLI_LATENCY median=%.1fms max=%.1fms" % (statistics.median(ts), max(ts)))
EOF
emit clear 0.5

print "RESULT pass=$pass fail=$fail"
