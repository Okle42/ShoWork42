#!/bin/zsh
# M1-2 e2e: ShoWorkAgent --resolve vs ground truth (the AX title of the resolved window must
# carry the label we printed into that window's selected tab). Opens only its own windows.
set -u
ROOT=${0:A:h:h:h}
AGENT=$ROOT/.build/debug/ShoWorkAgent
AXT=$ROOT/spikes/m0_glow/axtitle
AXR=$ROOT/spikes/m0_glow/axraise
ST=$(mktemp -d /tmp/sw42-e2e.XXXX)
pass=0 fail=0
ok()   { (( pass++ )); print "ok   $*"; }
bad()  { (( fail++ )); print "FAIL $*"; }
pidof() { osascript -e "tell application \"System Events\" to get unix id of process \"$1\"" 2>/dev/null; }
running() { osascript -e "tell application \"System Events\" to (name of processes) contains \"$1\"" 2>/dev/null; }
label() { printf '\033]0;%s\007' $2 > $1; }

check() {   # check <name> <tty> <proc> <expected label in window title>
  local out wid title
  out=$($AGENT --resolve $2 2>/dev/null | head -1); wid=${${(s: :)out}[3]:-}
  [[ $3 == iTerm2 && -n $wid ]] && $AXR $(pidof iTerm2) $wid   # iTerm2 applies titles only to the key window
  for _ in {1..10}; do title=$($AXT $(pidof $3) ${wid:-0} 2>/dev/null); [[ $title == *$4* ]] && break; sleep 0.2; done
  if [[ -n $wid && $title == *$4* ]]; then ok "$1 → wid $wid ($title)"; else bad "$1 → '$out' title='$title' want *$4*"; fi
}
waittty() { for _ in {1..25}; do [[ -s $1 ]] && break; sleep 0.2; done; cat $1; }
gcfg() { print -r -- "set cfg to new surface configuration
  set command of cfg to \"/bin/zsh -c \\\"tty > $1; exec ${2:-/bin/zsh -i}\\\"\""; }

TERM_WAS=$(running Terminal); ITERM_WAS=$(running iTerm2)

# ── Ghostty: single tab, and a two-tab window (background tab must resolve too)
osascript -e "tell application \"Ghostty\"
  $(gcfg $ST/g1)
  new window with configuration cfg
  $(gcfg $ST/g2a)
  set w to new window with configuration cfg
  $(gcfg $ST/g2b)
  new tab in w with configuration cfg
end tell" >/dev/null
G1=$(waittty $ST/g1); G2A=$(waittty $ST/g2a); G2B=$(waittty $ST/g2b)
label $G1 SW42E-g1; label $G2A SW42E-g2a; label $G2B SW42E-g2b; sleep 0.5
check "ghostty single tab" $G1 Ghostty SW42E-g1
check "ghostty selected tab" $G2B Ghostty SW42E-g2b
check "ghostty BACKGROUND tab" $G2A Ghostty SW42E-g2b      # same window; window title = selected tab

# ── tmux (isolated server)
osascript -e "tell application \"Ghostty\"
  $(gcfg $ST/tc "/opt/homebrew/bin/tmux -L sw42e2e new-session -s e2e")
  new window with configuration cfg
end tell" >/dev/null
TC=$(waittty $ST/tc); sleep 1.2
PANE=$(tmux -L sw42e2e list-panes -a -F '#{pane_tty}' | head -1)
label $TC SW42E-tmux; sleep 0.4
check "tmux pane $PANE" $PANE Ghostty SW42E-tmux

# ── Terminal.app
osascript -e "tell application id \"com.apple.Terminal\" to do script \"tty > $ST/t1\"" >/dev/null
T1=$(waittty $ST/t1); label $T1 SW42E-term; sleep 0.5
check "Terminal.app" $T1 Terminal SW42E-term

# ── iTerm2
osascript -e "tell application id \"com.googlecode.iterm2\" to create window with default profile command \"/bin/zsh -c 'tty > $ST/i1; exec /bin/zsh -i'\"" >/dev/null
I1=$(waittty $ST/i1); label $I1 SW42E-iterm; sleep 0.5
check "iTerm2" $I1 iTerm2 SW42E-iterm

# ── negatives: detached tmux, and a tty nobody shows
tmux -L sw42e2e detach-client -s e2e 2>/dev/null; sleep 0.8
if $AGENT --resolve $PANE >/dev/null 2>&1; then bad "detached tmux should resolve to nothing"; else ok "detached tmux → none"; fi
if $AGENT --resolve /dev/ttys999 >/dev/null 2>&1; then bad "bogus tty should resolve to nothing"; else ok "bogus tty → none"; fi

# ── cleanup: only our windows; quit apps only if we launched them AND nothing else is open
tmux -L sw42e2e kill-server 2>/dev/null
osascript -e 'tell application "Ghostty"
  set ids to id of (every window whose name contains "SW42E")
  repeat with i in ids
    close window (first window whose id is (contents of i))
  end repeat
end tell' >/dev/null 2>&1
TWID=$($AGENT --resolve $T1 2>/dev/null | awk '{print $3}')
[[ -n $TWID ]] && osascript -e "tell application id \"com.apple.Terminal\" to close (first window whose id is $TWID) saving no" >/dev/null 2>&1
# a Terminal/iTerm2 we launched opens a default window of its own; it is ours to close
if [[ $TERM_WAS == false ]]; then osascript -e 'tell application id "com.apple.Terminal" to close every window saving no' >/dev/null 2>&1; fi
IWID=$(osascript -e "tell application id \"com.googlecode.iterm2\"
  repeat with w in windows
    repeat with tb in tabs of w
      repeat with s in sessions of tb
        if tty of s is \"$I1\" then return id of w
      end repeat
    end repeat
  end repeat
end tell" 2>/dev/null)
[[ -n $IWID ]] && osascript -e "tell application id \"com.googlecode.iterm2\" to close (first window whose id is $IWID)" >/dev/null 2>&1
sleep 1
[[ $ITERM_WAS == false ]] && osascript -e 'tell application id "com.googlecode.iterm2" to close every window' >/dev/null 2>&1
sleep 1
[[ $TERM_WAS == false ]] && [[ $(osascript -e 'tell application id "com.apple.Terminal" to count windows' 2>/dev/null) == 0 ]] && osascript -e 'tell application id "com.apple.Terminal" to quit'
[[ $ITERM_WAS == false ]] && [[ $(osascript -e 'tell application id "com.googlecode.iterm2" to count windows' 2>/dev/null) == 0 ]] && osascript -e 'tell application id "com.googlecode.iterm2" to quit'
sleep 1
# leftovers are a test failure, not a shrug
left=$(osascript -e 'tell application "Ghostty" to count (every window whose name contains "SW42E")')
if (( left == 0 )); then ok "cleanup: no Ghostty leftovers"; else bad "cleanup: $left Ghostty windows left"; fi
for a in Terminal iTerm2; do
  was=$([[ $a == Terminal ]] && print $TERM_WAS || print $ITERM_WAS)
  if [[ $was == false && $(running $a) == true ]]; then bad "cleanup: $a still running"; else ok "cleanup: $a restored"; fi
done
rm -rf $ST
print "RESULT pass=$pass fail=$fail"
