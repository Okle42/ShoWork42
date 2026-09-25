#!/bin/zsh
# M1b e2e: arrange 1…11 terminal windows (Ghostty + Terminal + iTerm2 mixed) and check the real
# frames against the plan. Runs on an EMPTY Space and refuses to arrange if any window that the
# test did not open is on screen — it must never move the user's own windows.
set -u
ROOT=${0:A:h:h:h}
AG=$ROOT/.build/debug/ShoWorkAgent
AXT=$ROOT/spikes/m0_glow/axtitle
ST=$(mktemp -d /tmp/sw42-lay.XXXX)
MAXN=${1:-11}
pass=0 fail=0
ok()  { (( pass++ )); print "ok   $*"; }
bad() { (( fail++ )); print "FAIL $*"; }
running() { osascript -e "tell application \"System Events\" to (name of processes) contains \"$1\"" 2>/dev/null; }
TERM_WAS=$(running Terminal); ITERM_WAS=$(running iTerm2)
typeset -a MINE      # wids we opened
space() { osascript -e "tell application \"System Events\" to key code $1 using control down" >/dev/null; sleep 1.6; }
count_now() { $AG --arrange-dry 2>/dev/null | sed -n 's/.*windows \([0-9]*\).*/\1/p'; }
foreign() {          # any on-screen terminal window that is not ours?
  local w
  for w in $($AG --arrange-dry 2>/dev/null | awk 'NR>1{print $2}'); do (( ${MINE[(Ie)$w]} )) || { print $w; return 0; }; done
  return 1
}

# ── find an empty Space (right, else left)
BACK=123
space 124
if (( $(count_now) != 0 )); then space 123; space 123; BACK=124
  if (( $(count_now) != 0 )); then space 124; print "ABORT: no empty Space found — refusing to touch your windows"; exit 1; fi
fi
ok "on an empty Space"

cleanup() {
  osascript -e 'tell application "Ghostty"
    set ids to id of (every window whose name starts with "SW42L")
    repeat with i in ids
      close window (first window whose id is (contents of i))
    end repeat
  end tell' >/dev/null 2>&1
  [[ $TERM_WAS == false ]] && osascript -e 'tell application id "com.apple.Terminal" to close every window saving no' >/dev/null 2>&1
  [[ $ITERM_WAS == false ]] && osascript -e 'tell application id "com.googlecode.iterm2" to close every window' >/dev/null 2>&1
  for id in ${MINE[@]}; do
    osascript -e "tell application id \"com.apple.Terminal\" to close (every window whose id is $id) saving no" >/dev/null 2>&1
    osascript -e "tell application id \"com.googlecode.iterm2\" to close (every window whose id is $id)" >/dev/null 2>&1
  done
  sleep 1
  [[ $TERM_WAS == false ]] && osascript -e 'tell application id "com.apple.Terminal" to quit' >/dev/null 2>&1
  [[ $ITERM_WAS == false ]] && osascript -e 'tell application id "com.googlecode.iterm2" to quit' >/dev/null 2>&1
  space $BACK
  rm -rf $ST
}
trap cleanup EXIT INT TERM

open_one() {   # open_one <i> : Ghostty, except #3 Terminal.app and #5 iTerm2 (mixed apps)
  local i=$1 f=$ST/tty$1
  case $i in
    3) osascript -e "tell application id \"com.apple.Terminal\" to do script \"tty > $f\"" >/dev/null ;;
    5) osascript -e "tell application id \"com.googlecode.iterm2\" to create window with default profile command \"/bin/zsh -c 'tty > $f; exec /bin/zsh -i'\"" >/dev/null ;;
    *) osascript -e "tell application \"Ghostty\"
         set cfg to new surface configuration
         set command of cfg to \"/bin/zsh -c \\\"tty > $f; exec /bin/zsh -i\\\"\"
         new window with configuration cfg
       end tell" >/dev/null ;;
  esac
  for _ in {1..30}; do [[ -s $f ]] && break; sleep 0.2; done
  printf '\033]0;SW42L-%d\007' $i > $(<$f)
  sleep 0.6
  local w=$($AG --resolve $(<$f) 2>/dev/null | awk '{print $3; exit}')
  [[ -n $w ]] && MINE+=$w
  print "   opened #$i tty=$(<$f) wid=${w:-UNRESOLVED}" >> $ST/diag
  # a freshly launched Terminal/iTerm2 also opens its own default window here — ours too
  if [[ $i == 3 && $TERM_WAS == false ]] || [[ $i == 5 && $ITERM_WAS == false ]]; then
    for x in $($AG --arrange-dry 2>/dev/null | awk 'NR>1{print $2}'); do (( ${MINE[(Ie)$x]} )) || MINE+=$x; done
  fi
}

check_layout() {   # check_layout <label> [style]
  local f=$(foreign)
  if [[ -n $f ]]; then bad "$1: foreign window $f on screen — NOT arranging"; cat $ST/diag; $AG --arrange-dry | sed 's/^/   dry: /'; return; fi
  $AG --arrange-once ${2:-columns} > $ST/plan 2>/dev/null; sleep 1.0
  $ROOT/spikes/m0_glow/wbounds $(awk '{print $1}' $ST/plan) > $ST/actual
  if [[ -n ${SW42_SECOND_PASS:-} ]]; then
    print "   1st pass: $(paste -sd' ' $ST/actual)" >> $ST/diag
    $AG --arrange-once ${2:-columns} > /dev/null 2>&1; sleep 1.0
    $ROOT/spikes/m0_glow/wbounds $(awk '{print $1}' $ST/plan) > $ST/actual
  fi
  python3 - $ST/plan $ST/actual <<'PY' && ok "$1" || bad "$1"
import sys
plan = {l.split()[0]: list(map(int, l.split()[1:])) for l in open(sys.argv[1]) if l.strip()}
act = {l.split()[0]: l.split()[1:] for l in open(sys.argv[2]) if l.strip()}
errs = []
for wid, (x, y, w, h) in plan.items():
    a = act.get(wid, ["gone"])
    if a[0] == "gone": errs.append(f"{wid} gone"); continue
    X, Y, W, H = map(int, a)
    # origin exact (±3); size may shrink to the terminal's cell grid (≤25) but never grow (≤3)
    if abs(X-x) > 3 or abs(Y-y) > 3 or not (-25 <= W-w <= 3) or not (-25 <= H-h <= 3):
        errs.append(f"{wid} want {x},{y} {w}x{h} got {X},{Y} {W}x{H}")
if not plan: errs.append("empty plan")
if errs: print("   ", "; ".join(errs)); sys.exit(1)
PY
}

for n in $(seq 1 $MAXN); do
  open_one $n
  if (( n == 4 )); then check_layout "n=4 columns" columns; check_layout "n=4 grid" grid; check_layout "n=4 back to columns" columns
  else check_layout "n=$n"; fi
done
[[ -n ${SW42_SECOND_PASS:-} ]] && sed 's/^/   /' $ST/diag | grep -E '1st pass' | tail -3
print "RESULT pass=$pass fail=$fail"
