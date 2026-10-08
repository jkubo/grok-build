#!/usr/bin/env bash
# Run scripts/sync-upstream.sh against disposable local Git remotes.
# The fixture executes a byte copy of this repo's script (cmp before each run).
# Nothing here pushes to a network remote.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_SYNC="$ROOT/scripts/sync-upstream.sh"
WF="$ROOT/.github/workflows/sync-upstream.yml"
PATCH="$ROOT/fork/patches/0001-sessions-rename-and-hook-title.patch"
UPSTREAM_PIN="2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf 'ok: %s\n' "$*"; }

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf 'FAIL: %s\n got: [%s]\n want: [%s]\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}

[[ -f "$REAL_SYNC" ]] || fail "missing $REAL_SYNC"
[[ -f "$WF" ]] || fail "missing $WF"
[[ -f "$PATCH" ]] || fail "missing $PATCH"

grep -F 'sha: ${{ steps.sync.outputs.sha }}' "$WF" >/dev/null \
  || fail "workflow does not export steps.sync.outputs.sha"
if grep -F 'fork sync failed on' "$WF"; then
  fail "workflow still creates a dated issue"
fi
grep -F 'title="fork sync failed"' "$WF" >/dev/null || fail "stable issue title missing"
grep -F '.github/workflows/sync-upstream.yml' "$REAL_SYNC" >/dev/null \
  || fail "selective workflow restore missing"
if grep -E '^[[:space:]]*\.github[[:space:]]*\\?$' "$REAL_SYNC"; then
  fail "sync script still checks out the whole .github tree"
fi
if grep -F -- '--no-verify' "$REAL_SYNC"; then
  fail "sync script bypasses hooks"
fi
if grep -F 'git fetch "$ORIGIN_REMOTE" --prune || true' "$REAL_SYNC"; then
  fail "origin fetch failure is ignored"
fi
if grep -E 'push_fork \|\|' "$REAL_SYNC"; then
  fail "push_fork is invoked in an OR list"
fi
grep -F -- '--atomic' "$REAL_SYNC" >/dev/null || fail "push is not atomic"
if grep -E -- '--force($|[^-=])' "$REAL_SYNC"; then
  fail "sync script uses a bare --force"
fi
if grep -F 'github-actions[bot]' "$WF"; then
  fail "workflow committer is the actions bot"
fi
if grep -F 'user.name "jkubo-sync' "$WF" "$REAL_SYNC"; then
  fail "identity still uses the jkubo-sync alias"
fi
if grep -F 'user.email "jkubo@users.noreply.github.com"' "$REAL_SYNC"; then
  fail "fallback email dropped the public numeric id"
fi
grep -F 'user.name "Jay Kubo"' "$WF" >/dev/null || fail "workflow name is not Jay Kubo"
grep -F '6161465+jkubo@users.noreply.github.com' "$WF" >/dev/null \
  || fail "workflow email is not the public alias"
grep -F 'GIT_AUTHOR_NAME="Jay Kubo"' "$REAL_SYNC" >/dev/null || fail "generated author is not Jay Kubo"
grep -F 'GIT_COMMITTER_NAME="Jay Kubo"' "$REAL_SYNC" >/dev/null || fail "generated committer is not Jay Kubo"
grep -F '6161465+jkubo@users.noreply.github.com' "$REAL_SYNC" >/dev/null \
  || fail "generated email is not the public alias"
grep -F 'refusing to discard unpublished mirror work' "$REAL_SYNC" >/dev/null \
  || fail "local mirror guard missing"
grep -F 'refusing to discard fetched mirror work' "$REAL_SYNC" >/dev/null \
  || fail "fetched mirror guard missing"
grep -F 'refusing to discard remote fork history' "$REAL_SYNC" >/dev/null \
  || fail "remote fork guard missing"
grep -F 'the reviewed remote history, then retry.' "$ROOT/FORK.md" >/dev/null \
  || fail "operator docs omit remote fork reconciliation"
grep -F 'diverged local `main` is unpublished work' "$ROOT/FORK.md" >/dev/null \
  || fail "operator docs omit the local mirror guard"
if grep -E 'diff --git a/(scripts/|\.github/|fork/)' "$PATCH"; then
  fail "product patch contains fork tooling"
fi
if grep -F 'Co-Authored-By:' "$PATCH"; then
  fail "product patch contains a Co-Authored-By trailer"
fi
if git -C "$ROOT" log "${UPSTREAM_PIN}..HEAD" --format='%B' | grep -F 'Co-Authored-By:'; then
  fail "candidate history contains a Co-Authored-By trailer"
fi
if git -C "$ROOT" log "${UPSTREAM_PIN}..HEAD" --format='%B' | grep -F $'\u2014'; then
  fail "candidate history contains an em dash"
