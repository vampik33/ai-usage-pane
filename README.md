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

Warp restores each pane's size and working directory after a restart, but not the
command running in it. So the pane is tied to a marker directory, and a fish hook
starts the app when a shell arrives there:

```sh
mkdir -p ~/.local/share/ai-usage-pane
cp contrib/ai-usage-pane.fish ~/.config/fish/conf.d/
```

Then in any tab, split the pane down and run `aiu` in the new pane. Resize it to
~3 lines; Warp remembers the size across restarts and the hook restarts the app.
Quitting with `q` leaves a normal prompt; run `aiu` again to bring it back.
