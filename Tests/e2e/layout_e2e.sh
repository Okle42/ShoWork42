#!/bin/zsh
# M1b e2e: arrange 1…11 terminal windows (Ghostty + Terminal + iTerm2 mixed) on an EMPTY Space and
# compare real frames with the plan.
#
# SAFETY (after the 09-26 incidents, see memory feedback_排版測試不可搬使用者視窗):
#   • the user's terminal windows on ALL Spaces are snapshotted first (FORBID) and diffed at the end
#   • no "adopt unknown windows" logic anywhere; Terminal/iTerm2 are only used if they were NOT running
#   • before every arrange: every on-screen terminal window must be ours, otherwise ABORT the whole test
#   • the agent itself enforces SHOWORK_ONLY_WIDS (code-level whitelist) — belt and braces
set -u
ROOT=${0:A:h:h:h}
AG=$ROOT/.build/debug/ShoWorkAgent
WB=$ROOT/spikes/m0_glow/wbounds
ST=$(mktemp -d /tmp/sw42-lay.XXXX)
MAXN=${1:-11}
pass=0 fail=0
ok()  { (( pass++ )); print "ok   $*"; }
bad() { (( fail++ )); print "FAIL $*"; }
strings $AG | grep -q 'requires SHOWORK_ONLY_WIDS' || { print "ABORT: agent binary lacks the whitelist guard — rebuild first"; exit 1; }

running() { osascript -e "tell application \"System Events\" to (name of processes) contains \"$1\"" 2>/dev/null; }
TERM_WAS=$(running Terminal); ITERM_WAS=$(running iTerm2)

# FORBID: every terminal window on every Space, with full frames
cat > $ST/allwins.swift <<'EOF'
import CoreGraphics
let owners: Set<String> = ["Ghostty", "Terminal", "iTerm2", "終端機"]
for w in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [] {
  guard owners.contains(w[kCGWindowOwnerName as String] as? String ?? ""), (w[kCGWindowLayer as String] as? Int) == 0,
        let b = w[kCGWindowBounds as String] as? [String: Any], (b["Width"] as? Double ?? 0) > 200 else { continue }
  print(w[kCGWindowNumber as String]!, Int(b["X"] as! Double), Int(b["Y"] as! Double), Int(b["Width"] as! Double), Int(b["Height"] as! Double))
}
EOF
swiftc -O -o $ST/allwins $ST/allwins.swift 2>/dev/null || { print "ABORT: helper build failed"; exit 1; }
$ST/allwins | sort > $ST/forbid.before
typeset -a FORBID MINE
FORBID=($(awk '{print $1}' $ST/forbid.before))
print "   protecting ${#FORBID} existing terminal windows"

space() { osascript -e "tell application \"System Events\" to key code $1 using control down" >/dev/null; sleep 1.6; }
onscreen() { $AG --arrange-dry 2>/dev/null | awk 'NR>1{print $2}'; }

abort() { print "ABORT: $1"; exit 1; }
cleanup() {
  osascript -e 'tell application "Ghostty"
    set ids to id of (every window whose name starts with "SW42L")
    repeat with i in ids
      close window (first window whose id is (contents of i))
    end repeat
  end tell' >/dev/null 2>&1
  [[ $TERM_WAS == false ]] && osascript -e 'tell application id "com.apple.Terminal" to quit saving no' >/dev/null 2>&1
  [[ $ITERM_WAS == false ]] && osascript -e 'tell application id "com.googlecode.iterm2" to quit' >/dev/null 2>&1
  sleep 1.5
  # the user's windows must be exactly where they were
  $ST/allwins | sort > $ST/forbid.after
  local moved=$(join $ST/forbid.before $ST/forbid.after | awk '$2!=$6||$3!=$7||$4!=$8||$5!=$9')
  if [[ -z $moved ]]; then print "ok   none of your ${#FORBID} windows moved"; else print "FAIL your windows moved:"; print $moved; fi
  [[ -n ${BACK:-} ]] && space $BACK
  rm -rf $ST
}
trap cleanup EXIT INT TERM