fi
mapfile -t candidate_idents < <(git -C "$ROOT" log "${UPSTREAM_PIN}..HEAD" --format='%an <%ae>%n%cn <%ce>')
[[ ${#candidate_idents[@]} -gt 0 ]] || fail "no candidate commits after upstream"
for ident in "${candidate_idents[@]}"; do
  [[ "$ident" == "Jay Kubo <6161465+jkubo@users.noreply.github.com>" ]] \
    || fail "candidate author or committer is not the public alias: $ident"
done
candidate_count="$(git -C "$ROOT" rev-list --count "${UPSTREAM_PIN}..HEAD")"
[[ "$candidate_count" -eq 2 ]] || fail "expected 2 commits after upstream, got $candidate_count"
[[ "$(git -C "$ROOT" rev-parse 'HEAD^^')" == "$UPSTREAM_PIN" ]] \
  || fail "product parent is not ${UPSTREAM_PIN}"

PRISTINE=""
EXEC_DIR=""
SANDBOXES=()
CANONICAL_ID="Jay Kubo <6161465+jkubo@users.noreply.github.com>"
cleanup() {
  local d
  if [[ -n "$PRISTINE" ]]; then
    git -C "$ROOT" worktree remove --force "$PRISTINE" >/dev/null 2>&1 || rm -rf "$PRISTINE"
  fi
  if [[ -n "$EXEC_DIR" ]]; then
    git -C "$ROOT" worktree remove --force "$EXEC_DIR" >/dev/null 2>&1 || rm -rf "$EXEC_DIR"
  fi
  for d in "${SANDBOXES[@]+"${SANDBOXES[@]}"}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

PRISTINE="$(mktemp -d -t grok-pristine-XXXX)"
rmdir "$PRISTINE"
GIT_LFS_SKIP_SMUDGE=1 git -C "$ROOT" worktree add --detach "$PRISTINE" "$UPSTREAM_PIN" >/dev/null
git -C "$PRISTINE" apply --check "$PATCH" \
  || fail "patch does not strictly apply onto ${UPSTREAM_PIN}"
say "patch applies onto pristine ${UPSTREAM_PIN}"
git -C "$ROOT" apply --reverse --check "$PATCH" \
  || fail "patch does not reverse-apply onto HEAD $(git -C "$ROOT" rev-parse --short HEAD)"
say "patch reverse-applies onto HEAD $(git -C "$ROOT" rev-parse --short HEAD)"

assert_committed_executables() {
  local path mode rc
  for path in scripts/sync-upstream.sh scripts/install-sync-timer.sh scripts/test-sync-upstream.sh; do
    mode="$(git -C "$ROOT" ls-tree HEAD -- "$path" | awk '{print $1}')"
    [[ "$mode" == "100755" ]] || fail "$path committed mode is ${mode:-missing}, want 100755"
  done
  EXEC_DIR="$(mktemp -d -t grok-exec-XXXX)"
  rmdir "$EXEC_DIR"
  git -C "$ROOT" worktree add --detach "$EXEC_DIR" HEAD >/dev/null
  [[ -x "$EXEC_DIR/scripts/sync-upstream.sh" ]] || fail "checkout of sync script is not executable"
  [[ -x "$EXEC_DIR/scripts/install-sync-timer.sh" ]] || fail "checkout of install script is not executable"
  [[ -x "$EXEC_DIR/scripts/test-sync-upstream.sh" ]] || fail "checkout of test script is not executable"
  set +e
  ( cd "$EXEC_DIR" && ./scripts/sync-upstream.sh --help >/dev/null 2>&1 )
  rc=$?
  set -e
  [[ "$rc" -ne 126 ]] || fail "workflow direct script execution exits 126"
  [[ "$rc" -eq 0 ]] || fail "checked out sync script --help exited $rc"
  say "committed scripts are executable and direct execution does not exit 126"
}
assert_committed_executables

SB_ROOT=""
new_sandbox() {
  SB_ROOT="$(mktemp -d -t grok-sync-XXXX)"
  SANDBOXES+=("$SB_ROOT")
  git init --bare -q "$SB_ROOT/origin.git"
  git init --bare -q "$SB_ROOT/upstream.git"
  git init -q -b main "$SB_ROOT/work"
  git -C "$SB_ROOT/work" config user.name "Jay Kubo"
  git -C "$SB_ROOT/work" config user.email "6161465+jkubo@users.noreply.github.com"
  git -C "$SB_ROOT/work" config commit.gpgsign false
  git -C "$SB_ROOT/work" config core.hooksPath "$SB_ROOT/work/.git/hooks"
  git -C "$SB_ROOT/work" remote add origin "$SB_ROOT/origin.git"
  git -C "$SB_ROOT/work" remote add upstream "$SB_ROOT/upstream.git"
  mkdir -p "$SB_ROOT/work/.git/hooks"
}

install_hook() {
  local work="$1"
  cat >"$work/.git/hooks/pre-push" <<'EOF'
#!/bin/bash
if [[ -n "${HOOK_MARK:-}" ]]; then
  printf 'hooked\n' >>"$HOOK_MARK"
fi
if [[ -n "${SPOIL_ONCE:-}" && ! -f "$SPOIL_ONCE" && -n "${ORIGIN_BARE:-}" && -n "${SPOILER_SHA:-}" ]]; then
  : >"$SPOIL_ONCE"
  if ! git --git-dir="$ORIGIN_BARE" update-ref refs/heads/jkubo "$SPOILER_SHA"; then
    printf 'spoil-remote-failed\n' >>"${HOOK_MARK:-/dev/null}"
  fi
  if ! git update-ref refs/remotes/origin/jkubo "$SPOILER_SHA"; then
    printf 'spoil-tracking-failed\n' >>"${HOOK_MARK:-/dev/null}"
  fi
  printf 'spoiled\n' >>"${HOOK_MARK:-/dev/null}"
fi
exit 0
EOF
  chmod +x "$work/.git/hooks/pre-push"
}

# A normal pre-push hook. It runs after sync-upstream.sh has captured the
# fork oid, then points local jkubo at a new commit. It does not touch origin.
install_local_move_hook() {
  local work="$1"
  cat >"$work/.git/hooks/pre-push" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ -n "${HOOK_MARK:-}" ]]; then
  printf 'hooked\n' >>"$HOOK_MARK"
fi
if [[ -z "${LOCAL_MOVE_SHA:-}" || -z "${LOCAL_MOVE_PLANNED:-}" ]]; then
  exit 0
fi
if [[ -f "$LOCAL_MOVE_SHA" ]]; then
  exit 0
fi
planned="$(git rev-parse refs/heads/jkubo)"
planned_push=""
saw_update=0
# An up-to-date push runs this hook with empty stdin. A push that actually
# sends objects lists each ref. Both must exit 0 after the local move.
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  [[ -n "${line:-}" ]] || continue
  saw_update=1
  read -r local_ref local_sha remote_ref remote_sha <<<"$line"
  if [[ "${remote_ref:-}" == "refs/heads/jkubo" ]]; then
    planned_push="$local_sha"
  fi
done
if [[ "$saw_update" -eq 1 && -z "$planned_push" ]]; then
  printf 'no-planned-fork\n' >>"${HOOK_MARK:-/dev/null}"
  exit 1
fi
if [[ -n "$planned_push" && "$planned_push" != "$planned" ]]; then
  printf 'planned-mismatch push=%s local=%s\n' "$planned_push" "$planned" >>"${HOOK_MARK:-/dev/null}"
  exit 1
fi
nonce="${RANDOM}${RANDOM}$$"
new="$(git commit-tree "${planned}^{tree}" -p "$planned" -m "concurrent local work ${nonce}")"
git update-ref refs/heads/jkubo "$new"
printf '%s\n' "$planned" >"$LOCAL_MOVE_PLANNED"
printf '%s\n' "$new" >"$LOCAL_MOVE_SHA"
if [[ -n "${HOOK_MARK:-}" ]]; then
  if [[ "$saw_update" -eq 1 ]]; then
    printf 'updating\n' >>"$HOOK_MARK"
  else
    printf 'uptodate\n' >>"$HOOK_MARK"
  fi
  printf 'moved\n' >>"$HOOK_MARK"
fi
exit 0
EOF
  chmod +x "$work/.git/hooks/pre-push"
}

commit_tree() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

commit_as() {
  local work="$1" name="$2" email="$3" message="$4"
  git -C "$work" config user.name "$name"
  git -C "$work" config user.email "$email"
  commit_tree "$work" "$message"
}

isolate_identity() {
  git -C "$1" config --unset user.name || true
  git -C "$1" config --unset user.email || true
  SYNC_ISOLATE_IDENTITY=1
}

assert_commit_identity() {
  local work="$1" rev="$2" want_author="$3" label="$4"
  local author committer
  author="$(git -C "$work" log -1 --format='%an <%ae>' "$rev")"
  committer="$(git -C "$work" log -1 --format='%cn <%ce>' "$rev")"
  assert_eq "$author" "$want_author" "$label author"
  assert_eq "$committer" "$CANONICAL_ID" "$label committer"
}

seed_base() {
  local work="$1"
  mkdir -p "$work/crates/codegen/xai-grok-pager-bin" \
    "$work/scripts" "$work/.github/workflows" "$work/fork/patches"
  printf 'version = "9.9.9"\n' >"$work/crates/codegen/xai-grok-pager-bin/Cargo.toml"
  printf 'base-notes\n' >"$work/notes.txt"
  printf 'base\n' >"$work/README.md"
  commit_tree "$work" "base"
}

install_sync_bytes() {
  local work="$1" mode
  mode="$(git -C "$ROOT" ls-tree HEAD -- scripts/sync-upstream.sh | awk '{print $1}')"
  [[ "$mode" == "100755" ]] || fail "refusing to copy sync script with committed mode ${mode:-missing}"
  [[ -n "$EXEC_DIR" && -x "$EXEC_DIR/scripts/sync-upstream.sh" ]] \
    || fail "refusing to copy sync script before the executable checkout check"
  mkdir -p "$work/scripts"
  cp -a "$EXEC_DIR/scripts/sync-upstream.sh" "$work/scripts/sync-upstream.sh"
  [[ -x "$work/scripts/sync-upstream.sh" ]] || fail "copied sync script is not executable"
  cmp -s "$REAL_SYNC" "$work/scripts/sync-upstream.sh" \
    || fail "fixture script is not the real sync script"
}

write_tooling_files() {
  local work="$1"
  install_sync_bytes "$work"
  printf '#!/bin/bash\necho install\n' >"$work/scripts/install-sync-timer.sh"
  chmod +x "$work/scripts/install-sync-timer.sh"
  printf '#!/bin/bash\necho test-stub\n' >"$work/scripts/test-sync-upstream.sh"
  chmod +x "$work/scripts/test-sync-upstream.sh"
  mkdir -p "$work/.github/workflows" "$work/fork"
  cp "$WF" "$work/.github/workflows/sync-upstream.yml"
  printf '%s\n' '# series' '0001-sessions-rename-and-hook-title.patch' >"$work/fork/series"
  [[ -f "$work/fork/patches/0001-sessions-rename-and-hook-title.patch" ]] \
    || fail "fixture patch missing"
}

snapshot_product_patch() {
  local work="$1"
  mkdir -p "$work/fork/patches"
  git -C "$work" format-patch -1 --stdout HEAD \
    >"$work/fork/patches/0001-sessions-rename-and-hook-title.patch"
}

# Point main at base and jkubo at the current tip, then publish both remotes.
publish_fork_at_base() {
  local work="$1" base="$2" tip="$3"
  # main is checked out here, so move it only after switching to jkubo.
  if git -C "$work" show-ref --verify --quiet refs/heads/jkubo; then
    git -C "$work" branch -f jkubo "$tip"
  else
    git -C "$work" branch jkubo "$tip"
  fi
  git -C "$work" checkout -q jkubo
  git -C "$work" branch -f main "$base"
  git -C "$work" push -q origin "$base:refs/heads/main"
  git -C "$work" push -q origin "$tip:refs/heads/jkubo"
  git -C "$work" push -q upstream "$base:refs/heads/main"
}

SYNC_RC=0
run_sync() {
  local work="$1"
  shift
  cmp -s "$REAL_SYNC" "$work/scripts/sync-upstream.sh" \
    || fail "refusing to run a script that is not the real sync script"
  [[ -x "$work/scripts/sync-upstream.sh" ]] || fail "refusing to run a non-executable sync script"
  : >"$work/github-output"
  : >"$work/hook-mark"
  set +e
  (
    cd "$work"
    if [[ "${SYNC_ISOLATE_IDENTITY:-}" == "1" ]]; then
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_CONFIG_SYSTEM=/dev/null
    fi
    HOOK_MARK="$work/hook-mark" \
      GITHUB_OUTPUT="$work/github-output" \
      ./scripts/sync-upstream.sh "$@"
  ) >"$work/sync.out" 2>&1
  SYNC_RC=$?
  set -e
}

out_val() {
  local file="$1" key="$2" line
  line="$(grep "^${key}=" "$file" | tail -n1 || true)"
  printf '%s' "${line#"${key}="}"
}

show_sync() {
  printf '%s\n' '--- sync.out ---' >&2
  cat "$1/sync.out" >&2 || true
  printf '%s\n' '--- github-output ---' >&2
  cat "$1/github-output" >&2 || true
  printf '%s\n' '--- status ---' >&2
  git -C "$1" status --porcelain=v1 >&2 || true
  if [[ -f "$1/hook-mark" ]]; then
    printf '%s\n' '--- hook-mark ---' >&2
    cat "$1/hook-mark" >&2 || true
  fi
}

assert_clean_git() {
  local work="$1"
  if [[ -d "$work/.git/rebase-merge" || -d "$work/.git/rebase-apply" ]]; then
    show_sync "$work"
    fail "rebase or am left in progress"
  fi
  if [[ -n "$(git -C "$work" status --porcelain --untracked-files=no)" ]]; then
    show_sync "$work"
    fail "worktree dirty after sync"
  fi
}

pin_foreign_replay_branch() {
  local work="$1"
  git -C "$work" branch jkubo-sync-replay HEAD
}

assert_foreign_replay_branch() {
  local work="$1" listed
  git -C "$work" show-ref --verify --quiet refs/heads/jkubo-sync-replay \
    || fail "sync deleted pre-existing jkubo-sync-replay"
  listed="$(git -C "$work" branch --list 'jkubo-sync-replay-*')"
  if [[ -n "$listed" ]]; then
    printf '%s\n' "$listed" >&2
    fail "sync left an invocation-owned replay branch"
  fi
}

capture_state() {
  local work="$1" dest="$2" git_dir name path f sym
  mkdir -p "$dest"
  git_dir="$(git -C "$work" rev-parse --absolute-git-dir)"
  git -C "$work" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort >"$dest/refs"
  git -C "$work" rev-parse HEAD >"$dest/head"
  if sym="$(git -C "$work" symbolic-ref -q HEAD)"; then
    printf '%s\n' "$sym" >"$dest/symbolic"
  else
    printf 'detached\n' >"$dest/symbolic"
  fi
  # github-output, hook-mark, and sync.out are created by this harness.
  git -C "$work" status --porcelain=v1 --untracked-files=all \
    | grep -v -E '^\?\? (github-output|hook-mark|sync\.out)$' >"$dest/porcelain" || true
  git -C "$work" ls-files --stage >"$dest/index"
  sha256sum "$git_dir/index" | awk '{print $1}' >"$dest/index-sha"
  git -C "$work" diff >"$dest/workdir-diff" || true
  git -C "$work" diff --cached >"$dest/cached-diff" || true
  {
    for name in rebase-merge rebase-apply sequencer MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD; do
      path="$git_dir/$name"
      if [[ ! -e "$path" ]]; then
        printf 'absent %s\n' "$name"
        continue
      fi
      if [[ -d "$path" ]]; then
        while IFS= read -r f; do
          sha256sum "$f"
        done < <(find "$path" -type f -print | LC_ALL=C sort)
      else
        sha256sum "$path"
      fi
    done
  } >"$dest/ops"
  if [[ -f "$work/notes.txt" ]]; then
    sha256sum "$work/notes.txt" | awk '{print $1}' >"$dest/notes"
  else
    printf 'absent\n' >"$dest/notes"
  fi
}

assert_snapshot_same() {
  local before="$1" after="$2" label="$3" name
  for name in refs head symbolic porcelain index index-sha workdir-diff cached-diff ops notes; do
    if ! cmp -s "$before/$name" "$after/$name"; then
      printf 'FAIL: %s changed %s\n' "$label" "$name" >&2
      diff -u "$before/$name" "$after/$name" >&2 || true
      exit 1
    fi
  done
}

expect_preflight_refusal() {
  local work="$1" needle="$2"
  local before after rc
  install_sync_bytes "$work"
  before="$(mktemp -d)"
  capture_state "$work" "$before"
  shift 2
  run_sync "$work" "$@"
  rc=$SYNC_RC
  after="$(mktemp -d)"
  capture_state "$work" "$after"
  if [[ "$rc" -ne 1 ]]; then
    show_sync "$work"
    fail "expected refusal exit 1, got $rc ($needle)"
  fi
  if ! grep -F "$needle" "$work/sync.out" >/dev/null; then
    show_sync "$work"
    fail "refusal did not report: $needle"
  fi
  assert_snapshot_same "$before" "$after" "$needle"
  rm -rf "$before" "$after"
}

scenario_noop() {
  new_sandbox
  local work="$SB_ROOT/work" base tip
  seed_base "$work"
  base="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_tree "$work" "product"
  snapshot_product_patch "$work"
  write_tooling_files "$work"
  commit_tree "$work" "tooling"
  tip="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$base" "$tip"
  install_hook "$work"
  pin_foreign_replay_branch "$work"
  run_sync "$work" --push --no-pull-origin
  if [[ "$SYNC_RC" -ne 0 ]]; then
    show_sync "$work"
    fail "no-op sync exited $SYNC_RC"
  fi
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "no-op moved jkubo"
  assert_eq "$(git -C "$work" rev-parse main)" "$base" "no-op main is not the upstream mirror"
  assert_eq "$(git -C "$work" rev-parse upstream/main)" "$base" "no-op upstream"
  assert_eq "$(out_val "$work/github-output" changed)" "false" "no-op changed"
  assert_eq "$(out_val "$work/github-output" sha)" "$tip" "no-op sha"
  git -C "$work" diff --exit-code main upstream/main \
    || fail "no-op main tree differs from upstream"
  assert_clean_git "$work"
  assert_foreign_replay_branch "$work"
  say "no-op leaves product and upstream where they are"
}

scenario_replay() {
  new_sandbox
  local work="$SB_ROOT/work" base tip up after upstream_author
  seed_base "$work"
  base="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_as "$work" "Product Author" "product-author@example.com" "product"
  snapshot_product_patch "$work"
  write_tooling_files "$work"
  commit_as "$work" "Tooling Author" "tooling-author@example.com" "tooling"
  tip="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$base" "$tip"
  git -C "$work" checkout -q main
  mkdir -p "$work/.github/workflows"
  printf 'from-upstream\n' >"$work/.github/workflows/ci.yml"
  printf 'upstream-only\n' >"$work/upstream-only.txt"
  commit_as "$work" "Upstream Author" "upstream-author@example.com" "upstream move"
  up="$(git -C "$work" rev-parse HEAD)"
  upstream_author="$(git -C "$work" log -1 --format='%an <%ae>' "$up")"
  git -C "$work" push -q upstream "HEAD:refs/heads/main"
  git -C "$work" checkout -q jkubo
  install_hook "$work"
  pin_foreign_replay_branch "$work"
  isolate_identity "$work"
  run_sync "$work" --push --no-pull-origin
  SYNC_ISOLATE_IDENTITY=0
  if [[ "$SYNC_RC" -ne 0 ]]; then
    show_sync "$work"
    fail "replay sync exited $SYNC_RC"
  fi
  after="$(git -C "$work" rev-parse jkubo)"
  [[ "$after" != "$tip" ]] || fail "replay did not advance jkubo"
  [[ "$after" != "$up" ]] || fail "replay sha is pure upstream"
  assert_eq "$(git -C "$work" rev-parse main)" "$up" "replay main sha"
  assert_eq "$(git -C "$work" rev-parse upstream/main)" "$up" "replay upstream sha"
  assert_eq "$(git -C "$work" log -1 --format='%an <%ae>' main)" "$upstream_author" \
    "replay rewrote upstream author"
  assert_eq "$(git -C "$work" log -1 --format='%cn <%ce>' main)" \
    "$(git -C "$work" log -1 --format='%cn <%ce>' "$up")" "replay rewrote upstream committer"
  git -C "$work" diff --exit-code main upstream/main \
    || fail "replay main tree differs from upstream"
  assert_eq "$(out_val "$work/github-output" changed)" "true" "replay changed"
  assert_eq "$(out_val "$work/github-output" sha)" "$after" "replay sha output is jkubo"
  assert_eq "$(git -C "$work" show "jkubo:.github/workflows/ci.yml")" "from-upstream" \
    "replay kept upstream ci.yml"
  assert_eq "$(git -C "$work" show "jkubo:feature.txt")" "product" "replay kept product"
  assert_commit_identity "$work" jkubo \
    "Tooling Author <tooling-author@example.com>" "replay tooling"
  assert_commit_identity "$work" "jkubo^" \
    "Product Author <product-author@example.com>" "replay product"
  assert_eq "$(git -C "$work" config user.name || true)" "" "replay changed persistent name"
  assert_eq "$(git -C "$work" config user.email || true)" "" \
    "replay changed persistent email"
  cmp -s "$REAL_SYNC" "$work/scripts/sync-upstream.sh" || fail "replay script bytes drifted"
  grep -q '^hooked$' "$work/hook-mark" || fail "pre-push hook did not run on replay"
  assert_clean_git "$work"
  assert_foreign_replay_branch "$work"
  say "replay advances jkubo, mirrors main, and reports that sha"
}

scenario_fallback_keeps_upstream_workflow() {
  new_sandbox
  local work="$SB_ROOT/work" base tip up restored upstream_author
  local -a original_branches=()
  seed_base "$work"
  base="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_as "$work" "Product Author" "product-author@example.com" "product"
  snapshot_product_patch "$work"
  printf 'tooling-notes\n' >"$work/notes.txt"
  printf 'published extra work\n' >"$work/USER_PUBLISHED_NOTE"
  write_tooling_files "$work"
  commit_as "$work" "Tooling Author" "tooling-author@example.com" "tooling"
  tip="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$base" "$tip"
  git -C "$work" checkout -q main
  printf 'upstream-notes\n' >"$work/notes.txt"
  mkdir -p "$work/.github/workflows"
  printf 'from-upstream\n' >"$work/.github/workflows/ci.yml"
  commit_as "$work" "Upstream Author" "upstream-author@example.com" "upstream edits notes and adds ci"
  up="$(git -C "$work" rev-parse HEAD)"
  upstream_author="$(git -C "$work" log -1 --format='%an <%ae>%n%cn <%ce>' "$up")"
  git -C "$work" push -q upstream "HEAD:refs/heads/main"
  git -C "$work" checkout -q jkubo
  install_hook "$work"
  pin_foreign_replay_branch "$work"
  isolate_identity "$work"
  run_sync "$work" --push --no-pull-origin
  SYNC_ISOLATE_IDENTITY=0
  if [[ "$SYNC_RC" -ne 0 ]]; then
    show_sync "$work"
    fail "fallback sync exited $SYNC_RC"
  fi
  assert_eq "$(git -C "$work" rev-parse main)" "$up" "fallback main sha"
  assert_eq "$(git -C "$work" log -1 --format='%an <%ae>%n%cn <%ce>' main)" "$upstream_author" \
    "fallback rewrote upstream metadata"
  git -C "$work" diff --exit-code main upstream/main \
    || fail "fallback main tree differs from upstream"
  assert_eq "$(git -C "$work" show "jkubo:.github/workflows/ci.yml")" "from-upstream" \
    "fallback deleted or replaced upstream ci.yml"
  assert_eq "$(git -C "$work" show "jkubo:notes.txt")" "upstream-notes" \
    "fallback notes are not the upstream text"
  mapfile -t original_branches < <(git -C "$work" for-each-ref \
    --format='%(refname)' 'refs/heads/jkubo-sync-original-*')
  [[ ${#original_branches[@]} -eq 1 ]] || fail "fallback did not retain one named original tip"
  assert_eq "$(git -C "$work" rev-parse "${original_branches[0]}")" "$tip" \
    "fallback retained the wrong original tip"
  assert_eq "$(git -C "$work" show "${original_branches[0]}:USER_PUBLISHED_NOTE")" \
    "published extra work" "fallback lost accepted work outside series and tooling"
  assert_eq "$(git -C "$work" show "${original_branches[0]}:notes.txt")" \
    "tooling-notes" "fallback lost original non-series notes"
  grep -F "patch fallback original fork retained on ${original_branches[0]#refs/heads/} at ${tip}" \
    "$work/sync.out" >/dev/null || fail "fallback did not report the retained original tip"
  assert_eq "$(git -C "$work" show "jkubo:feature.txt")" "product" "fallback product missing"
  git -C "$work" cat-file -e "jkubo:.github/workflows/sync-upstream.yml" \
    || fail "fallback did not restore the fork workflow"
  restored="$(mktemp)"
  git -C "$work" show "jkubo:scripts/sync-upstream.sh" >"$restored"
  cmp -s "$REAL_SYNC" "$restored" || fail "fallback restored script is not the real script"
  rm -f "$restored"
  assert_commit_identity "$work" "jkubo^" \
    "Product Author <product-author@example.com>" "fallback product"
  assert_commit_identity "$work" jkubo \
    "$CANONICAL_ID" "fallback tooling restore"
  assert_eq "$(git -C "$work" config user.email || true)" "" \
    "fallback changed persistent email"
  assert_eq "$(git -C "$work" config user.name || true)" "" \
    "fallback changed persistent name"
  assert_eq "$(out_val "$work/github-output" sha)" "$(git -C "$work" rev-parse jkubo)" \
    "fallback sha output"
  [[ "$(out_val "$work/github-output" sha)" != "$up" ]] || fail "fallback sha is upstream"
  assert_clean_git "$work"
  assert_foreign_replay_branch "$work"
  say "am fallback keeps upstream workflows and restores fork tooling"
}

scenario_rollback() {
  new_sandbox
  local work="$SB_ROOT/work" base tip main_before
  seed_base "$work"
  base="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_tree "$work" "product"
  snapshot_product_patch "$work"
  write_tooling_files "$work"
  commit_tree "$work" "tooling"
  tip="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$base" "$tip"
  git -C "$work" checkout -q main
  printf 'upstream-feature\n' >"$work/feature.txt"
  commit_tree "$work" "upstream conflicts with the product patch"
  git -C "$work" push -q upstream "HEAD:refs/heads/main"
  git -C "$work" checkout -q jkubo
  main_before="$(git -C "$work" rev-parse main)"
  install_hook "$work"
  pin_foreign_replay_branch "$work"
  run_sync "$work" --push --no-pull-origin
  if [[ "$SYNC_RC" -eq 0 ]]; then
    show_sync "$work"
    fail "conflicted replay exited 0"
  fi
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" "conflict moved jkubo"
  assert_eq "$(git -C "$work" rev-parse main)" "$main_before" "conflict moved main"
  assert_eq "$(out_val "$work/github-output" sha)" "$tip" "conflict sha output"
  assert_eq "$(out_val "$work/github-output" changed)" "false" "conflict reports changed"
  if [[ -s "$work/hook-mark" ]]; then
    show_sync "$work"
    fail "conflicted replay pushed"
  fi
  # Failed am is now retained prospectively: boolean creation ownership
  # cannot distinguish conflict state from a normal hook's staged work.
  [[ -d "$work/.git/rebase-apply" ]] || fail "failed am was not retained for inspection"
  [[ ! -d "$work/.git/rebase-merge" ]] || fail "proven unchanged rebase conflict was not aborted"
  [[ "$(git -C "$work" symbolic-ref --short HEAD)" == jkubo-sync-replay-* ]] \
    || fail "failed am is not retained on a named replay branch"
  git -C "$work" show-ref --verify --quiet refs/heads/jkubo-sync-replay \
    || fail "failed am removed a pre-existing branch"
  say "failed replay keeps named fork/remotes unchanged and retains uncertain am state"
}

scenario_lease() {
  new_sandbox
  local work="$SB_ROOT/work" base tip up after remote_jkubo remote_main spoiler
  seed_base "$work"
  base="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_tree "$work" "product"
  snapshot_product_patch "$work"
  write_tooling_files "$work"
  commit_tree "$work" "tooling"
  tip="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$base" "$tip"
  spoiler="$(git -C "$work" commit-tree "${tip}^{tree}" -m spoiler)"
  git -C "$work" push -q origin "$spoiler:refs/heads/spoiler-hold"
  git -C "$work" checkout -q main
  printf 'upstream-only\n' >"$work/upstream-only.txt"
  commit_tree "$work" "upstream move"
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream "HEAD:refs/heads/main"
  git -C "$work" checkout -q jkubo
  install_hook "$work"
  ORIGIN_BARE="$SB_ROOT/origin.git"
  SPOILER_SHA="$spoiler"
  SPOIL_ONCE="$work/spoil-once"
  export ORIGIN_BARE SPOILER_SHA SPOIL_ONCE
  pin_foreign_replay_branch "$work"
  run_sync "$work" --push --no-pull-origin
  unset ORIGIN_BARE SPOILER_SHA SPOIL_ONCE
  if [[ "$SYNC_RC" -eq 0 ]]; then
    show_sync "$work"
    fail "stale lease push exited 0"
  fi
  after="$(git -C "$work" rev-parse jkubo)"
  [[ "$after" != "$tip" ]] || fail "lease failure rolled the local replay back"
  [[ "$after" != "$spoiler" ]] || fail "local jkubo became the spoiled remote"
  assert_eq "$(git -C "$work" rev-parse main)" "$up" "lease failure undid the local main mirror"
  remote_jkubo="$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)"
  remote_main="$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)"
  assert_eq "$remote_jkubo" "$spoiler" "remote jkubo was not the observed lease target"
  assert_eq "$remote_main" "$base" "lease failure published remote main"
  grep -q '^hooked$' "$work/hook-mark" || fail "lease scenario did not run the pre-push hook"
  grep -q '^spoiled$' "$work/hook-mark" || fail "lease scenario did not move the remote"
  assert_clean_git "$work"
  assert_foreign_replay_branch "$work"
  say "push rejection keeps the local replay and refuses a bare lease"
}

scenario_repair_then_noop() {
  new_sandbox
  local work="$SB_ROOT/work" base first second
  seed_base "$work"
  base="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_tree "$work" "product"
  snapshot_product_patch "$work"
  git -C "$work" reset --hard -q "$base"
  write_tooling_files "$work"
  commit_tree "$work" "tooling without the product file"
  publish_fork_at_base "$work" "$base" "$(git -C "$work" rev-parse HEAD)"
  if [[ -f "$work/feature.txt" ]]; then
    fail "repair fixture already has the product file"
  fi
  install_hook "$work"
  pin_foreign_replay_branch "$work"
  run_sync "$work" --push --no-pull-origin
  if [[ "$SYNC_RC" -ne 0 ]]; then
    show_sync "$work"
    fail "repair sync exited $SYNC_RC"
  fi
  assert_eq "$(git -C "$work" show "jkubo:feature.txt")" "product" "repair did not apply the product"
  assert_eq "$(out_val "$work/github-output" changed)" "true" "missing product was treated as a no-op"
  first="$(out_val "$work/github-output" sha)"
  assert_eq "$first" "$(git -C "$work" rev-parse jkubo)" "repair sha output"
  [[ "$first" != "$base" ]] || fail "repair sha is the unpatched base"
  assert_eq "$(git -C "$work" rev-parse main)" "$(git -C "$work" rev-parse upstream/main)" \
    "repair main is not upstream"
  run_sync "$work" --push --no-pull-origin
  if [[ "$SYNC_RC" -ne 0 ]]; then
    show_sync "$work"
    fail "second sync after repair exited $SYNC_RC"
  fi
  second="$(out_val "$work/github-output" sha)"
  assert_eq "$second" "$first" "verified no-op moved jkubo"
  assert_eq "$(out_val "$work/github-output" changed)" "false" "verified state was not a no-op"
  assert_eq "$(git -C "$work" show "jkubo:feature.txt")" "product" "no-op dropped the product"
  git -C "$work" diff --exit-code main upstream/main \
    || fail "repaired main tree differs from upstream"
  assert_clean_git "$work"
  assert_foreign_replay_branch "$work"
  say "missing product is repaired, then a correct tree is a no-op"
}

scenario_dirty_preserves_replay_branch() {
  new_sandbox
  local work="$SB_ROOT/work" tip
  seed_base "$work"
  tip="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" branch jkubo-sync-replay "$tip"
  printf 'dirty\n' >>"$work/notes.txt"
  expect_preflight_refusal "$work" "worktree dirty; commit/stash or pass --allow-dirty"
  assert_eq "$(git -C "$work" rev-parse jkubo-sync-replay)" "$tip" \
    "dirty refusal moved jkubo-sync-replay"
  say "dirty refusal keeps the existing replay branch, index, and worktree"
}

begin_conflict_pair() {
  local work="$1"
  git -C "$work" checkout -q -b side
  printf 'side\n' >"$work/notes.txt"
  commit_tree "$work" "side"
  SIDE_SHA="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q main
  printf 'main\n' >"$work/notes.txt"
  commit_tree "$work" "mainline"
}

scenario_rebase_preserves_operation() {
  new_sandbox
  local work="$SB_ROOT/work" held
  seed_base "$work"
  begin_conflict_pair "$work"
  git -C "$work" checkout -q side
  git -C "$work" branch jkubo-sync-replay HEAD
  held="$(git -C "$work" rev-parse jkubo-sync-replay)"
  if git -C "$work" rebase main; then
    fail "fixture rebase did not conflict"
  fi
  [[ -d "$work/.git/rebase-merge" ]] || fail "fixture rebase left no rebase-merge"
  expect_preflight_refusal "$work" "rebase already in progress; refusing to abort it"
  assert_eq "$(git -C "$work" rev-parse jkubo-sync-replay)" "$held" \
    "rebase refusal moved jkubo-sync-replay"
  [[ -d "$work/.git/rebase-merge" ]] || fail "rebase refusal removed rebase-merge"
  grep -F 'UU notes.txt' <<<"$(git -C "$work" status --porcelain=v1)" >/dev/null \
    || fail "rebase refusal cleared UU state"
  say "pre-existing rebase is refused without aborting it"
}

scenario_rebase_allow_dirty_preserves_operation() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_base "$work"
  begin_conflict_pair "$work"
  git -C "$work" checkout -q side
  git -C "$work" branch jkubo-sync-replay HEAD
  if git -C "$work" rebase main; then
    fail "fixture rebase did not conflict"
  fi
  expect_preflight_refusal "$work" "rebase already in progress; refusing to abort it" --allow-dirty
  if grep -F 'worktree dirty' "$work/sync.out"; then
    fail "allow-dirty rebase refusal reported a dirty worktree"
  fi
  [[ -d "$work/.git/rebase-merge" ]] || fail "allow-dirty rebase refusal removed rebase-merge"
  say "allow-dirty still refuses a pre-existing rebase"
}

scenario_am_allow_dirty_preserves_operation() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_base "$work"
  begin_conflict_pair "$work"
  git -C "$work" checkout -q --detach "$SIDE_SHA"
  git -C "$work" format-patch -1 --stdout HEAD >"$SB_ROOT/side.patch"
  git -C "$work" checkout -q main
  git -C "$work" branch jkubo-sync-replay HEAD
  if git -C "$work" am "$SB_ROOT/side.patch"; then
    fail "fixture am did not conflict"
  fi
  [[ -f "$work/.git/rebase-apply/applying" ]] || fail "fixture am left no applying marker"
  expect_preflight_refusal "$work" "am already in progress; refusing to abort it" --allow-dirty
  [[ -f "$work/.git/rebase-apply/applying" ]] || fail "allow-dirty am refusal removed applying"
  say "allow-dirty still refuses a pre-existing am"
}

scenario_cherry_pick_allow_dirty_preserves_operation() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_base "$work"
  begin_conflict_pair "$work"
  git -C "$work" branch jkubo-sync-replay HEAD
  if git -C "$work" cherry-pick "$SIDE_SHA"; then
    fail "fixture cherry-pick did not conflict"
  fi
  [[ -f "$work/.git/CHERRY_PICK_HEAD" ]] || fail "fixture cherry-pick left no CHERRY_PICK_HEAD"
  expect_preflight_refusal "$work" "cherry-pick already in progress; refusing to abort it" --allow-dirty
  [[ -f "$work/.git/CHERRY_PICK_HEAD" ]] || fail "allow-dirty cherry-pick refusal removed CHERRY_PICK_HEAD"
  say "allow-dirty still refuses a pre-existing cherry-pick"
}

scenario_merge_allow_dirty_preserves_operation() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_base "$work"
  begin_conflict_pair "$work"
  git -C "$work" branch jkubo-sync-replay HEAD
  if git -C "$work" merge side; then
    fail "fixture merge did not conflict"
  fi
  [[ -f "$work/.git/MERGE_HEAD" ]] || fail "fixture merge left no MERGE_HEAD"
  expect_preflight_refusal "$work" "merge already in progress; refusing to abort it" --allow-dirty
  [[ -f "$work/.git/MERGE_HEAD" ]] || fail "allow-dirty merge refusal removed MERGE_HEAD"
  say "allow-dirty still refuses a pre-existing merge"
}

scenario_revert_allow_dirty_preserves_operation() {
  new_sandbox
  local work="$SB_ROOT/work" v2
  seed_base "$work"
  printf 'v2\n' >"$work/notes.txt"
  commit_tree "$work" "v2"
  v2="$(git -C "$work" rev-parse HEAD)"
  printf 'v3\n' >"$work/notes.txt"
  commit_tree "$work" "v3"
  git -C "$work" branch jkubo-sync-replay HEAD
  if git -C "$work" revert --no-edit "$v2"; then
    fail "fixture revert did not conflict"
  fi
  [[ -f "$work/.git/REVERT_HEAD" ]] || fail "fixture revert left no REVERT_HEAD"
  expect_preflight_refusal "$work" "revert already in progress; refusing to abort it" --allow-dirty
  [[ -f "$work/.git/REVERT_HEAD" ]] || fail "allow-dirty revert refusal removed REVERT_HEAD"
  say "allow-dirty still refuses a pre-existing revert"
}

scenario_replay_branch_collision() {
  new_sandbox
  local work="$SB_ROOT/work" base advanced sentinel
  seed_base "$work"
  base="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" branch jkubo-sync-replay "$base"
  sentinel="$(git -C "$work" rev-parse jkubo-sync-replay)"
  printf 'upstream-only\n' >"$work/upstream-only.txt"
  commit_tree "$work" "upstream move"
  advanced="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream "HEAD:refs/heads/main"
  git -C "$work" update-ref refs/remotes/upstream/main "$base"
  git -C "$work" checkout -q -B jkubo "$base"
  printf 'dirty\n' >>"$work/notes.txt"
  [[ "$advanced" != "$base" ]] || fail "collision fixture did not advance upstream"
  REPLAY_BRANCH=jkubo-sync-replay \
    expect_preflight_refusal "$work" \
      "replay branch jkubo-sync-replay already exists; refusing to change it" \
      --allow-dirty --no-pull-origin
  if grep -F 'worktree dirty' "$work/sync.out"; then
    fail "allow-dirty collision refusal reported a dirty worktree"
  fi
  assert_eq "$(git -C "$work" rev-parse jkubo-sync-replay)" "$sentinel" \
    "collision refusal moved jkubo-sync-replay"
  assert_eq "$(git -C "$work" rev-parse refs/remotes/upstream/main)" "$base" \
    "collision refusal fetched upstream"
  say "named replay branch collision is refused before fetch"
}

BASE_SHA=""
TIP_SHA=""

seed_published() {
  local work="$1"
  seed_base "$work"
  BASE_SHA="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_tree "$work" "product"
  snapshot_product_patch "$work"
  write_tooling_files "$work"
  commit_tree "$work" "tooling"
  TIP_SHA="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$BASE_SHA" "$TIP_SHA"
}

advance_upstream_detached() {
  local work="$1" base="$2"
  git -C "$work" checkout -q --detach "$base"
  printf 'upstream-only\n' >"$work/upstream-only.txt"
  commit_tree "$work" "upstream move"
  git -C "$work" push -q upstream "HEAD:refs/heads/main"
  git -C "$work" checkout -q jkubo
}

expect_history_refusal() {
  local work="$1" needle="$2"
  local before after rc
  shift 2
  before="$(mktemp -d)"
  capture_state "$work" "$before"
  run_sync "$work" "$@"
  rc=$SYNC_RC
  after="$(mktemp -d)"
  capture_state "$work" "$after"
  if [[ "$rc" -ne 1 ]]; then
    show_sync "$work"
    fail "expected refusal exit 1, got $rc ($needle)"
  fi
  if ! grep -F "$needle" "$work/sync.out" >/dev/null; then
    show_sync "$work"
    fail "refusal did not report: $needle"
  fi
  assert_snapshot_same "$before" "$after" "$needle"
  if [[ -s "$work/hook-mark" ]]; then
    show_sync "$work"
    fail "refusal reached a push hook: $needle"
  fi
  rm -rf "$before" "$after"
}

scenario_receive_reject() {
  local reject_ref="$1"
  new_sandbox
  local work="$SB_ROOT/work" up
  seed_published "$work"
  git -C "$work" checkout -q main
  printf 'upstream-only\n' >"$work/upstream-only.txt"
  commit_tree "$work" "upstream move"
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream "HEAD:refs/heads/main"
  git -C "$work" checkout -q jkubo
  cat >"$SB_ROOT/origin.git/hooks/update" <<EOF
#!/bin/bash
if [[ "\$1" == "$reject_ref" ]]; then
  echo "reject \$1" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$SB_ROOT/origin.git/hooks/update"
  install_hook "$work"
  pin_foreign_replay_branch "$work"
  run_sync "$work" --push --no-pull-origin
  if [[ "$SYNC_RC" -eq 0 ]]; then
    show_sync "$work"
    fail "receive rejection of $reject_ref exited 0"
  fi
  [[ "$(git -C "$work" rev-parse jkubo)" != "$TIP_SHA" ]] \
    || fail "receive rejection rolled back local replay ($reject_ref)"
  assert_eq "$(git -C "$work" rev-parse main)" "$up" \
    "receive rejection undid local main ($reject_ref)"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$BASE_SHA" \
    "receive rejection published remote main ($reject_ref)"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)" "$TIP_SHA" \
    "receive rejection published remote fork ($reject_ref)"
  grep -q '^hooked$' "$work/hook-mark" || fail "receive rejection skipped the client hook ($reject_ref)"
  assert_clean_git "$work"
  assert_foreign_replay_branch "$work"
  say "receive hook rejecting $reject_ref leaves both remote refs unchanged"
}

scenario_remote_fork_guard() {
  local kind="$1"
  shift
  new_sandbox
  local work="$SB_ROOT/work" remote_fork remote_main
  seed_published "$work"
  if [[ "$kind" == "ahead" ]]; then
    git -C "$work" checkout -q jkubo
    printf 'remote-fork-only\n' >"$work/remote-fork-only.txt"
    commit_tree "$work" "remote fork only"
    git -C "$work" push -q origin "HEAD:refs/heads/jkubo"
    git -C "$work" reset --hard -q "$TIP_SHA"
  else
    git -C "$work" checkout -q --detach "$BASE_SHA"
    printf 'remote-fork-divergent\n' >"$work/remote-fork-only.txt"
    commit_tree "$work" "remote fork from previous upstream"
    git -C "$work" push -q --force origin "HEAD:refs/heads/jkubo"
    git -C "$work" checkout -q jkubo
  fi
  advance_upstream_detached "$work" "$BASE_SHA"
  remote_fork="$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)"
  remote_main="$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)"
  if git -C "$work" merge-base --is-ancestor "$remote_fork" "$TIP_SHA"; then
    fail "fixture origin/jkubo is already contained in local jkubo ($kind)"
  fi
  install_hook "$work"
  expect_history_refusal "$work" \
    "origin/jkubo is not an ancestor of local jkubo; refusing to discard remote fork history" \
    "$@"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$TIP_SHA" "remote fork guard moved jkubo ($kind)"
  assert_eq "$(git -C "$work" rev-parse main)" "$BASE_SHA" "remote fork guard moved main ($kind)"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)" "$remote_fork" \
    "remote fork guard published jkubo ($kind)"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$remote_main" \
    "remote fork guard published main ($kind)"
  say "remote fork $kind is refused (${*:-default pull}) without push"
}

