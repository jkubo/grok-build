#!/usr/bin/env bash
# Rebase the jkubo fork onto xai-org/grok-build and optionally test/build/install.
#
#   ./scripts/sync-upstream.sh                  # fetch + rebase (no push)
#   ./scripts/sync-upstream.sh --push           # also update origin/jkubo + origin/main
#   ./scripts/sync-upstream.sh --build --install
#   ./scripts/sync-upstream.sh --dry-run
#
# `main` stays a fast-forward mirror of upstream. `jkubo` is upstream + the
# product patch (+ fork tooling). Rebase is the happy path; `git am --3way`
# of fork/patches/ is the fallback. Do not PR this at xai-org/grok-build.
set -euo pipefail

FORK_BRANCH="${FORK_BRANCH:-jkubo}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
MIRROR_BRANCH="${MIRROR_BRANCH:-main}"
PATCH_DIR="${PATCH_DIR:-fork/patches}"
STATE_DIR="${GROK_JKUBO_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/grok-jkubo}"

DO_PUSH=0
DO_BUILD=0
DO_INSTALL=0
DO_TEST=0
DO_DRY=0
PULL_ORIGIN=1
ALLOW_DIRTY=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \?//'
  echo "Flags: --push --build --install --test --dry-run --no-pull-origin --allow-dirty"
}

log() { printf 'sync-upstream: %s\n' "$*"; }
die() { printf 'sync-upstream: ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) DO_PUSH=1 ;;
    --build) DO_BUILD=1 ;;
    --install) DO_INSTALL=1 ;;
    --test) DO_TEST=1 ;;
    --dry-run) DO_DRY=1 ;;
    --no-pull-origin) PULL_ORIGIN=0 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d .git ]]; then
  die "not a git repo: $ROOT"
fi

changed=0
emit_github() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    if [[ "$changed" -eq 1 ]]; then
      echo "changed=true" >>"$GITHUB_OUTPUT"
    else
      echo "changed=false" >>"$GITHUB_OUTPUT"
    fi
    echo "sha=$(git rev-parse HEAD)" >>"$GITHUB_OUTPUT"
    echo "upstream=$(git rev-parse "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || true)" >>"$GITHUB_OUTPUT"
  fi
}
trap emit_github EXIT

require_clean() {
  if [[ "$ALLOW_DIRTY" -eq 1 ]]; then
    return 0
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    die "worktree dirty; commit/stash or pass --allow-dirty"
  fi
}

ensure_remote() {
  local name="$1" url="$2"
  if git remote get-url "$name" >/dev/null 2>&1; then
    return 0
  fi
  git remote add "$name" "$url"
}

ensure_identity() {
  if git config user.email >/dev/null && git config user.name >/dev/null; then
    return 0
  fi
  git config user.name "jkubo-sync"
  git config user.email "jkubo@users.noreply.github.com"
}

