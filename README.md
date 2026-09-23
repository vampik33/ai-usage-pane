# ai-usage-pane

A tiny terminal pane that shows your **Claude Code** and **Codex CLI** subscription
usage — 5-hour and weekly windows, with countdowns to reset. Built to sit at the
bottom of a [Warp](https://www.warp.dev/) tab, but works in any terminal.

```
Claude 5h ░░░░░░░░░░   2% ↻2h40m  │ wk ███░░░░░░░  33% ↻5d11h
Codex  5h ░░░░░░░░░░   0% ↻4h59m  │ wk ████████░░  79% ↻3d14h
[⟳ refresh]  r refresh · q quit  updated just now
```

## How it works

- Reads the OAuth tokens that the CLIs already store (`~/.claude/.credentials.json`,
  `~/.codex/auth.json`) and queries the same usage endpoints they use.
  Tokens are never refreshed by this tool — when one expires, the row shows
  `stale: ⚠ token expired` until you open `claude` / `codex` again.
- Auto-refreshes every 5 minutes; click `[⟳ refresh]` or press `r` to fetch now
  (at most once per 30 s).
- All panes share one cache (`$XDG_CACHE_HOME/ai-usage-pane.json`, default
  `~/.cache`), so many open tabs still fetch once per 5 minutes.

> The usage endpoints are undocumented and may change without notice.

## Install

```sh
cargo install --git https://github.com/vampik33/ai-usage-pane
```

## Warp setup

Save as `~/.local/share/warp-terminal/tab_configs/ai_usage.toml` (Linux), then pick
it from the **+** menu (hover → **Make default** to use it for every new tab):

```toml
name = "AI usage"

[[panes]]
id = "root"
split = "vertical"
children = ["main", "usage"]

[[panes]]
id = "main"
type = "terminal"
is_focused = true

[[panes]]
id = "usage"
type = "terminal"
commands = ["ai-usage-pane"]

[params]
```

Warp splits panes equally, so drag the divider down until the usage pane is ~3 lines tall.