scenario_remote_mirror_guard() {
  new_sandbox
  local work="$SB_ROOT/work" extra
  seed_published "$work"
  git -C "$work" checkout -q --detach "$BASE_SHA"
  printf 'remote-main-only\n' >"$work/remote-main-only.txt"
  commit_tree "$work" "remote main only"
  extra="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q origin "HEAD:refs/heads/main"
  git -C "$work" checkout -q jkubo
  if git -C "$work" merge-base --is-ancestor "$extra" "$BASE_SHA"; then
    fail "fixture origin/main is already contained in upstream"
  fi
  install_hook "$work"
  expect_history_refusal "$work" \
    "origin/main is not an ancestor of upstream/main; refusing to discard fetched mirror work" \
    "$@"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$extra" \
    "fetched mirror guard discarded origin/main"
  assert_eq "$(git -C "$work" rev-parse main)" "$BASE_SHA" "fetched mirror guard moved local main"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$TIP_SHA" "fetched mirror guard moved jkubo"
  say "fetched mirror work is refused (${*:-default pull})"
}

scenario_local_mirror_guard() {
  local kind="$1"
  shift
  new_sandbox
  local work="$SB_ROOT/work" local_main remote_main remote_fork
  seed_published "$work"
  # main is pure upstream and does not contain the sync script. Commit the
  # script with the unpublished file so the refusal can be executed while
  # that file is the checked-out worktree.
  git -C "$work" checkout -q main
  install_sync_bytes "$work"
  printf 'local-only\n' >"$work/local-main-only.txt"
  commit_tree "$work" "local main only"
  local_main="$(git -C "$work" rev-parse HEAD)"
  if [[ "$kind" == "divergent" ]]; then
    git -C "$work" checkout -q --detach "$BASE_SHA"
    printf 'upstream-only\n' >"$work/upstream-only.txt"
    commit_tree "$work" "upstream move"
    git -C "$work" push -q upstream "HEAD:refs/heads/main"
    git -C "$work" checkout -q main
  fi
  remote_main="$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)"
  remote_fork="$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)"
  [[ "$remote_main" == "$BASE_SHA" ]] || fail "fixture origin/main is not the pure upstream base"
  install_hook "$work"
  expect_history_refusal "$work" \
    "local main is not an ancestor of upstream/main; refusing to discard unpublished mirror work" \
    "$@"
  assert_eq "$(git -C "$work" rev-parse main)" "$local_main" "local mirror guard reset main ($kind)"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$TIP_SHA" "local mirror guard moved jkubo ($kind)"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$remote_main" \
    "local mirror guard published origin/main ($kind)"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)" "$remote_fork" \
    "local mirror guard published origin/jkubo ($kind)"
  assert_eq "$(git -C "$work" show "main:local-main-only.txt")" "local-only" \
    "local mirror guard dropped local-main-only.txt ($kind)"
  [[ -f "$work/local-main-only.txt" ]] || fail "local mirror guard removed the worktree file ($kind)"
  git -C "$work" cat-file -e "${local_main}^{commit}" || fail "local mirror commit is gone ($kind)"
  say "local mirror $kind is refused (${*:-default pull})"
}