# ── find an empty Space
BACK=123; space 124
if [[ -n $(onscreen) ]]; then space 123; space 123; BACK=124; [[ -z $(onscreen) ]] || abort "no empty Space found"; fi
ok "on an empty Space"

guard() {   # every on-screen terminal window must be ours
  local w
  for w in $(onscreen); do
    (( ${FORBID[(Ie)$w]} )) && abort "one of YOUR windows ($w) is on screen — macOS switched Spaces"
    (( ${MINE[(Ie)$w]} )) || abort "unknown window $w on screen"
  done
}

open_one() {   # Ghostty; #3 Terminal.app and #5 iTerm2 only if the test launches them itself
  local i=$1 f=$ST/tty$1 app=ghostty
  # Terminal/iTerm2 are NOT mixed in: macOS puts a background app's new windows on the Space it
  # already lives on, so they never appear on the empty test Space (M1b finding). Their AX
  # move/resize is covered by M0 ⑥⑦ (60 rounds each); the arranger code path is app-agnostic.
  [[ -n ${SW42_MIX_APPS:-} && $i == 3 && $TERM_WAS == false ]] && app=terminal
  [[ -n ${SW42_MIX_APPS:-} && $i == 5 && $ITERM_WAS == false ]] && app=iterm
  case $app in
    terminal) osascript -e "tell application id \"com.apple.Terminal\" to do script \"tty > $f\"" >/dev/null ;;
    iterm)    osascript -e "tell application id \"com.googlecode.iterm2\" to create window with default profile command \"/bin/zsh -c 'tty > $f; exec /bin/zsh -i'\"" >/dev/null ;;
    ghostty)  osascript -e "tell application \"Ghostty\"
                set cfg to new surface configuration
                set command of cfg to \"/bin/zsh -c \\\"tty > $f; exec /bin/zsh -i\\\"\"
                new window with configuration cfg
              end tell" >/dev/null ;;
  esac
  for _ in {1..30}; do [[ -s $f ]] && break; sleep 0.2; done
  printf '\033]0;SW42L-%d\007' $i > $(<$f); sleep 0.6
  case $app in      # these apps were NOT running before the test ⇒ every window they own is ours
    terminal) MINE+=($(osascript -e 'tell application id "com.apple.Terminal" to get id of windows' | tr -d ',')) ;;
    iterm)    MINE+=($(osascript -e 'tell application id "com.googlecode.iterm2" to get id of windows' | tr -d ',')) ;;
    ghostty)  local w=$($AG --resolve $(<$f) 2>/dev/null | awk '{print $3; exit}'); [[ -n $w ]] && MINE+=$w ;;
  esac
}

