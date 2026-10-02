# ShoWork42

**A glow around your terminal window tells you what the AI inside is doing.**
Part of the **42 series** by [Okle42](https://github.com/Okle42) — follow for more AI tools that actually ship.

[繁體中文說明](README.zh-TW.md)

> [!WARNING]
> **Work in progress (M0 technical validation)**: not yet signed or notarized, no packaged installer, and behavior and settings may still change. Feel free to look around, try it out and report issues, but please don't rely on it for real work yet.

> The AI in your terminal is working, finished, or waiting for your answer — no need to switch over and check. The glow around the window tells you.

A macOS menu bar utility. Every terminal window running an AI agent (Claude Code, Codex, Gemini…) glows around its edges based on what the agent is doing right now:

| State | Color (default) | When it appears | When it goes away |
|---|---|---|---|
| Working | Purple · breathing | You send a prompt, a tool runs | Done, or waiting on you |
| Done | Green `#30D158` | The AI's turn ends | You **press a key or click** in that window |
| Needs your answer | Red | Permission prompt, question | The AI moves on |

When a window has several tabs, it shows whichever needs attention most: **red > green > purple**.

> Status: **work in progress**. M0 (technical validation) is done; M1 (daily driver for Claude Code × Ghostty) is underway. Code signing, notarization and full-matrix testing come before a release.

## Features

- **Three terminals**: Ghostty (including tmux), Terminal.app and iTerm2 — background tabs, multiple windows and multiple tmux clients are all matched correctly.
- **Glow**: click-through; follows the window as it moves, resizes and gets stacked; in full screen it switches to a thin 3pt line along the screen edge; no animation when Reduce Motion is on.
- **Multiple displays**: the glow follows windows across displays; auto-layout runs per display; larger displays get a proportionally scaled layout (tested on an external TV).
- **Settings window** (menu bar → Settings… ⌘,): the Glow page shows live previews of all three states side by side. Each has its own on/off toggle, color, six glow styles (breathe / orbit / ripple / haze / sparkle / aurora), brightness, width and speed, all previewed live.
- **Auto-layout** (optional): rearranges terminal windows whenever their count changes; ⌃⌥L to arrange now. Each count from 1 to 11 windows has a fixed layout; with 6 or more, windows overlap and the stacking order is tidied up automatically.
- **Menu bar overview**: a ● count per state; click an entry to jump straight to that window.
- **Fallback detection**: for older Claude sessions that aren't sending hooks, the state is read from the spinner in the Ghostty tab title.

## Design principles (hard rules)

1. **Never slow down the AI**: `showork emit`, called from hooks, takes at most 200 ms, always exits 0 and never reads stdin.
2. **No network**: local Unix socket only (permissions 0600).
3. **Play nicely with other tools' hooks**: install only *merges* its own hook groups and backs up before writing; uninstall removes only its own.
4. **The glow is always click-through** — it never steals focus and has no Dock icon.
5. **Never touch your window titles**: Ghostty matching uses an OSC 7 probe and restores the original cwd afterwards.

## Install

Requirements: macOS 14+, Swift 6 toolchain.

```sh
python3 scripts/showork_install.py install     # build release, sign, install LaunchAgent, merge Claude hooks
python3 scripts/showork_install.py status
python3 scripts/showork_install.py uninstall   # remove the agent and its own hooks
```

- On first launch it asks for Accessibility permission (System Settings → Privacy & Security → Accessibility → ShoWorkAgent); once granted, it restarts and takes over automatically.
- If you have an Apple Development / Developer ID certificate it signs with that, so the permission survives rebuilds; otherwise it signs ad-hoc.
- To just print the hooks snippet without installing: `python3 adapters/claude/hooks.py /path/to/showork`

## Development

```sh
swift build
swift test                       # ShoWorkCore unit tests (state machine, layout geometry, title signals)
Tests/e2e/resolver_e2e.sh        # tty → window matching (opens test terminal windows)
Tests/e2e/engine_e2e.sh          # events → glow
Tests/e2e/layout_e2e.sh          # layout (allowlist-protected, see below)
```

⚠ The e2e tests open and close real windows. Layout tests must always pass the `SHOWORK_ONLY_WIDS` allowlist; if any window outside the list shows up on screen, the whole run aborts. To verify the safeguard itself, add `SHOWORK_ARRANGE_NOOP=1` (checks only, moves nothing).

Debugging: after `SHOWORK_DEBUG=1 python3 scripts/showork_install.py install`, `~/Library/Application Support/ShoWork42/agent.log` records EVT / ACK / REAP / RESTORE / TITLE.

## Docs

The docs are currently in Traditional Chinese.

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — architecture, data flow, module responsibilities, known pitfalls
- [docs/M0-進度.md](docs/M0-進度.md) — technical validation log (matching approach, stress test numbers)
- [docs/M1-計畫.md](docs/M1-計畫.md) · [docs/M1b-排版計畫.md](docs/M1b-排版計畫.md) — current milestone
- [docs/decisions/](docs/decisions/) — decision boards (HTML) and answers used to settle the spec

## Contrib

- [contrib/claude-island/](contrib/claude-island/README.md) — Claude Island: a single-file Swift utility inspired by ShoWork42, with a Dynamic Island–style pill in the top-right corner plus a thin glowing strip on terminal windows. Self-contained; it doesn't change ShoWork42 itself. Contributed by @gamebear61211-lgtm.

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| M0 | Window matching + glow follow/stacking (three terminals, tmux, Spaces, full screen) | ✅ |
| M1 | Claude Code × Ghostty: a full day of daily use with zero false alerts; layout; settings window | In progress |
| M2 | Codex, Gemini, generic fallback (watching output activity) | |
| M3 | Terminal.app and iTerm2 daily-use acceptance | |
| M4 | Packaging, signing + notarization, README GIF, release | |

## License

[MIT](LICENSE) © 2026 Okle42

`contrib/claude-island` © 2026 [@gamebear61211-lgtm](https://github.com/gamebear61211-lgtm), also MIT.