scenario_origin_fetch_failure() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_published "$work"
  advance_upstream_detached "$work" "$BASE_SHA"
  git -C "$work" remote set-url origin "$SB_ROOT/missing-origin.git"
  install_hook "$work"
  expect_history_refusal "$work" \
    "fetch origin failed; refusing to use a stale lease" \
    --push --no-pull-origin
  assert_eq "$(git -C "$work" rev-parse main)" "$BASE_SHA" "stale fetch moved local main"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$TIP_SHA" "stale fetch moved jkubo"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$BASE_SHA" \
    "stale fetch published origin/main"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)" "$TIP_SHA" \
    "stale fetch published origin/jkubo"
  say "origin fetch failure does not use a stale lease"
}

# The pre-push hook moves local jkubo after capture. No-op and replay both
# publish through push_fork; the captured oid differs, so both are exercised.
scenario_published_sha_survives_local_move() {
  local kind="$1"
  new_sandbox
  local work="$SB_ROOT/work" base tip mirror published moved
  seed_base "$work"
  base="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_tree "$work" "product"
  snapshot_product_patch "$work"
  write_tooling_files "$work"
  commit_tree "$work" "tooling"
  tip="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$base" "$tip"
  mirror="$base"
  if [[ "$kind" == "replay" ]]; then
    git -C "$work" checkout -q main
    printf 'upstream-only\n' >"$work/upstream-only.txt"
    commit_tree "$work" "upstream move"
    mirror="$(git -C "$work" rev-parse HEAD)"
    git -C "$work" push -q upstream "HEAD:refs/heads/main"
    git -C "$work" checkout -q jkubo
  elif [[ "$kind" != "noop" ]]; then
    fail "unknown local-move kind: $kind"
  fi
  install_local_move_hook "$work"
  LOCAL_MOVE_SHA="$work/local-move-sha"
  LOCAL_MOVE_PLANNED="$work/local-move-planned"
  export LOCAL_MOVE_SHA LOCAL_MOVE_PLANNED
  pin_foreign_replay_branch "$work"
  run_sync "$work" --push --no-pull-origin
  unset LOCAL_MOVE_SHA LOCAL_MOVE_PLANNED
  if [[ "$SYNC_RC" -ne 0 ]]; then
    show_sync "$work"
    fail "$kind sync with local move exited $SYNC_RC"
  fi
  grep -q '^hooked$' "$work/hook-mark" || fail "$kind pre-push hook did not run"
  grep -q '^moved$' "$work/hook-mark" || fail "$kind pre-push hook did not move jkubo"
  [[ -s "$work/local-move-planned" && -s "$work/local-move-sha" ]] \
    || fail "$kind hook did not record shas"
  published="$(<"$work/local-move-planned")"
  moved="$(<"$work/local-move-sha")"
  [[ "$published" != "$moved" ]] || fail "$kind hook commit collided with the published sha"
  grep -F "local jkubo moved after capture; leaving it and exporting ${published}" \
    "$work/sync.out" >/dev/null \
    || fail "$kind did not keep the moved local ref while exporting the published sha"
  if [[ "$kind" == "noop" ]]; then
    grep -q '^uptodate$' "$work/hook-mark" \
      || fail "noop push did not take the up-to-date hook path"
    assert_eq "$published" "$tip" "noop published sha is not the captured tip"
    assert_eq "$(out_val "$work/github-output" changed)" "false" \
      "noop local move reported changed"
  else
    grep -q '^updating$' "$work/hook-mark" \
      || fail "replay push did not take the updating hook path"
    [[ "$published" != "$tip" ]] || fail "replay published the pre-sync tip"
    [[ "$published" != "$mirror" ]] || fail "replay published pure upstream"
    assert_eq "$(out_val "$work/github-output" changed)" "true" \
      "replay local move reported unchanged"
  fi
  assert_eq "$(out_val "$work/github-output" sha)" "$published" "$kind exported sha"
  assert_eq "$(out_val "$work/github-output" upstream)" "$mirror" "$kind exported upstream"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)" "$published" \
    "$kind origin jkubo"
  git --git-dir "$SB_ROOT/origin.git" cat-file -e "${published}^{commit}" \
    || fail "$kind published commit is absent from origin"
  if git --git-dir "$SB_ROOT/origin.git" cat-file -e "${moved}^{commit}" >/dev/null 2>&1; then
    fail "$kind origin contains the unpushed local commit"
  fi
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$moved" \
    "$kind local jkubo was reset"
  assert_eq "$(git -C "$work" rev-parse 'jkubo^')" "$published" \
    "$kind local commit is not based on the published sha"
  git -C "$work" cat-file -e "${moved}^{commit}" \
    || fail "$kind local commit object is missing"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/jkubo" \
    "$kind HEAD left jkubo"
  git -C "$work" merge-base --is-ancestor "$published" "$moved" \
    || fail "$kind published sha is not an ancestor of the preserved local commit"
  assert_eq "$(git -C "$work" rev-parse main)" "$mirror" "$kind local main"
  assert_eq "$(git -C "$work" rev-parse upstream/main)" "$mirror" "$kind upstream/main"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)" "$mirror" \
    "$kind origin main"
  git -C "$work" diff --exit-code main upstream/main \
    || fail "$kind main tree differs from upstream"
  if git -C "$work" cat-file -e "main:feature.txt" >/dev/null 2>&1; then
    fail "$kind mirror contains the product file"
  fi
  assert_clean_git "$work"
  assert_foreign_replay_branch "$work"
  say "$kind push exports the published sha and keeps the hook's local commit"
}