check() {   # check <label> [style]
  guard
  SHOWORK_ONLY_WIDS=${(j:,:)MINE} $AG --arrange-once ${2:-columns} > $ST/plan 2>$ST/err; local rc=$?
  (( rc == 0 )) || { bad "$1: agent refused/failed rc=$rc $(<$ST/err)"; return; }
  local want=${1#n=}; want=${want%% *}
  local got=$(wc -l < $ST/plan | tr -d ' ')
  (( got == want )) || { bad "$1: arranged $got windows, expected $want (some test windows are not on this Space)"; return; }
  sleep 1.0
  [[ -n ${SW42_SHOTS:-} ]] && screencapture -x "$SW42_SHOTS/${1// /_}.png"
  $WB $(awk '{print $1}' $ST/plan) > $ST/actual
  python3 - $ST/plan $ST/actual <<'PY' && ok "$1" || bad "$1"
import sys
plan = {l.split()[0]: list(map(int, l.split()[1:])) for l in open(sys.argv[1]) if l.strip()}
act = {l.split()[0]: l.split()[1:] for l in open(sys.argv[2]) if l.strip()}
errs = []
for wid, (x, y, w, h) in plan.items():
    a = act.get(wid, ["gone"])
    if a[0] == "gone": errs.append(f"{wid} gone"); continue
    X, Y, W, H = map(int, a)
    if abs(X-x) > 3 or abs(Y-y) > 3 or not (-25 <= W-w <= 3) or not (-25 <= H-h <= 3):
        errs.append(f"{wid} want {x},{y} {w}x{h} got {X},{Y} {W}x{H}")
if not plan: errs.append("empty plan")
if errs: print("   ", "; ".join(errs)); sys.exit(1)
PY
}

for n in $(seq 1 $MAXN); do
  open_one $n
  if (( n == 4 )); then check "n=4 columns" columns; check "n=4 grid" grid; check "n=4 back to columns" columns
  else check "n=$n"; fi
done
# ── restacking (Kang 09-26): arrange 11, click a TOP window, then a BOTTOM window ⇒
#    bottom-clicked window on top; other rows back to top < middle < bottom
if (( MAXN >= 11 )); then
  cat > $ST/zorder.swift <<'EOF2'
import CoreGraphics
for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] where (w[kCGWindowLayer as String] as? Int) == 0 { print(w[kCGWindowNumber as String]!) }
EOF2
  swiftc -O -o $ST/zorder $ST/zorder.swift 2>/dev/null
  guard
  SHOWORK_ONLY_WIDS=${(j:,:)MINE} $AG --arrange-watch > $ST/watch.plan 2>$ST/watch.err &
  WPID=$!
  sleep 2.5
  typeset -a P Y G
  P=($(sed -n '1,4p' $ST/watch.plan | awk '{print $1}')); Y=($(sed -n '5,7p' $ST/watch.plan | awk '{print $1}')); G=($(sed -n '8,11p' $ST/watch.plan | awk '{print $1}'))
  GP=$(osascript -e 'tell application "System Events" to get unix id of process "Ghostty"')
  $ROOT/spikes/m0_glow/axraise $GP $P[2]; sleep 1.5
  [[ -n ${SW42_SHOTS:-} ]] && screencapture -x "$SW42_SHOTS/restack_1_click_top.png"
  $ST/zorder > $ST/z1
  python3 - $ST/z1 "${(j:,:)P}" "${(j:,:)Y}" "${(j:,:)G}" <<'PY' && ok "restack: clicked TOP window on top; then middle, then bottom" || bad "restack after clicking top"
import sys
z=[l.strip() for l in open(sys.argv[1]) if l.strip()]
P,Y,G=[a.split(',') for a in sys.argv[2:5]]
idx={w:i for i,w in enumerate(z)}
mine=[w for w in z if w in P+Y+G]
ok = mine and mine[0]==P[1]
ok = ok and max(idx[w] for w in P) < min(idx[w] for w in Y) and max(idx[w] for w in Y) < min(idx[w] for w in G)
if not ok: print("    front→back:", ["P" if w in P else "Y" if w in Y else "G" for w in mine], "first:", mine[:1], "want", P[1])
sys.exit(0 if ok else 1)
PY
  $ROOT/spikes/m0_glow/axraise $GP $G[3]; sleep 1.5
  [[ -n ${SW42_SHOTS:-} ]] && screencapture -x "$SW42_SHOTS/restack_2_click_bottom.png"
  $ST/zorder > $ST/z
  kill $WPID 2>/dev/null
  python3 - $ST/z "${(j:,:)P}" "${(j:,:)Y}" "${(j:,:)G}" <<'PY' && ok "restack: clicked bottom window on top; bottom > middle > top" || bad "restack order"
import sys
z=[l.strip() for l in open(sys.argv[1]) if l.strip()]
P,Y,G=[a.split(',') for a in sys.argv[2:5]]
idx={w:i for i,w in enumerate(z)}                 # 0 = frontmost
mine=[w for w in z if w in P+Y+G]
ok = mine and mine[0]==G[2]
ok = ok and max(idx[w] for w in G) < min(idx[w] for w in Y) and max(idx[w] for w in Y) < min(idx[w] for w in P)
if not ok: print("    front→back:", ["P" if w in P else "Y" if w in Y else "G" for w in mine], "first:", mine[:1], "want", G[2])
sys.exit(0 if ok else 1)
PY
fi
print "RESULT pass=$pass fail=$fail"
