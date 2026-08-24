# jkubo fork of grok-build

Personal fork of [`xai-org/grok-build`](https://github.com/xai-org/grok-build).
Upstream **does not accept external PRs** (`CONTRIBUTING.md`). This tree is
for local builds and the two session-title gaps Claude Code already has:

1. **`grok sessions rename <id> <title>`** — persist a manual title (or
   `--reset-to-auto`) the same way `x.ai/session/rename` does on disk.
2. **Hook `sessionTitle` + `terminalSequence`** — Claude-shaped
   `hookSpecificOutput` so `/autoname` can live-update the TUI and tab
   title without writing `/dev/tty`. `--auto` stays unpin; it is **not**
   an invent verb.

Do not open a PR against `xai-org/grok-build`. Rebase onto `upstream/main`
when pulling syncs.