# A normal pre-push hook: add and commit a file, then accept or reject.
# The commit has to be a real git commit so the named ref, index, and
# worktree all move together. HOOK_EXIT is the hook status.
install_commit_file_hook() {
  local work="$1"
  cat >"$work/.git/hooks/pre-push" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ -n "${HOOK_MARK:-}" ]]; then
  printf 'hooked\n' >>"$HOOK_MARK"
fi
# git writes the planned updates here. Consume them. The assertions below
# depend on the commit this hook creates, not on which refs were pushed.
cat >/dev/null || true
if [[ -z "${HOOK_COMMIT_OUT:-}" ]]; then
  printf 'hook-commit-out-missing\n' >>"${HOOK_MARK:-/dev/null}"
  exit 1
fi
if [[ -s "$HOOK_COMMIT_OUT" ]]; then
  exit "${HOOK_EXIT:-1}"
fi
printf 'hook-work\n' > user-hook-work.txt
git add -- user-hook-work.txt
git commit -m "user hook work" -- user-hook-work.txt
git rev-parse HEAD >"$HOOK_COMMIT_OUT"
printf 'committed\n' >>"${HOOK_MARK:-/dev/null}"
exit "${HOOK_EXIT:-1}"
EOF
  chmod +x "$work/.git/hooks/pre-push"
}

install_reject_main_update() {
  local bare="$1"
  cat >"$bare/hooks/update" <<'EOF'
#!/bin/bash
if [[ "$1" == "refs/heads/main" ]]; then
  echo "reject refs/heads/main" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$bare/hooks/update"
}

# kind: noop | replay. rejection: hook | update.
# Remaining args are passed to sync-upstream.sh (default pull or --no-pull-origin).
# The noop update case leaves origin/main as a strict ancestor of upstream.
# An equal main is not transmitted, so a bare update hook would never run;
# the product tree is still the verified no-op path.
scenario_rejected_push_keeps_hook_work() {
  local kind="$1" rejection="$2"
  shift 2
  local -a sync_args=("$@")
  new_sandbox
  local work="$SB_ROOT/work" base tip root="" up="" recorded
  local remote_main_before remote_fork_before no_pull=0 arg
  local head_blob index_blob hook_tree index_tree parent
  seed_base "$work"
  if [[ "$kind" == "noop" && "$rejection" == "update" ]]; then
    root="$(git -C "$work" rev-parse HEAD)"
    printf 'base-more\n' >>"$work/notes.txt"
    commit_tree "$work" "base2"
  fi
  base="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_tree "$work" "product"
  snapshot_product_patch "$work"
  write_tooling_files "$work"
  commit_tree "$work" "tooling"
  tip="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$base" "$tip"
  up="$base"
  if [[ "$kind" == "replay" ]]; then
    git -C "$work" checkout -q main
    printf 'upstream-only\n' >"$work/upstream-only.txt"
    commit_tree "$work" "upstream move"
    up="$(git -C "$work" rev-parse HEAD)"
    git -C "$work" push -q upstream "HEAD:refs/heads/main"
    git -C "$work" checkout -q jkubo
  elif [[ "$kind" != "noop" ]]; then
    fail "unknown rejection kind: $kind"
  fi
  if [[ "$kind" == "noop" && "$rejection" == "update" ]]; then
    [[ -n "$root" && "$root" != "$base" ]] || fail "noop update fixture has no ancestor main"
    git --git-dir "$SB_ROOT/origin.git" update-ref refs/heads/main "$root"
    git -C "$work" update-ref refs/remotes/origin/main "$root"
  fi
  if [[ "$rejection" == "hook" ]]; then
    HOOK_EXIT=1
  elif [[ "$rejection" == "update" ]]; then
    HOOK_EXIT=0
    install_reject_main_update "$SB_ROOT/origin.git"
  else
    fail "unknown rejection: $rejection"
  fi
  export HOOK_EXIT
  install_commit_file_hook "$work"
  HOOK_COMMIT_OUT="$SB_ROOT/hook-commit"
  export HOOK_COMMIT_OUT
  : >"$HOOK_COMMIT_OUT"
  for arg in "${sync_args[@]}"; do
    if [[ "$arg" == "--no-pull-origin" ]]; then
      no_pull=1
    fi
  done
  remote_main_before="$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)"
  remote_fork_before="$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)"
  pin_foreign_replay_branch "$work"
  run_sync "$work" "${sync_args[@]}"
  unset HOOK_EXIT HOOK_COMMIT_OUT
  if [[ "$SYNC_RC" -eq 0 ]]; then
    show_sync "$work"
    fail "$kind $rejection push rejection exited 0 (${sync_args[*]})"
  fi
  grep -q '^hooked$' "$work/hook-mark" \
    || fail "$kind $rejection pre-push hook did not run"
  grep -q '^committed$' "$work/hook-mark" \
    || fail "$kind $rejection pre-push hook did not commit"
  [[ -s "$SB_ROOT/hook-commit" ]] || fail "$kind $rejection hook did not record its commit"
  recorded="$(<"$SB_ROOT/hook-commit")"
  assert_eq "$(git -C "$work" rev-parse refs/heads/jkubo)" "$recorded" \
    "$kind $rejection named fork lost the hook commit"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$recorded" \
    "$kind $rejection HEAD is not the hook commit"
  assert_eq "$(git -C "$work" symbolic-ref HEAD)" "refs/heads/jkubo" \
    "$kind $rejection HEAD left jkubo"
  parent="$(git -C "$work" rev-parse "${recorded}^")"
  if [[ "$kind" == "noop" ]]; then
    assert_eq "$parent" "$tip" "$kind $rejection hook commit is not based on the pre-sync fork"
    grep -F 'sync-upstream: already based on latest upstream and the product patch is present' \
      "$work/sync.out" >/dev/null \
      || fail "$kind $rejection did not take the verified no-op path"
    if grep -F 'sync-upstream: replay jkubo onto' "$work/sync.out" >/dev/null; then
      fail "$kind $rejection replayed a no-op"
    fi
    assert_eq "$(git -C "$work" rev-parse main)" "$base" \
      "$kind $rejection moved local main"
  else
    [[ "$parent" != "$tip" ]] || fail "$kind $rejection hook commit stayed on the pre-sync fork"
    [[ "$up" != "$base" ]] || fail "$kind $rejection upstream did not move"
    git -C "$work" merge-base --is-ancestor "$up" "$parent" \
      || fail "$kind $rejection replay parent does not contain upstream"
    assert_eq "$(git -C "$work" show "${parent}:feature.txt")" "product" \
      "$kind $rejection replay dropped the product"
    if git -C "$work" cat-file -e "${parent}:user-hook-work.txt" >/dev/null 2>&1; then
      fail "$kind $rejection replay commit already contained the hook file"
    fi
    grep -F 'sync-upstream: replay jkubo onto' "$work/sync.out" >/dev/null \
      || fail "$kind $rejection did not replay"
    assert_eq "$(git -C "$work" rev-parse main)" "$up" \
      "$kind $rejection undid the local main mirror"
  fi
  assert_eq "$(git -C "$work" show "${recorded}:user-hook-work.txt")" "hook-work" \
    "$kind $rejection commit lost the hook file"
  assert_eq "$(cat "$work/user-hook-work.txt")" "hook-work" \
    "$kind $rejection worktree lost the hook file"
  head_blob="$(git -C "$work" rev-parse "HEAD:user-hook-work.txt")"
  index_blob="$(git -C "$work" rev-parse ":user-hook-work.txt")"
  assert_eq "$index_blob" "$head_blob" "$kind $rejection index blob drifted from the commit"
  hook_tree="$(git -C "$work" rev-parse "${recorded}^{tree}")"
  index_tree="$(git -C "$work" write-tree)"
  assert_eq "$index_tree" "$hook_tree" "$kind $rejection index tree is not the hook commit"
  git -C "$work" diff --exit-code >/dev/null \
    || fail "$kind $rejection worktree differs from the hook commit"
  git -C "$work" diff --cached --exit-code >/dev/null \
    || fail "$kind $rejection index differs from the hook commit"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/main)" \
    "$remote_main_before" "$kind $rejection published origin/main"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse refs/heads/jkubo)" \
    "$remote_fork_before" "$kind $rejection published origin/jkubo"
  if git --git-dir "$SB_ROOT/origin.git" cat-file -e "${recorded}^{commit}" >/dev/null 2>&1; then
    fail "$kind $rejection origin contains the hook commit"
  fi
  assert_eq "$(out_val "$work/github-output" sha)" "$recorded" \
    "$kind $rejection reported a sha other than the preserved fork"
  assert_eq "$(out_val "$work/github-output" changed)" "true" \
    "$kind $rejection reported an unchanged fork after the hook commit"
  grep -F 'sync-upstream: atomic push rejected; local replay kept; neither remote branch was published' \
    "$work/sync.out" >/dev/null \
    || fail "$kind $rejection did not fail inside the atomic push"
  if [[ "$no_pull" -eq 1 ]]; then
    grep -F 'sync-upstream: not pulling origin; fetched origin/jkubo must already be contained in local jkubo' \
      "$work/sync.out" >/dev/null \
      || fail "$kind $rejection did not take the no-pull path"
  else
    if grep -F 'not pulling origin;' "$work/sync.out" >/dev/null; then
      fail "$kind $rejection default pull logged the no-pull path"
    fi
    grep -F 'sync-upstream: fetched origin/jkubo must already be contained in local jkubo' \
      "$work/sync.out" >/dev/null \
      || fail "$kind $rejection did not take the default pull path"
  fi
  if [[ "$rejection" == "update" ]]; then
    grep -F 'reject refs/heads/main' "$work/sync.out" >/dev/null \
      || fail "$kind $rejection bare update hook did not reject main"
  fi
  assert_clean_git "$work"
  assert_foreign_replay_branch "$work"
  say "$kind $rejection rejection (${sync_args[*]}) keeps the hook commit on jkubo"
}

