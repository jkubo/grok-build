# jkubo fork of grok-build

Personal fork of [`xai-org/grok-build`](https://github.com/xai-org/grok-build).
Upstream **does not accept external PRs** (`CONTRIBUTING.md`). This tree is
for local builds and the two session-title gaps Claude Code already has:

1. **`grok sessions rename <id> <title>`**: persist a manual title (or
   `--reset-to-auto`) the same way `x.ai/session/rename` does on disk.
2. **Hook `sessionTitle` + `terminalSequence`**: Claude-shaped
   `hookSpecificOutput` so `/autoname` can live-update the TUI and tab
   title without writing `/dev/tty`. `--auto` stays unpin; it is **not**
   an invent verb.

Do not open a PR against `xai-org/grok-build`. There is no public issue
tracker on the upstream repo either.

## Branches

| Branch | Meaning |
|--------|---------|
| `main` | Exact mirror of `xai-org/grok-build` `main`. No fork delta. |
| `jkubo` | Default. Latest upstream **plus** the session-title patch and this tooling. |

Product delta (replayable if rebase conflicts): `fork/patches/` listed in
`fork/series`.

## Keep current

```sh
./scripts/sync-upstream.sh                 # fetch + rebase onto upstream/main
./scripts/sync-upstream.sh --push          # also update origin/jkubo + origin/main
./scripts/sync-upstream.sh --build --install
```

Sync requires Python 3 for batched raw file checks. Before fetch, files and
stage-zero index entries must match the captured commit, including file type,
executable mode and raw bytes read without clean filters. Unreadable files,
unstable reads and unsupported tracked types refuse. `--allow-dirty` does not
waive this raw ownership requirement. Fetch may refresh remote-tracking refs
and `FETCH_HEAD`; local named branches, index, raw files and operation data
must still match the pre-fetch snapshot before checkout.

Checkout, replay, tooling restoration and return checkouts compare raw files
and the complete index with committed input entries before adopting them.
Target paths occupied by independent ignored or untracked files refuse before
replacement. Post-checkout hook work hidden by a clean filter and `git add`
stays in place with a nonzero result and no push. These checks read raw bytes
in batches and leave the real hooks and filters enabled.

Native rebase/am can replace files before returning to the script. Replay
therefore refuses active tracked clean/smudge/process filters, working-tree
encodings, text/EOL normalization and ident expansion when preservation is
unproven. Effective native working-tree and index attributes are checked as well as
upstream and accepted replay history, including introduced paths and
attributes. This includes ignored/untracked per-directory `.gitattributes`
and native info/global precedence. The checks repeat after replay checkout
before native replay. Query errors or incomplete results retain state and
refuse. Absence in a committed tree does not establish local absence. A filter configured only
for paths outside this tracked participation set does not block replay.
Grok's current tree has no tracked attributes enabling these transforms;
operator attributes/config or later upstream attributes can make advancing
sync require manual recovery. A verified no-op needs no native replay and
can still proceed when its actual raw files/index match the commit.

Happy path is `git rebase` of the `jkubo` commits onto `upstream/main`.
Replay runs on a temporary branch and moves `jkubo` only after it succeeds.
For a simple rebase conflict, automatic abort and `git am --3way` fallback
require matching operation metadata, original branch tip, HEAD reflog,
complete staged entries/flags from an independent bare Git inspection
repo's three-tree result, and tracked file bytes from `AUTO_MERGE`. Full
operation files, names, types and modes, including todo instructions, must
match a native rebase reconstructed from committed history in that separate
inspection repo. The inspection replay must reach the same HEAD; it uses
the current generated committer timestamp to reproduce commit IDs. Earlier
differing timestamps, configured replay or more complex conflicts may be
unproven and require manual recovery. Edited or unproven conflict state stays on
the named replay branch, with its files, index and operation for inspection.
The inspection repo uses an empty template, isolated inspection config,
and its own worktree, index and new object writes. It reads committed source
objects through alternates;
the real candidate's normal hooks and configuration remain unchanged.
An accepted fallback restores only fork-owned paths: `FORK.md`,
`scripts/sync-upstream.sh`, `scripts/install-sync-timer.sh`,
`scripts/test-sync-upstream.sh`, `fork/`, and
`.github/workflows/sync-upstream.yml`. Other workflows that arrived with
upstream stay. Failed or partial `git am` is conservatively retained on the
named replay branch, including files, index and any am operation. Creating
that branch does not authorize aborting hook-created staged work. Inspect
`git status` and the sync log before manually resolving or aborting it.
The existing fork and remote heads are not replaced by a failed am.
Tooling restoration failures likewise stop before fork replacement or push
and retain the restoration files and index for inspection.

Patch fallback refuses unpublished local fork commits instead of omitting
them. Resolve that conflict manually before retrying. Before an accepted
fallback, the complete original fork tip is retained on a local named
branch `jkubo-sync-original-*`, whose name and commit are printed in the
sync log. This includes published work outside the series and tooling
paths: those files remain available on the retained branch, while the
fallback fork contains the recorded product patches and restored tooling.
The retained original branch is not pushed or deleted by the script.
Replacing the fork requires an atomic local ref update from the captured
pre-replay tip. If another local actor moved that ref, the script keeps
both its current tip and the replay branch, exits nonzero and does not
push. Checkout after a successful update does not force files or refs.

After fetch succeeds, and before checkout, replay, or any move of `main`:

- Fetched `origin/jkubo` must already be an ancestor of local `jkubo`
  (equal or local-ahead). If the remote fork is ahead or diverged, the
  script refuses in the default pull mode and with `--no-pull-origin`.
  It does not adopt that history and it does not replace it. Reconcile
  the reviewed remote history, then retry.
- Fetched `origin/main` must be an ancestor of the upstream commit this
  run would mirror. Remote mirror commits that upstream does not contain
  are refused instead of discarded.
- Local `main`, when the branch already exists, must be an ancestor of
  that same upstream commit. Equal and behind are accepted. Ahead or
  diverged local `main` is unpublished work and is refused. The script
  does not force-reset it, stash it, or hide it on a temporary branch.

An origin fetch failure stops the run before those observed shas are used.
A history-guard refusal preserves local named branches, remote heads, index,
worktree and operation state. Fetched remote-tracking refs and `FETCH_HEAD`
are caches that may have changed. A later uncertain raw transition retains
the state reached by the actual hook or operation for inspection.

`main` moves to the fetched upstream commit only after a successful replay
or a verified no-op, and only when the checks above passed. A no-op (exit 0
and `changed=false`) requires both of these: upstream is already an ancestor
of `jkubo`, and `fork/patches/` reverse-applies on that tree.

Push sends `main` and `jkubo` as one atomic update. Each ref is leased with
`--force-with-lease=<branch>:<observed-sha>`, using the sha fetched at the
start of the run. A branch that was absent uses an empty expected sha, so
the update is allowed only when this run is creating it. Normal hooks run.
The sha reported for the test job is the fork oid captured for that push and
published to origin. If a hook then moves local `jkubo` to a new commit, that
commit stays on the local branch and is not the reported sha.
The push does not use a bare `--force` or `--no-verify`. If the remote
rejects either branch, or a hook rejects the push, neither remote ref is
published. A local replay that already succeeded stays local. A verified
no-op did not replay `jkubo`, so a rejected push does not move that branch
back: a hook commit created during the push, its files, and the index stay.
Failed replay cleanup deletes only disposable temporary refs this run
created and aborts rebase conflicts only after the checks above pass.
It retains detected uncertain rebase/am state and does not force a moved
`jkubo` back to the captured commit. These checks do not lock the working
copy against arbitrary concurrent writes. The script
exits nonzero and does not report a successful push. A local build or
install is left in place, and the process still exits nonzero.
If a normal hook adds commits to the temporary replay branch before a
failed replay, cleanup keeps that named branch and its checked-out files
and index. Its creation alone does not make those new commits disposable.
Temporary ref deletion checks the observed tip, so a later local ref move
prevents deletion.

Version stamp: `GROK_VERSION=<pager-bin-version>-jkubo` (e.g. `1.0.8-jkubo`).

After a **manual** conflict resolution, refresh the product patch:

```sh
git format-patch -1 <product-commit> --stdout > fork/patches/0001-sessions-rename-and-hook-title.patch
```

### Automation

- **GitHub Actions** (`.github/workflows/sync-upstream.yml`): daily rebase +
  push; the test job checks out the patched sha the sync step reports.
  Runs the rename/hook unit tests. Does not install on this machine.
  A failed run comments on the open issue titled `fork sync failed`
  (label `fork-sync`), or opens that issue when none is open.
  Generated tooling commits temporarily use author and committer
  `Jay Kubo <6161465+jkubo@users.noreply.github.com>`. Rebase and patch replay
  preserve input authors and use that canonical generated committer.
  Existing repository identity settings are left unchanged. Upstream
  history keeps its existing author and committer.
- **Local timer** (rebuilds `~/.local/bin/grok-jkubo` when HEAD moved):

```sh
./scripts/install-sync-timer.sh
```

A running TUI keeps the old ELF until you `/quit` and start `grok` again.
