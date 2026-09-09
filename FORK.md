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

Do not open a PR against `xai-org/grok-build`. There is no public issue
tracker on the upstream repo either.

## Branches

| Branch | Meaning |
|--------|---------|
| `main` | Fast-forward mirror of `xai-org/grok-build` `main`. No fork delta. |
| `jkubo` | Default. Latest upstream **plus** the session-title patch and this tooling. |

Product delta (replayable if rebase conflicts): `fork/patches/` listed in
`fork/series`.

## Keep current

```sh
./scripts/sync-upstream.sh                 # fetch + rebase onto upstream/main
./scripts/sync-upstream.sh --push          # also update origin/jkubo + origin/main
./scripts/sync-upstream.sh --build --install
```

Happy path is `git rebase` of the `jkubo` commits onto `upstream/main`. If
that conflicts, the script `git am --3way`s `fork/patches/` and restores
this tooling. If both fail it aborts and leaves `jkubo` where it was.

Version stamp: `GROK_VERSION=<pager-bin-version>-jkubo` (e.g. `1.0.8-jkubo`).

After a **manual** conflict resolution, refresh the product patch:

```sh
git format-patch -1 <product-commit> --stdout > fork/patches/0001-sessions-rename-and-hook-title.patch
```

### Automation

- **GitHub Actions** (`.github/workflows/sync-upstream.yml`): daily rebase +
  push; runs the rename/hook unit tests. Does not install on this machine.
- **Local timer** (rebuilds `~/.local/bin/grok-jkubo` when HEAD moved):

```sh
./scripts/install-sync-timer.sh
```

A running TUI keeps the old ELF until you `/quit` and start `grok` again.