scenario_replay_hook_keeps_work() {
  local kind="$1"
  shift
  new_sandbox
  local work="$SB_ROOT/work" hook_commit hook_branch hook_tree up
  seed_published "$work"
  git -C "$work" checkout -q --detach "$BASE_SHA"
  if [[ "$kind" == "post-checkout" ]]; then
    printf 'upstream product conflict\n' >"$work/feature.txt"
  else
    printf 'upstream-only\n' >"$work/upstream-only.txt"
  fi
  commit_tree "$work" "upstream move for replay hook"
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream 'HEAD:refs/heads/main'
  git -C "$work" checkout -q jkubo
  pin_foreign_replay_branch "$work"
  mkdir "$SB_ROOT/hook-record"
  cat >"$work/.git/hooks/$kind" <<'EOF'
#!/bin/bash
set -euo pipefail
branch="$(git symbolic-ref --quiet --short HEAD || true)"
[[ "$branch" == jkubo-sync-replay-* ]] || exit 0
[[ ! -f "$SYNC_REPLAY_HOOK_RECORD/oid" ]] || exit 0
printf 'operator replay hook note\n' >USER_NOTE
git add USER_NOTE
git commit -q -m 'operator note on replay branch'
git rev-parse HEAD >"$SYNC_REPLAY_HOOK_RECORD/oid"
printf '%s\n' "$branch" >"$SYNC_REPLAY_HOOK_RECORD/branch"
git write-tree >"$SYNC_REPLAY_HOOK_RECORD/index-tree"
if [[ "$SYNC_REPLAY_HOOK_KIND" == "pre-rebase" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$work/.git/hooks/$kind"
  SYNC_REPLAY_HOOK_KIND="$kind" SYNC_REPLAY_HOOK_RECORD="$SB_ROOT/hook-record" \
    run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail "$kind hook refusal exited $SYNC_RC"; }
  [[ -s "$SB_ROOT/hook-record/oid" ]] || fail "$kind hook did not commit"
  hook_commit="$(cat "$SB_ROOT/hook-record/oid")"
  hook_branch="$(cat "$SB_ROOT/hook-record/branch")"
  hook_tree="$(cat "$SB_ROOT/hook-record/index-tree")"
  assert_eq "$(git -C "$work" rev-parse "refs/heads/$hook_branch")" "$hook_commit" \
    "$kind cleanup deleted or moved the hook's named branch"
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$hook_commit" "$kind cleanup moved HEAD"
  assert_eq "$(git -C "$work" symbolic-ref --short HEAD)" "$hook_branch" "$kind cleanup left the hook branch"
  assert_eq "$(cat "$work/USER_NOTE")" 'operator replay hook note' "$kind cleanup dropped the file"
  assert_eq "$(git -C "$work" write-tree)" "$hook_tree" "$kind cleanup changed the index tree"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$TIP_SHA" "$kind cleanup moved the original fork"
  assert_eq "$(git -C "$work" rev-parse main)" "$BASE_SHA" "$kind cleanup advanced main"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse jkubo)" "$TIP_SHA" "$kind published fork"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse main)" "$BASE_SHA" "$kind published main"
  assert_eq "$(git --git-dir "$SB_ROOT/upstream.git" rev-parse main)" "$up" "$kind moved upstream"
  [[ ! -s "$work/hook-mark" ]] || fail "$kind replay refusal reached push"
  git -C "$work" show-ref --verify --quiet refs/heads/jkubo-sync-replay \
    || fail "$kind cleanup removed a pre-existing branch"
  if [[ "$kind" == "post-checkout" ]]; then
    grep -F 'CONFLICT (add/add): Merge conflict in feature.txt' "$work/sync.out" >/dev/null \
      || { show_sync "$work"; fail "post-checkout fixture did not reach a genuine product conflict"; }
  else
    grep -F 'The pre-rebase hook refused to rebase.' "$work/sync.out" >/dev/null \
      || fail "pre-rebase fixture did not reach the normal hook refusal"
  fi
  assert_clean_git "$work"
  say "$kind replay hook work keeps its named branch, files, and index (${*:-default pull})"
}

scenario_local_ahead_conflict_keeps_work() {
  new_sandbox
  local work="$SB_ROOT/work" base tip original original_tree up
  seed_base "$work"
  mkdir -p "$work/crates/runtime-fixture"
  cat >"$work/crates/runtime-fixture/product.rs" <<'EOF'
const FIRST: &str = "base first";
// spacer 1
// spacer 2
// spacer 3
// spacer 4
// spacer 5
// spacer 6
// spacer 7
// spacer 8
const SECOND: &str = "base second";
EOF
  commit_tree "$work" 'runtime baseline'
  base="$(git -C "$work" rev-parse HEAD)"
  sed -i 's/base first/fork first/' "$work/crates/runtime-fixture/product.rs"
  commit_tree "$work" 'recorded first runtime setting'
  snapshot_product_patch "$work"
  write_tooling_files "$work"
  commit_tree "$work" tooling
  tip="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$base" "$tip"
  printf 'operator unpublished note\n' >"$work/USER_AHEAD_NOTE"
  sed -i 's/base second/operator second/' "$work/crates/runtime-fixture/product.rs"
  commit_tree "$work" 'unpublished note and second runtime setting'
  original="$(git -C "$work" rev-parse HEAD)"
  original_tree="$(git -C "$work" write-tree)"
  git -C "$work" checkout -q --detach "$base"
  sed -i 's/base second/upstream second/' "$work/crates/runtime-fixture/product.rs"
  commit_tree "$work" 'upstream second runtime setting'
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream 'HEAD:refs/heads/main'
  git -C "$work" checkout -q jkubo
  install_hook "$work"
  pin_foreign_replay_branch "$work"
  run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail "local-ahead fallback exited $SYNC_RC"; }
  grep -F 'CONFLICT (content): Merge conflict in crates/runtime-fixture/product.rs' "$work/sync.out" >/dev/null \
    || { show_sync "$work"; fail 'local-ahead fixture did not reach a real runtime conflict'; }
  grep -F 'patch fallback would omit unpublished fork work' "$work/sync.out" >/dev/null \
    || fail 'local-ahead fallback did not explain its refusal'
  if grep -F 'git am ok' "$work/sync.out" >/dev/null; then
    fail 'local-ahead fallback applied a narrower product series'
  fi
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$original" 'local-ahead refusal lost named user commit'
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$original" 'local-ahead refusal moved HEAD'
  assert_eq "$(git -C "$work" symbolic-ref --short HEAD)" jkubo 'local-ahead refusal left jkubo'
  assert_eq "$(cat "$work/USER_AHEAD_NOTE")" 'operator unpublished note' 'local-ahead refusal dropped note'
  assert_eq "$(git -C "$work" write-tree)" "$original_tree" 'local-ahead refusal changed index tree'
  assert_eq "$(git -C "$work" rev-parse main)" "$base" 'local-ahead refusal advanced main'
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse main)" "$base" 'local-ahead refusal published main'
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse jkubo)" "$tip" 'local-ahead refusal published fork'
  assert_eq "$(git --git-dir "$SB_ROOT/upstream.git" rev-parse main)" "$up" 'local-ahead refusal moved upstream'
  [[ ! -s "$work/hook-mark" ]] || fail 'local-ahead refusal reached push'
  assert_clean_git "$work"
  assert_foreign_replay_branch "$work"
  say "local-ahead runtime conflict keeps original commits, note, and index (${*:-default pull})"
}

seed_missing_product() {
  local work="$1"
  seed_published "$work"
  rm "$work/feature.txt"
  commit_tree "$work" 'published product removal requests repair'
  TIP_SHA="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q origin 'HEAD:refs/heads/jkubo'
}

assert_original_remote_heads() {
  local work="$1" tip="$2" base="$3"
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse jkubo)" "$tip" 'failure published fork'
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse main)" "$base" 'failure published main'
  [[ ! -s "$work/hook-mark" ]] || fail 'failure reached normal pre-push hook'
}

scenario_replay_keeps_moved_fork() {
  new_sandbox
  local work="$SB_ROOT/work" moved replay
  seed_published "$work"
  advance_upstream_detached "$work" "$BASE_SHA"
  install_hook "$work"
  mkdir "$SB_ROOT/hook-record"
  cat >"$work/.git/hooks/pre-rebase" <<'EOF'
#!/bin/bash
set -euo pipefail
git worktree add -q "$REPLAY_RECORD/operator" jkubo
printf 'independent operator fork note\n' >"$REPLAY_RECORD/operator/FORK_OPERATOR_NOTE"
git -C "$REPLAY_RECORD/operator" add FORK_OPERATOR_NOTE
git -C "$REPLAY_RECORD/operator" commit -q -m 'independent fork work during replay'
git -C "$REPLAY_RECORD/operator" rev-parse HEAD >"$REPLAY_RECORD/oid"
git worktree remove "$REPLAY_RECORD/operator"
exit 0
EOF
  chmod +x "$work/.git/hooks/pre-rebase"
  REPLAY_RECORD="$SB_ROOT/hook-record" run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail 'moved-fork replay did not refuse'; }
  moved="$(cat "$SB_ROOT/hook-record/oid")"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$moved" 'replay replaced independent fork commit'
  assert_eq "$(git -C "$work" show jkubo:FORK_OPERATOR_NOTE)" 'independent operator fork note' 'fork note lost'
  replay="$(git -C "$work" symbolic-ref --short HEAD)"
  [[ "$replay" == jkubo-sync-replay-* ]] || fail 'rejected replacement lost named replay'
  git -C "$work" show-ref --verify --quiet "refs/heads/$replay" || fail 'replay tip has no named ref'
  [[ "$(git -C "$work" rev-parse "$replay")" != "$moved" ]] || fail 'independent fork replaced replay tip'
  grep -F 'moved after capture; keeping its current ref' "$work/sync.out" >/dev/null \
    || fail 'moved-fork refusal did not explain expected-old check'
  assert_original_remote_heads "$work" "$TIP_SHA" "$BASE_SHA"
  assert_clean_git "$work"
  say "successful replay refuses an independently moved fork (${*:-default pull})"
}

scenario_failed_am_keeps_hook_work() {
  local hook="$1" kind="$2"
  shift 2
  new_sandbox
  local work="$SB_ROOT/work" branch recorded
  seed_missing_product "$work"
  install_hook "$work"
  mkdir "$SB_ROOT/hook-record"
  cat >"$work/.git/hooks/$hook" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'operator am note\n' >AM_OPERATOR_NOTE
git add AM_OPERATOR_NOTE
if [[ "$AM_RECORD_KIND" == commit ]]; then
  git commit -q -m 'operator am hook commit'
fi
git rev-parse HEAD >"$AM_RECORD/oid"
git symbolic-ref --short HEAD >"$AM_RECORD/branch"
git write-tree >"$AM_RECORD/tree"
git ls-files --stage >"$AM_RECORD/stages"
exit 1
EOF
  chmod +x "$work/.git/hooks/$hook"
  AM_RECORD_KIND="$kind" AM_RECORD="$SB_ROOT/hook-record" run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail "$hook $kind failure did not stop"; }
  branch="$(cat "$SB_ROOT/hook-record/branch")"
  recorded="$(cat "$SB_ROOT/hook-record/oid")"
  assert_eq "$(git -C "$work" symbolic-ref --short HEAD)" "$branch" "$hook changed hook branch"
  assert_eq "$(git -C "$work" rev-parse "$branch")" "$recorded" "$hook changed hook tip"
  assert_eq "$(cat "$work/AM_OPERATOR_NOTE")" 'operator am note' "$hook erased note"
  assert_eq "$(git -C "$work" write-tree)" "$(cat "$SB_ROOT/hook-record/tree")" "$hook erased index tree"
  git -C "$work" ls-files --stage >"$SB_ROOT/stages-after"
  cmp "$SB_ROOT/hook-record/stages" "$SB_ROOT/stages-after" || fail "$hook altered complete staged entries"
  [[ -d "$work/.git/rebase-apply" ]] || fail "$hook uncertain am operation was aborted"
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$TIP_SHA" "$hook changed original fork"
  assert_original_remote_heads "$work" "$TIP_SHA" "$BASE_SHA"
  say "$hook $kind refusal keeps named branch/files/index/am state (${*:-default pull})"
}

scenario_restore_failure_stops_publication() {
  new_sandbox
  local work="$SB_ROOT/work"
  seed_missing_product "$work"
  install_hook "$work"
  cat >"$work/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
printf 'normal pre-commit refuses tooling restoration\n' >&2
exit 1
EOF
  chmod +x "$work/.git/hooks/pre-commit"
  run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail 'restore failure was swallowed'; }
  grep -F 'normal pre-commit refuses tooling restoration' "$work/sync.out" >/dev/null \
    || fail 'restore fixture did not invoke normal rejecting hook'
  grep -F 'tooling restoration failed' "$work/sync.out" >/dev/null || fail 'restore failure not propagated'
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$TIP_SHA" 'restore failure replaced original fork'
  [[ "$(git -C "$work" symbolic-ref --short HEAD)" == jkubo-sync-replay-* ]] \
    || fail 'restore failure lost named replay'
  [[ -f "$work/scripts/sync-upstream.sh" ]] || fail 'restore failure lost staged script file'
  [[ -f "$work/.github/workflows/sync-upstream.yml" ]] || fail 'restore failure lost staged workflow file'
  git -C "$work" cat-file -e :scripts/sync-upstream.sh || fail 'restore failure erased staged script'
  git -C "$work" cat-file -e :.github/workflows/sync-upstream.yml || fail 'restore failure erased staged workflow'
  assert_original_remote_heads "$work" "$TIP_SHA" "$BASE_SHA"
  [[ ! -d "$work/.git/rebase-apply" ]] || fail 'successful am left operation despite restoration failure'
  say "rejected tooling restoration retains files/index and never publishes (${*:-default pull})"
}