copy_patches() {
  local dest="$1"
  mkdir -p "$dest"
  local series="${ROOT}/fork/series"
  if [[ -f "$series" ]]; then
    while read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      [[ -f "${ROOT}/${PATCH_DIR}/${line}" ]] || die "missing patch ${line}"
      cp "${ROOT}/${PATCH_DIR}/${line}" "$dest/"
    done <"$series"
  else
    cp "${ROOT}/${PATCH_DIR}"/*.patch "$dest/" 2>/dev/null || die "no patches in ${PATCH_DIR}"
  fi
}

restore_tooling() {
  local src_tree="$1"
  git checkout "$src_tree" -- \
    FORK.md \
    scripts/sync-upstream.sh \
    fork \
    .github \
    2>/dev/null || true
  if ! git diff --cached --quiet -- FORK.md scripts/sync-upstream.sh fork .github 2>/dev/null; then
    ensure_identity
    git add FORK.md scripts/sync-upstream.sh fork .github 2>/dev/null || true
    git commit -m "chore(fork): restore sync tooling after patch fallback"
  fi
}

pager_version() {
  sed -n 's/^version = "\([0-9][^"]*\)"/\1/p' \
    crates/codegen/xai-grok-pager-bin/Cargo.toml | head -n1
}

fork_version() {
  local v
  v="$(pager_version)"
  [[ -n "$v" ]] || die "could not read pager-bin version"
  printf '%s-jkubo' "$v"
}

notify_fail() {
  local msg="$1"
  mkdir -p "$STATE_DIR"
  printf '%s %s\n' "$(date -Is)" "$msg" >>"${STATE_DIR}/sync.log"
  if command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    notify-send --urgency=critical "grok-jkubo sync failed" "$msg" || true
  fi
}

require_clean
ensure_remote "$UPSTREAM_REMOTE" "https://github.com/xai-org/grok-build.git"
ensure_remote "$ORIGIN_REMOTE" "https://github.com/jkubo/grok-build.git"

log "fetch ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH} + ${ORIGIN_REMOTE}"
git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" --prune
git fetch "$ORIGIN_REMOTE" --prune || true

UPSTREAM_SHA="$(git rev-parse "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}")"
log "upstream ${UPSTREAM_SHA:0:12} $(git log -1 --format=%s "$UPSTREAM_SHA")"

# Stay on / create the integration branch.
if git show-ref --verify --quiet "refs/heads/${FORK_BRANCH}"; then
  git checkout "$FORK_BRANCH"
else
  log "creating local branch ${FORK_BRANCH}"
  git checkout -b "$FORK_BRANCH"
fi

PRE_SHA="$(git rev-parse HEAD)"
LEASE_SHA=""
if git show-ref --verify --quiet "refs/remotes/${ORIGIN_REMOTE}/${FORK_BRANCH}"; then
  LEASE_SHA="$(git rev-parse "${ORIGIN_REMOTE}/${FORK_BRANCH}")"
fi

if [[ "$PULL_ORIGIN" -eq 1 ]] && [[ -n "$LEASE_SHA" ]]; then
  ORIGIN_SHA="$LEASE_SHA"
  if git merge-base --is-ancestor "$UPSTREAM_SHA" "$ORIGIN_SHA"; then
    if [[ "$PRE_SHA" != "$ORIGIN_SHA" ]]; then
      log "origin/${FORK_BRANCH} already contains latest upstream; fast-forward"
      if [[ "$DO_DRY" -eq 1 ]]; then
        log "dry-run: would ff to ${ORIGIN_SHA:0:12}"
      else
        git merge --ff-only "$ORIGIN_SHA"
        PRE_SHA="$(git rev-parse HEAD)"
      fi
    fi
  else
    log "origin/${FORK_BRANCH} is behind upstream; rebasing locally"
  fi
fi

HEAD_SHA="$(git rev-parse HEAD)"
if git merge-base --is-ancestor "$UPSTREAM_SHA" "$HEAD_SHA"; then
  log "already based on latest upstream"
else
  changed=1
  log "rebase ${FORK_BRANCH} onto ${UPSTREAM_SHA:0:12}"
  if [[ "$DO_DRY" -eq 1 ]]; then
    log "dry-run: would rebase $(git rev-list --count "${UPSTREAM_SHA}..HEAD") commit(s)"
  else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"; emit_github' EXIT
    copy_patches "$tmp/patches"
    tooling_src="$HEAD_SHA"
    if git rebase "$UPSTREAM_SHA"; then
      log "rebase ok → $(git rev-parse --short HEAD)"
    else
      log "rebase conflict; falling back to git am --3way"
      git rebase --abort
      git checkout -B "$FORK_BRANCH" "$UPSTREAM_SHA"
      shopt -s nullglob
      patches=("$tmp/patches"/*.patch)
      shopt -u nullglob
      [[ ${#patches[@]} -gt 0 ]] || {
        notify_fail "no patches to am after rebase conflict"
        git checkout "$PRE_SHA"
        git checkout -B "$FORK_BRANCH" "$PRE_SHA"
        die "rebase failed and ${PATCH_DIR} was empty"
      }
      if git am --3way "${patches[@]}"; then
        log "git am ok → $(git rev-parse --short HEAD)"
        restore_tooling "$tooling_src"
      else
        git am --abort || true
        git checkout -B "$FORK_BRANCH" "$PRE_SHA"
        notify_fail "rebase and git am both failed on ${UPSTREAM_SHA:0:12}"
        die "could not replay fork patches onto upstream (resolve in a checkout, then --push)"
      fi
    fi
  fi
fi

# Mirror branch: exact upstream, never our delta.
if [[ "$DO_DRY" -eq 0 ]]; then
  git branch -f "$MIRROR_BRANCH" "$UPSTREAM_SHA"
fi

HEAD_SHA="$(git rev-parse HEAD)"
if [[ "$HEAD_SHA" != "$PRE_SHA" ]]; then
  changed=1
fi

push_fork() {
  if [[ "$DO_PUSH" -ne 1 ]]; then
    return 0
  fi
  if [[ "$DO_DRY" -eq 1 ]]; then
    log "dry-run: would push ${FORK_BRANCH} and ${MIRROR_BRANCH}"
    return 0
  fi
  # --no-verify: this tree contains upstream RFC 6598 (100.64/10) tests; the
  # local GitHub pre-push hook treats 100.x as Tailscale and blocks ancestry.
  log "push ${MIRROR_BRANCH} (upstream mirror)"
  if ! git push --no-verify "$ORIGIN_REMOTE" "${UPSTREAM_SHA}:refs/heads/${MIRROR_BRANCH}"; then
    git push --no-verify --force-with-lease "$ORIGIN_REMOTE" "${UPSTREAM_SHA}:refs/heads/${MIRROR_BRANCH}"
  fi
  log "push ${FORK_BRANCH} (force-with-lease)"
  if [[ -n "$LEASE_SHA" ]]; then
    git push --no-verify --force-with-lease="${FORK_BRANCH}:${LEASE_SHA}" "$ORIGIN_REMOTE" "$FORK_BRANCH"
  else
    git push --no-verify -u "$ORIGIN_REMOTE" "$FORK_BRANCH"
  fi
}

if [[ "$DO_TEST" -eq 1 ]]; then
  command -v cargo >/dev/null || die "cargo not on PATH"
  log "test hook + rename"
  cargo test -p xai-grok-hooks --lib
  cargo test -p xai-grok-shell --lib -- rename_pins_manual
fi

if [[ "$DO_BUILD" -eq 1 || "$DO_INSTALL" -eq 1 ]]; then
  mkdir -p "$STATE_DIR"
  last="${STATE_DIR}/built-sha"
  need_build=1
  if [[ -f "$last" && "$(cat "$last")" == "$HEAD_SHA" && -x target/release/xai-grok-pager ]]; then
    need_build=0
    log "release binary already built for ${HEAD_SHA:0:12}"
  fi
  if [[ "$need_build" -eq 1 ]]; then
    command -v cargo >/dev/null || die "cargo not on PATH"
    ver="$(fork_version)"
    log "build GROK_VERSION=${ver}"
    if [[ "$DO_DRY" -eq 1 ]]; then
      log "dry-run: would cargo build -p xai-grok-pager-bin --release"
    else
      GROK_VERSION="$ver" cargo build -p xai-grok-pager-bin --release
      printf '%s\n' "$HEAD_SHA" >"$last"
    fi
  fi
fi

if [[ "$DO_INSTALL" -eq 1 ]]; then
  bin="${ROOT}/target/release/xai-grok-pager"
  dest="${GROK_JKUBO_BIN:-$HOME/.local/bin/grok-jkubo}"
  [[ -x "$bin" ]] || die "missing ${bin}; pass --build"
  if [[ "$DO_DRY" -eq 1 ]]; then
    log "dry-run: would install ${bin} → ${dest}"
  else
    install -m 755 "$bin" "$dest"
    log "installed ${dest} ($("$dest" --version 2>/dev/null || echo ok))"
    log "running TUI processes keep the old ELF until relaunch"
  fi
fi

push_rc=0
push_fork || push_rc=$?
if [[ "$push_rc" -ne 0 ]]; then
  if [[ "$DO_BUILD" -eq 1 || "$DO_INSTALL" -eq 1 ]]; then
    log "push failed (local build/install kept)"
  else
    die "push failed"
  fi
fi

log "HEAD $(git rev-parse --short HEAD) changed=${changed} version=$(fork_version)"