scenario_generated_identity_is_temporary() {
  new_sandbox
  local work="$SB_ROOT/work" ident config_before config_after
  seed_missing_product "$work"
  git -C "$work" config user.name 'Noncanonical Operator'
  git -C "$work" config user.email operator@example.com
  config_before="$(git -C "$work" config --local --list)"
  install_hook "$work"
  run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 0 ]] || { show_sync "$work"; fail 'identity repair failed'; }
  assert_commit_identity "$work" 'jkubo^' "$CANONICAL_ID" 'generated product'
  assert_commit_identity "$work" jkubo "$CANONICAL_ID" 'generated tooling'
  config_after="$(git -C "$work" config --local --list)"
  assert_eq "$config_after" "$config_before" 'generated identity changed persistent local config'
  assert_eq "$(out_val "$work/github-output" sha)" "$(git --git-dir "$SB_ROOT/origin.git" rev-parse jkubo)" \
    'identity repair exported unpublished sha'
  assert_clean_git "$work"
  say "generated metadata is canonical and operator config is unchanged (${*:-default pull})"
}

scenario_edited_rebase_conflict_is_retained() {
  local kind="$1"
  shift
  new_sandbox
  local work="$SB_ROOT/work" base tip up branch operation_file
  seed_base "$work"
  base="$(git -C "$work" rev-parse HEAD)"
  printf 'product\n' >"$work/feature.txt"
  commit_tree "$work" product
  snapshot_product_patch "$work"
  printf 'fork notes\n' >"$work/notes.txt"
  write_tooling_files "$work"
  commit_tree "$work" tooling
  tip="$(git -C "$work" rev-parse HEAD)"
  publish_fork_at_base "$work" "$base" "$tip"
  git -C "$work" checkout -q --detach "$base"
  printf 'upstream notes\n' >"$work/notes.txt"
  commit_tree "$work" 'upstream conflict'
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream 'HEAD:refs/heads/main'
  git -C "$work" checkout -q jkubo
  install_hook "$work"
  mkdir "$SB_ROOT/hook-record"
  cat >"$work/.git/hooks/post-index-change" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ -d .git/rebase-merge ]] || exit 0
if [[ "$REBASE_RECORD_KIND" != repeated && -f "$REBASE_RECORD/fired" ]]; then
  exit 0
fi
[[ -n "$(git ls-files -u -- notes.txt)" ]] || exit 0
if [[ "$REBASE_RECORD_KIND" == repeated && -z "$(git ls-files -u -- notes.txt | awk '$3 == 1')" ]]; then
  exit 0
fi
: >"$REBASE_RECORD/fired"
if [[ "$REBASE_RECORD_KIND" == stages || "$REBASE_RECORD_KIND" == repeated ]]; then
  git ls-files -u -- notes.txt | awk '$3 != 1' >"$REBASE_RECORD/keep"
  printf '0 0000000000000000000000000000000000000000\tnotes.txt\n' | git update-index --index-info
  git update-index --index-info <"$REBASE_RECORD/keep"
elif [[ "$REBASE_RECORD_KIND" == todo ]]; then
  printf '%s\n' 'exec printf operator-recovery > OPERATOR_RECOVERY_ACTION' >>.git/rebase-merge/git-rebase-todo
else
  printf 'operator conflict-byte edit\n' >notes.txt
fi
git ls-files --stage >"$REBASE_RECORD/index"
if [[ "$REBASE_RECORD_KIND" == todo ]]; then
  git ls-files --stage -v >"$REBASE_RECORD/index-flags"
  cp .git/index "$REBASE_RECORD/raw-index"
  git ls-files -z --deduplicate | while IFS= read -r -d '' path; do
    sha256sum "$path"
  done >"$REBASE_RECORD/raw-files"
fi
cp notes.txt "$REBASE_RECORD/bytes"
mkdir -p "$REBASE_RECORD/operation"
cp -a .git/rebase-merge/. "$REBASE_RECORD/operation/"
git rev-parse HEAD >"$REBASE_RECORD/head"
EOF
  chmod +x "$work/.git/hooks/post-index-change"
  REBASE_RECORD_KIND="$kind" REBASE_RECORD="$SB_ROOT/hook-record" run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail "edited rebase $kind did not refuse"; }
  [[ -f "$SB_ROOT/hook-record/fired" ]] || fail "edited rebase $kind hook did not fire"
  [[ -d "$work/.git/rebase-merge" ]] || fail "edited rebase $kind operation was aborted"
  branch="$(cat "$work/.git/rebase-merge/head-name")"
  [[ "$branch" == refs/heads/jkubo-sync-replay-* ]] || fail 'edited rebase has no named replay'
  git -C "$work" show-ref --verify --quiet "$branch" || fail 'edited replay branch was deleted'
  git -C "$work" ls-files --stage >"$SB_ROOT/index-after"
  cmp "$SB_ROOT/hook-record/index" "$SB_ROOT/index-after" || fail "edited rebase $kind changed index"
  cmp "$SB_ROOT/hook-record/bytes" "$work/notes.txt" || fail "edited rebase $kind changed bytes"
  for operation_file in "$SB_ROOT/hook-record/operation"/*; do
    cmp "$operation_file" "$work/.git/rebase-merge/${operation_file##*/}" \
      || fail "edited rebase $kind changed captured operation metadata"
  done
  if [[ "$kind" == todo ]]; then
    git -C "$work" ls-files --stage -v >"$SB_ROOT/index-flags-after"
    cmp "$SB_ROOT/hook-record/index-flags" "$SB_ROOT/index-flags-after" || fail 'todo changed index flags'
    cmp "$SB_ROOT/hook-record/raw-index" "$work/.git/index" || fail 'todo changed raw index'
    ( cd "$work"
      git ls-files -z --deduplicate | while IFS= read -r -d '' path; do
        sha256sum "$path"
      done
    ) >"$SB_ROOT/raw-files-after"
    cmp "$SB_ROOT/hook-record/raw-files" "$SB_ROOT/raw-files-after" || fail 'todo changed tracked raw files'
    [[ ! -e "$work/OPERATOR_RECOVERY_ACTION" ]] || fail 'operator todo instruction executed'
    grep -Fx 'exec printf operator-recovery > OPERATOR_RECOVERY_ACTION' \
      "$work/.git/rebase-merge/git-rebase-todo" >/dev/null || fail 'valid operator todo was discarded'
    [[ ! -s "$work/hook-mark" ]] || fail 'edited todo reached publication hook'
  fi
  assert_eq "$(git -C "$work" rev-parse HEAD)" "$(cat "$SB_ROOT/hook-record/head")" \
    "edited rebase $kind moved detached HEAD"
  assert_eq "$(git -C "$work" rev-parse "$branch")" "$tip" 'edited replay moved its named tip'
  assert_eq "$(git -C "$work" rev-parse jkubo)" "$tip" 'edited rebase moved original fork'
  assert_eq "$(git -C "$work" rev-parse main)" "$base" 'edited rebase moved main'
  assert_original_remote_heads "$work" "$tip" "$base"
  assert_eq "$(git --git-dir "$SB_ROOT/upstream.git" rev-parse main)" "$up" 'edited rebase moved upstream'
  grep -F 'rebase conflict state is edited or unproven' "$work/sync.out" >/dev/null \
    || fail 'edited rebase did not explain conservative refusal'
  say "edited rebase $kind preserves named branch/operation/index/bytes (${*:-default pull})"
}

# Record the actual hook's complete tracked raw files, index, named heads and
# HEAD. These fixtures use regular files and begin without an operation.
write_raw_record_helper() {
  cat >"$SB_ROOT/raw-record" <<'EOF_RECORD'
#!/bin/bash
set -euo pipefail
out="$1"
mkdir -p "$out"
git for-each-ref --format='%(refname) %(objectname)' refs/heads >"$out/heads"
git symbolic-ref HEAD >"$out/head-name"
git rev-parse HEAD >"$out/head"
git ls-files --stage -v >"$out/index-tuples"
cp .git/index "$out/index"
git ls-files -z --deduplicate | while IFS= read -r -d '' path; do
  stat -c '%a %F' -- "$path"
  sha256sum -- "$path"
done >"$out/raw-files"
for op in rebase-merge rebase-apply sequencer CHERRY_PICK_HEAD REVERT_HEAD MERGE_HEAD; do
  [[ ! -e ".git/$op" ]] || exit 91
done
EOF_RECORD
  chmod +x "$SB_ROOT/raw-record"
}

assert_raw_record() {
  local work="$1" before="$2"
  ( cd "$work"; "$SB_ROOT/raw-record" "$SB_ROOT/raw-after" )
  diff -r "$before" "$SB_ROOT/raw-after" || fail 'raw files/index/named heads/HEAD changed after refusal'
}

scenario_raw_postcheckout_filter_stage() {
  new_sandbox
  local work="$SB_ROOT/work" up
  seed_published "$work"
  git -C "$work" checkout -q --detach "$BASE_SHA"
  printf 'upstream README\n' >"$work/README.md"
  commit_tree "$work" 'upstream README advance'
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream 'HEAD:refs/heads/main'
  git -C "$work" checkout -q jkubo
  git -C "$work" checkout -q -b operator
  git -C "$work" config filter.operator.clean "sed '/^OPERATOR_LOCAL_NOTE /d'"
  git -C "$work" config filter.operator.smudge cat
  printf 'README.md filter=operator\n' >"$work/.git/info/attributes"
  install_hook "$work"
  write_raw_record_helper
  cat >"$work/.git/hooks/post-checkout" <<'EOF_HOOK'
#!/bin/bash
set -euo pipefail
[[ "$(git symbolic-ref -q HEAD || true)" == refs/heads/jkubo ]] || exit 0
[[ ! -e "$RAW_RECORD/fired" ]] || exit 0
mkdir -p "$RAW_RECORD"
: >"$RAW_RECORD/fired"
printf 'OPERATOR_LOCAL_NOTE unique uncommitted post-checkout work\n' >>README.md
cp README.md "$RAW_RECORD/foreign-raw"
git diff --binary >"$RAW_RECORD/normalized-diff"
git add README.md
git status --porcelain --untracked-files=no >"$RAW_RECORD/normalized-status"
"$RAW_HELPER" "$RAW_RECORD/state"
EOF_HOOK
  chmod +x "$work/.git/hooks/post-checkout"
  RAW_RECORD="$SB_ROOT/hook-record" RAW_HELPER="$SB_ROOT/raw-record" run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail 'hidden postcheckout raw work did not refuse'; }
  [[ -f "$SB_ROOT/hook-record/fired" ]] || fail 'normal postcheckout hook did not run'
  [[ ! -s "$SB_ROOT/hook-record/normalized-diff" && ! -s "$SB_ROOT/hook-record/normalized-status" ]] \
    || fail 'normal clean filter plus git add did not hide work'
  cmp "$SB_ROOT/hook-record/foreign-raw" "$work/README.md" || fail 'postcheckout raw note was discarded'
  assert_raw_record "$work" "$SB_ROOT/hook-record/state"
  assert_original_remote_heads "$work" "$TIP_SHA" "$BASE_SHA"
  assert_eq "$(git --git-dir "$SB_ROOT/upstream.git" rev-parse main)" "$up" 'raw refusal moved upstream'
  [[ ! -s "$work/hook-mark" ]] || fail 'hidden raw refusal reached push hook'
  grep -F 'fork checkout changed raw files or index' "$work/sync.out" >/dev/null \
    || fail 'postcheckout refusal did not identify raw uncertainty'
  say "postcheckout filter plus actual git add preserves raw/index/refs (${*:-default pull})"
}

scenario_native_transform_refusal() {
  local kind="$1"
  shift
  new_sandbox
  local work="$SB_ROOT/work" up
  seed_published "$work"
  git -C "$work" checkout -q --detach "$BASE_SHA"
  printf 'upstream README\n' >"$work/README.md"
  if [[ "$kind" == introduced ]]; then
    printf '* text=auto eol=lf\n' >"$work/.gitattributes"
  fi
  commit_tree "$work" 'upstream transform participation'
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream 'HEAD:refs/heads/main'
  git -C "$work" checkout -q jkubo
  if [[ "$kind" == filter ]]; then
    git -C "$work" config filter.operator.clean "sed '/^OPERATOR_LOCAL_NOTE /d'"
    git -C "$work" config filter.operator.smudge cat
    printf 'README.md filter=operator\n' >"$work/.git/info/attributes"
  fi
  install_hook "$work"
  write_raw_record_helper
  ( cd "$work"; "$SB_ROOT/raw-record" "$SB_ROOT/raw-before" )
  # This is the actual pre-rebase raw-loss payload from the old source. The
  # final policy refuses before native replay: this hook must not execute.
  cat >"$work/.git/hooks/pre-rebase" <<'EOF_HOOK'
#!/bin/bash
set -euo pipefail
: >"$NATIVE_TRANSFORM_MARK"
printf 'OPERATOR_LOCAL_NOTE unique uncommitted pre-rebase work\n' >>README.md
git add README.md
exit 0
EOF_HOOK
  chmod +x "$work/.git/hooks/pre-rebase"
  NATIVE_TRANSFORM_MARK="$SB_ROOT/native-hook-fired" run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail "$kind transform did not refuse"; }
  [[ ! -e "$SB_ROOT/native-hook-fired" ]] || fail 'unsupported native replay hook executed'
  assert_raw_record "$work" "$SB_ROOT/raw-before"
  assert_original_remote_heads "$work" "$TIP_SHA" "$BASE_SHA"
  assert_eq "$(git --git-dir "$SB_ROOT/upstream.git" rev-parse main)" "$up" 'transform refusal moved upstream'
  [[ ! -s "$work/hook-mark" ]] || fail 'unsupported transform reached push hook'
  grep -F 'unsupported tracked transform before native replay' "$work/sync.out" >/dev/null \
    || fail 'transform refusal did not explain policy'
  say "$kind native transform refuses before replay; actual hook is unexecuted (${*:-default pull})"
}

scenario_unfiltered_native_hook_control() {
  local kind="$1"
  new_sandbox
  local work="$SB_ROOT/work" up
  seed_published "$work"
  git -C "$work" checkout -q --detach "$BASE_SHA"
  printf 'upstream README\n' >"$work/README.md"
  commit_tree "$work" 'ordinary upstream replay'
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream 'HEAD:refs/heads/main'
  git -C "$work" checkout -q jkubo
  if [[ "$kind" == inactive ]]; then
    git -C "$work" config filter.operator.clean "sed '/^OPERATOR_LOCAL_NOTE /d'"
    git -C "$work" config filter.operator.smudge cat
    printf 'never-tracked-operator-path filter=operator\n' >"$work/.git/info/attributes"
  fi
  install_hook "$work"
  cat >"$work/.git/hooks/pre-rebase" <<'EOF_HOOK'
#!/bin/bash
set -euo pipefail
printf 'native pre-rebase hook ran\n' >"$NATIVE_HOOK_MARK"
EOF_HOOK
  chmod +x "$work/.git/hooks/pre-rebase"
  NATIVE_HOOK_MARK="$SB_ROOT/native-hook-fired" run_sync "$work" --push
  [[ "$SYNC_RC" -eq 0 ]] || { show_sync "$work"; fail "$kind native positive failed"; }
  [[ -s "$SB_ROOT/native-hook-fired" ]] || fail 'normal native pre-rebase hook was bypassed'
  assert_eq "$(cat "$work/README.md")" 'upstream README' 'ordinary replay did not advance tracked file'
  assert_eq "$(git -C "$work" rev-parse main)" "$up" 'ordinary replay did not mirror upstream'
  assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse jkubo)" "$(git -C "$work" rev-parse jkubo)" \
    'ordinary replay did not publish fork'
  [[ -s "$work/hook-mark" ]] || fail 'ordinary replay bypassed push hook'
  assert_clean_git "$work"
  say "$kind normal native hook and advancing publication remain enabled"
}

scenario_ignored_target_collision() {
  new_sandbox
  local work="$SB_ROOT/work" up
  seed_published "$work"
  git -C "$work" checkout -q --detach "$BASE_SHA"
  printf 'upstream-only\n' >"$work/upstream-only.txt"
  commit_tree "$work" 'upstream tracked path introduction'
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream 'HEAD:refs/heads/main'
  git -C "$work" checkout -q jkubo
  printf 'upstream-only.txt\n' >"$work/.git/info/exclude"
  printf 'operator ignored independent raw note\n' >"$work/upstream-only.txt"
  cp "$work/upstream-only.txt" "$SB_ROOT/foreign-raw"
  install_hook "$work"
  write_raw_record_helper
  ( cd "$work"; "$SB_ROOT/raw-record" "$SB_ROOT/raw-before" )
  run_sync "$work" --push "$@"
  [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail 'ignored target collision did not refuse'; }
  cmp "$SB_ROOT/foreign-raw" "$work/upstream-only.txt" || fail 'ignored target file was overwritten'
  assert_raw_record "$work" "$SB_ROOT/raw-before"
  assert_original_remote_heads "$work" "$TIP_SHA" "$BASE_SHA"
  assert_eq "$(git --git-dir "$SB_ROOT/upstream.git" rev-parse main)" "$up" 'collision refusal moved upstream'
  [[ ! -s "$work/hook-mark" ]] || fail 'ignored collision reached publication'
  grep -F 'target would replace independent path' "$work/sync.out" >/dev/null \
    || fail 'collision refusal did not identify independent path'
  say "ignored upstream target collision retains raw/index/refs (${*:-default pull})"
}

scenario_workingtree_attributes() {
  local kind="$1"
  shift
  new_sandbox
  local work="$SB_ROOT/work" up attrs_before config_before
  seed_published "$work"
  git -C "$work" checkout -q --detach "$BASE_SHA"
  printf 'upstream README\n' >"$work/README.md"
  commit_tree "$work" 'upstream workingtree-attributes control'
  up="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" push -q upstream 'HEAD:refs/heads/main'
  git -C "$work" checkout -q jkubo
  git -C "$work" config filter.operator.clean "sed '/^OPERATOR_LOCAL_NOTE /d'"
  git -C "$work" config filter.operator.smudge cat
  if [[ "$kind" == active ]]; then
    printf 'README.md filter=operator\n' >"$work/.gitattributes"
  else
    printf 'never-tracked-operator-path filter=operator\n' >"$work/.gitattributes"
  fi
  printf '.gitattributes\n' >"$work/.git/info/exclude"
  git -C "$work" check-ignore .gitattributes >/dev/null || fail 'local attribute fixture is not ignored'
  [[ -z "$(git -C "$work" ls-files -- .gitattributes)" ]] || fail 'local attributes accidentally tracked'
  attrs_before="$(cat "$work/.gitattributes")"
  config_before="$(git -C "$work" config --local --list)"
  git -C "$work" check-attr filter -- README.md >"$SB_ROOT/native-effective-attr"
  git -C "$work" check-attr --cached filter -- README.md >"$SB_ROOT/cached-effective-attr"
  git -C "$work" check-attr --source="$TIP_SHA" filter -- README.md >"$SB_ROOT/committed-source-attr"
  grep -Fx 'README.md: filter: unspecified' "$SB_ROOT/cached-effective-attr" >/dev/null \
    || fail 'cached query unexpectedly includes untracked local attributes'
  grep -Fx 'README.md: filter: unspecified' "$SB_ROOT/committed-source-attr" >/dev/null \
    || fail 'committed query unexpectedly includes untracked local attributes'
  install_hook "$work"
  write_raw_record_helper
  ( cd "$work"; "$SB_ROOT/raw-record" "$SB_ROOT/raw-before" )
  # Preserve the actual vulnerable hook inputs. The final active case refuses
  # before this hook, so its not-yet-created raw note is not a retention claim.
  if [[ "$kind" == active ]]; then
    grep -Fx 'README.md: filter: operator' "$SB_ROOT/native-effective-attr" >/dev/null \
      || fail 'normal native query did not observe local active attributes'
    cat >"$work/.git/hooks/pre-rebase" <<'EOF_HOOK'
#!/bin/bash
set -euo pipefail
: >"$LOCAL_ATTR_RECORD/hook-ran"
printf 'OPERATOR_LOCAL_NOTE unique uncommitted post-checkout work\n' >>README.md
cp README.md "$LOCAL_ATTR_RECORD/foreign-raw-bytes"
git diff --binary >"$LOCAL_ATTR_RECORD/normalized-diff"
git add README.md
cp .git/index "$LOCAL_ATTR_RECORD/hook-index"
git ls-files --stage -v >"$LOCAL_ATTR_RECORD/hook-index-tuples"
git status --porcelain=v1 --untracked-files=no >"$LOCAL_ATTR_RECORD/hook-normalized-status"
EOF_HOOK
  else
    grep -Fx 'README.md: filter: unspecified' "$SB_ROOT/native-effective-attr" >/dev/null \
      || fail 'inactive attributes applied to a participating tracked path'
    cat >"$work/.git/hooks/pre-rebase" <<'EOF_HOOK'
#!/bin/bash
set -euo pipefail
printf 'actual native pre-rebase hook\n' >"$LOCAL_ATTR_RECORD/hook-ran"
EOF_HOOK
  fi
  mkdir "$SB_ROOT/hook-record"
  chmod +x "$work/.git/hooks/pre-rebase"
  cp "$work/.git/hooks/pre-rebase" "$SB_ROOT/original-hook"
  LOCAL_ATTR_RECORD="$SB_ROOT/hook-record" run_sync "$work" --push "$@"
  if [[ "$kind" == active ]]; then
    [[ "$SYNC_RC" -eq 1 ]] || { show_sync "$work"; fail 'active local attributes did not refuse'; }
    [[ ! -e "$SB_ROOT/hook-record/hook-ran" && ! -e "$SB_ROOT/hook-record/foreign-raw-bytes" ]] \
      || fail 'unsupported local attributes reached vulnerable native hook'
    assert_raw_record "$work" "$SB_ROOT/raw-before"
    assert_original_remote_heads "$work" "$TIP_SHA" "$BASE_SHA"
    [[ ! -s "$work/hook-mark" ]] || fail 'local attributes refusal reached push'
    grep -F 'unsupported tracked transform before native replay' "$work/sync.out" >/dev/null \
      || fail 'local attribute refusal did not explain unsupported input'
  else
    [[ "$SYNC_RC" -eq 0 ]] || { show_sync "$work"; fail 'genuinely inactive local attributes refused'; }
    [[ -s "$SB_ROOT/hook-record/hook-ran" && -s "$work/hook-mark" ]] \
      || fail 'inactive local attributes bypassed native hooks'
    assert_eq "$(cat "$work/README.md")" 'upstream README' 'inactive local-attributes replay did not advance'
    assert_eq "$(git -C "$work" rev-parse main)" "$up" 'inactive local-attributes replay did not mirror'
    assert_eq "$(git --git-dir "$SB_ROOT/origin.git" rev-parse jkubo)" "$(git -C "$work" rev-parse jkubo)" \
      'inactive local-attributes replay did not publish fork'
    assert_clean_git "$work"
  fi
  assert_eq "$(cat "$work/.gitattributes")" "$attrs_before" 'sync changed local ignored attributes'
  assert_eq "$(git -C "$work" config --local --list)" "$config_before" 'sync changed persistent filter/config'
  cmp "$work/.git/hooks/pre-rebase" "$SB_ROOT/original-hook" || fail 'sync altered normal hook input'
  assert_eq "$(git --git-dir "$SB_ROOT/upstream.git" rev-parse main)" "$up" 'local attrs test moved upstream'
  say "$kind actual workingtree attributes (${*:-default pull}) have truthful native replay behavior"
}

scenario_noop
scenario_replay
scenario_fallback_keeps_upstream_workflow
scenario_rollback
scenario_lease
scenario_repair_then_noop
scenario_dirty_preserves_replay_branch
scenario_rebase_preserves_operation
scenario_rebase_allow_dirty_preserves_operation
scenario_am_allow_dirty_preserves_operation
scenario_cherry_pick_allow_dirty_preserves_operation
scenario_merge_allow_dirty_preserves_operation
scenario_revert_allow_dirty_preserves_operation
scenario_replay_branch_collision
scenario_receive_reject refs/heads/main
scenario_receive_reject refs/heads/jkubo
scenario_remote_fork_guard ahead --no-pull-origin
scenario_remote_fork_guard ahead
scenario_remote_fork_guard divergent --no-pull-origin
scenario_remote_fork_guard divergent
scenario_remote_mirror_guard --no-pull-origin
scenario_remote_mirror_guard
scenario_local_mirror_guard ahead --push --no-pull-origin
scenario_local_mirror_guard ahead --push
scenario_local_mirror_guard divergent --push --no-pull-origin
scenario_local_mirror_guard divergent --push
scenario_origin_fetch_failure
scenario_published_sha_survives_local_move noop
scenario_published_sha_survives_local_move replay
scenario_rejected_push_keeps_hook_work noop hook --push
scenario_rejected_push_keeps_hook_work noop hook --push --no-pull-origin
scenario_rejected_push_keeps_hook_work noop update --push
scenario_rejected_push_keeps_hook_work noop update --push --no-pull-origin
scenario_rejected_push_keeps_hook_work replay hook --push
scenario_rejected_push_keeps_hook_work replay hook --push --no-pull-origin
scenario_rejected_push_keeps_hook_work replay update --push
scenario_rejected_push_keeps_hook_work replay update --push --no-pull-origin
scenario_replay_hook_keeps_work pre-rebase
scenario_replay_hook_keeps_work pre-rebase --no-pull-origin
scenario_replay_hook_keeps_work post-checkout
scenario_replay_hook_keeps_work post-checkout --no-pull-origin
scenario_local_ahead_conflict_keeps_work
scenario_local_ahead_conflict_keeps_work --no-pull-origin
scenario_replay_keeps_moved_fork
scenario_replay_keeps_moved_fork --no-pull-origin
scenario_failed_am_keeps_hook_work applypatch-msg staged
scenario_failed_am_keeps_hook_work applypatch-msg staged --no-pull-origin
scenario_failed_am_keeps_hook_work pre-applypatch staged
scenario_failed_am_keeps_hook_work pre-applypatch staged --no-pull-origin
scenario_failed_am_keeps_hook_work applypatch-msg commit
scenario_failed_am_keeps_hook_work applypatch-msg commit --no-pull-origin
scenario_failed_am_keeps_hook_work pre-applypatch commit
scenario_failed_am_keeps_hook_work pre-applypatch commit --no-pull-origin
scenario_restore_failure_stops_publication
scenario_restore_failure_stops_publication --no-pull-origin
scenario_generated_identity_is_temporary
scenario_generated_identity_is_temporary --no-pull-origin
scenario_edited_rebase_conflict_is_retained stages
scenario_edited_rebase_conflict_is_retained stages --no-pull-origin
scenario_edited_rebase_conflict_is_retained bytes
scenario_edited_rebase_conflict_is_retained bytes --no-pull-origin
scenario_edited_rebase_conflict_is_retained repeated
scenario_edited_rebase_conflict_is_retained repeated --no-pull-origin
scenario_edited_rebase_conflict_is_retained todo
scenario_edited_rebase_conflict_is_retained todo --no-pull-origin
scenario_raw_postcheckout_filter_stage
scenario_raw_postcheckout_filter_stage --no-pull-origin
scenario_native_transform_refusal filter
scenario_native_transform_refusal filter --no-pull-origin
scenario_native_transform_refusal introduced
scenario_native_transform_refusal introduced --no-pull-origin
scenario_unfiltered_native_hook_control plain
scenario_unfiltered_native_hook_control inactive
scenario_ignored_target_collision
scenario_ignored_target_collision --no-pull-origin

scenario_workingtree_attributes active
scenario_workingtree_attributes active --no-pull-origin
scenario_workingtree_attributes inactive
say "all sync-upstream regressions passed"
