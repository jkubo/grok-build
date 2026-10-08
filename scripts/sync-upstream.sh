#!/usr/bin/env bash
# Rebase the jkubo fork onto xai-org/grok-build and optionally test/build/install.
#
#   ./scripts/sync-upstream.sh                  # fetch + rebase (no push)
#   ./scripts/sync-upstream.sh --push           # atomically update origin/jkubo and origin/main
#   ./scripts/sync-upstream.sh --build --install
#   ./scripts/sync-upstream.sh --dry-run
#
# `main` stays an exact mirror of upstream. `jkubo` is upstream plus the
# product patch and fork tooling. Remote-only fork or mirror work, and
# unpublished local main, are refused before any branch moves.
# Do not PR this at xai-org/grok-build.
# Preflight refusals (dirty tree, an in-progress rebase/am/cherry-pick/merge/
# revert, or an existing replay branch name) return before fetch. They do not
# abort, delete, or reset refs or operation state this invocation did not
# create. --allow-dirty does not skip the in-progress operation check.
# A rejected push after a verified no-op did not replay the named fork, so
# it must not move that ref. Failed replay cleanup aborts or deletes only
# operations and temporary refs this invocation created.
set -euo pipefail

# Replay checks out other commits over this file. Run from a private copy so
# bash does not keep reading a path git is replacing.
if [[ -z "${SYNC_UPSTREAM_REEXEC:-}" ]]; then
  SYNC_UPSTREAM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  SYNC_UPSTREAM_REEXEC_PATH="$(mktemp)"
  cp "$0" "$SYNC_UPSTREAM_REEXEC_PATH"
  chmod +x "$SYNC_UPSTREAM_REEXEC_PATH"
  export SYNC_UPSTREAM_REEXEC=1
  export SYNC_UPSTREAM_ROOT
  export SYNC_UPSTREAM_REEXEC_PATH
  exec bash "$SYNC_UPSTREAM_REEXEC_PATH" "$@"
fi
cleanup_reexec() {
  if [[ -n "${SYNC_UPSTREAM_REEXEC_PATH:-}" ]]; then
    rm -f "$SYNC_UPSTREAM_REEXEC_PATH"
  fi
}
trap cleanup_reexec EXIT

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

# Set once a replay has moved FORK_BRANCH. Push failure must not undo that.
REPLAY_COMMITTED=0
# Cleanup may abort or delete only replay state this invocation created.
CREATED_REPLAY_BRANCH=0
REPLAY_BASE_SHA=""
OWNS_REBASE=0
OWNS_AM=0
# Failed or partial am and restoration state may contain hook work. Keep it
# on the named replay branch for inspection instead of guessing ownership.
RETAIN_REPLAY_STATE=0
PRE_SHA=""
UPSTREAM_SHA=""
PRESERVED_FORK_BRANCH=""
# Set only after an atomic push of this exact oid exits 0. The test-job sha
# stays on this value even if a pre-push hook then moves the local fork ref.
PUBLISHED_FORK_SHA=""
RAW_SNAPSHOT_DIR=""
changed=0
fork_lease=""
mirror_lease=""

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

ROOT="${SYNC_UPSTREAM_ROOT}"
cd "$ROOT"

if [[ ! -d .git ]]; then
  die "not a git repo: $ROOT"
fi

# Fork-owned paths restored after an am fallback. Never the whole .github tree:
# upstream workflows that arrived with the new base have to stay.
TOOLING_PATHS=(
  FORK.md
  scripts/sync-upstream.sh
  scripts/install-sync-timer.sh
  scripts/test-sync-upstream.sh
  fork
  .github/workflows/sync-upstream.yml
)

abort_owned_operations() {
  local git_dir
  if [[ "$RETAIN_REPLAY_STATE" -eq 1 || "$OWNS_AM" -eq 1 ]]; then
    RETAIN_REPLAY_STATE=1
    return 0
  fi
  git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" ]] || return 0
  if [[ "$OWNS_REBASE" -eq 1 ]]; then
    if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
      if ! rebase_conflict_is_unchanged; then
        RETAIN_REPLAY_STATE=1
        log "rebase conflict state is edited or unproven; keeping files, index and operation for inspection"
        return 0
      fi
      if ! git rebase --abort; then
        RETAIN_REPLAY_STATE=1
        log "rebase abort failed; keeping replay state for inspection"
        return 0
      fi
    fi
    if [[ ! -d "$git_dir/rebase-merge" && ! -d "$git_dir/rebase-apply" ]]; then
      OWNS_REBASE=0
    fi
  fi
}

# Return to the named fork without rewriting its ref. Independently moved
# refs and uncertain replay files/index/operations are left in place.
checkout_fork_pre_sha() {
  local current="" head_name=""
  [[ "$RETAIN_REPLAY_STATE" -ne 1 ]] || return 0
  [[ -n "$PRE_SHA" ]] || return 0
  current="$(git rev-parse --verify --quiet "refs/heads/${FORK_BRANCH}" 2>/dev/null || true)"
  head_name="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if ! raw_require clean "$(git rev-parse HEAD)"; then return 0; fi
  if replay_has_independent_work; then
    log "keeping independent work on ${REPLAY_BRANCH}; HEAD and files left in place"
    return 0
  fi
  if [[ "$head_name" == "$REPLAY_BRANCH" && -n "$(git status --porcelain --untracked-files=no)" ]]; then
    log "keeping uncommitted work on ${REPLAY_BRANCH}; HEAD and files left in place"
    return 0
  fi
  if [[ -n "$current" && "$current" != "$PRE_SHA" ]]; then
    if [[ "$head_name" == "$FORK_BRANCH" ]]; then
      return 0
    fi
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
      return 0
    fi
    raw_require collision "$current" || return 0
    git checkout "$FORK_BRANCH" || { RETAIN_REPLAY_STATE=1; return 1; }
    raw_require clean "$current" || return 0
    return
  fi
  if [[ "$head_name" == "$FORK_BRANCH" && -n "$(git status --porcelain --untracked-files=no)" ]]; then
    return 0
  fi
  [[ -n "$current" ]] || return 0
  raw_require collision "$current" || return 0
  git checkout "$FORK_BRANCH" || { RETAIN_REPLAY_STATE=1; return 1; }
  raw_require clean "$current" || return 0
}

on_exit() {
  local rc=$?
  set +e
  abort_owned_operations
  # A committed replay stays, including when the push is rejected. A no-op
  # never creates a replay branch, so there is no owned fork state to undo:
  # a hook commit made during the rejected push keeps its ref, files, and index.
  if [[ "$rc" -ne 0 && "$REPLAY_COMMITTED" -ne 1 && "$RETAIN_REPLAY_STATE" -ne 1 && -n "$PRE_SHA" ]]; then
    if [[ "$CREATED_REPLAY_BRANCH" -eq 1 || "$OWNS_REBASE" -eq 1 || "$OWNS_AM" -eq 1 ]]; then
      checkout_fork_pre_sha
      abort_owned_operations
      checkout_fork_pre_sha
    fi
  fi
  drop_replay_branch
  if [[ -n "$RAW_SNAPSHOT_DIR" ]]; then rm -rf "$RAW_SNAPSHOT_DIR"; fi
  if [[ -n "${SYNC_UPSTREAM_REEXEC_PATH:-}" ]]; then
    rm -f "$SYNC_UPSTREAM_REEXEC_PATH"
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    local branch_sha=""
    # Successful push: report the captured oid that was uploaded. Re-reading
    # the branch would publish a hook's later local commit, which origin does
    # not contain. The hook's ref is left where the hook moved it.
    if [[ -n "$PUBLISHED_FORK_SHA" ]]; then
      branch_sha="$PUBLISHED_FORK_SHA"
    else
      branch_sha="$(git rev-parse "refs/heads/${FORK_BRANCH}" 2>/dev/null || true)"
    fi
    if [[ -n "$PRE_SHA" && -n "$branch_sha" && "$branch_sha" != "$PRE_SHA" ]]; then
      changed=1
    else
      changed=0
    fi
    if [[ "$changed" -eq 1 ]]; then
      printf 'changed=true\n' >>"$GITHUB_OUTPUT"
    else
      printf 'changed=false\n' >>"$GITHUB_OUTPUT"
    fi
    # The sha the test job checks out. After a successful push this is the
    # captured fork oid that was published. With no successful push it is the
    # fork branch tip: the patched commit when replay succeeded and the
    # previous tip when it did not.
    printf 'sha=%s\n' "$branch_sha" >>"$GITHUB_OUTPUT"
    local upstream_out=""
    upstream_out="$(git rev-parse "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || true)"
    printf 'upstream=%s\n' "$upstream_out" >>"$GITHUB_OUTPUT"
  fi
  exit "$rc"
}
trap on_exit EXIT

# Raw proof never asks a clean filter to characterize operator files. Native Git
# lists committed objects once; Python reads each file without following links.
# Unknown types, modified index flags, transforms and unstable reads refuse.
raw_state() {
  python3 - "$@" <<'PY'
import hashlib, json, os, stat, subprocess, sys

def git(*args, data=None):
    return subprocess.run(['git', *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True).stdout

def tree(oid):
    return entries(git('ls-tree', '-r', '-z', oid))

def entries(data):
    result = {}
    for row in data.split(b'\0'):
        if not row: continue
        meta, path = row.split(b'\t', 1)
        mode, kind, oid = meta.split()
        if kind != b'blob' or mode not in (b'100644', b'100755', b'120000'):
            raise ValueError('unsupported tracked type')
        if path.startswith(b'/') or any(p in (b'', b'.', b'..') for p in path.split(b'/')):
            raise ValueError('unsupported tracked path')
        result[path] = (mode, oid)
    return result

def stamp(s):
    return (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns,
            s.st_ctime_ns, s.st_nlink)

root = os.open(b'.', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
algorithm = git('rev-parse', '--show-object-format').strip().decode('ascii')

def raw(path):
    parent = os.dup(root)
    held = []
    try:
        parts = path.split(b'/')
        for component in parts[:-1]:
            before = os.stat(component, dir_fd=parent, follow_symlinks=False)
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=parent)
            if stamp(before) != stamp(os.fstat(child)): raise ValueError('directory changed')
            held.append((parent, component, stamp(before)))
            parent = child
        name = parts[-1]
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            data = os.readlink(name, dir_fd=parent)
            if isinstance(data, str): data = os.fsencode(data)
            mode = b'120000'
            digest = hashlib.new(algorithm, b'blob ' + str(len(data)).encode() + b'\0' + data)
        elif stat.S_ISREG(before.st_mode):
            mode = b'100755' if before.st_mode & 0o111 else b'100644'
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            try:
                if stamp(before) != stamp(os.fstat(fd)): raise ValueError('file changed')
                digest = hashlib.new(algorithm, b'blob ' + str(before.st_size).encode() + b'\0')
                size = 0
                while True:
                    block = os.read(fd, 1024 * 1024)
                    if not block: break
                    size += len(block); digest.update(block)
                if size != before.st_size or stamp(before) != stamp(os.fstat(fd)):
                    raise ValueError('file changed while reading')
            finally: os.close(fd)
        else: raise ValueError('unsupported worktree type')
        if stamp(before) != stamp(os.stat(name, dir_fd=parent, follow_symlinks=False)):
            raise ValueError('path changed while reading')
        for fd, name, expected in held:
            if stamp(os.stat(name, dir_fd=fd, follow_symlinks=False)) != expected:
                raise ValueError('parent changed while reading')
        return mode, digest.hexdigest().encode(), stamp(before)
    finally:
        os.close(parent)
        for fd, _, _ in held: os.close(fd)

def raw_match(expected):
    for path, value in expected.items():
        if raw(path)[:2] != value: raise ValueError('raw tracked bytes differ: ' + os.fsdecode(path))

def index_match(expected):
    actual = {}
    for row in git('ls-files', '--stage', '-v', '-z').split(b'\0'):
        if not row: continue
        meta, path = row.split(b'\t', 1)
        tag, mode, oid, stage = meta.split()
        if tag != b'H' or stage != b'0': raise ValueError('uncertain index flags or stages')
        actual[path] = (mode, oid)
    if actual != expected: raise ValueError('index differs from expected committed entries')

def overlay(base, source, paths):
    expected = tree(base); incoming = tree(source)
    for scope in paths:
        scope = os.fsencode(scope)
        picked = {p: v for p, v in incoming.items() if p == scope or p.startswith(scope + b'/')}
        # checkout's default overlay retains entries absent from the source.
        for path, value in picked.items():
            for old in list(expected):
                if old.startswith(path + b'/') or path.startswith(old + b'/'): del expected[old]
            expected[path] = value
    return expected

def collision(target, current=None):
    if current is None: current = tree('HEAD')
    for path in target:
        if path in current: continue
        parts = path.split(b'/')
        for n in range(1, len(parts) + 1):
            prefix = b'/'.join(parts[:n])
            try: value = os.lstat(prefix)
            except FileNotFoundError: break
            if n == len(parts) or not stat.S_ISDIR(value.st_mode):
                # A tracked ancestor is already proven; unknown leaves are not.
                if prefix not in current:
                    raise ValueError('target would replace independent path: ' + os.fsdecode(prefix))
                break

def fingerprint():
    tracked = tree('HEAD')
    files = []
    for p in sorted(tracked):
        mode, oid, provenance = raw(p)
        files.append((p.hex(), (mode.decode(), oid.decode()), provenance))
    git_dir = os.fsdecode(git('rev-parse', '--absolute-git-dir').strip())
    ops = {}
    names = ('index', 'HEAD', 'ORIG_HEAD', 'REBASE_HEAD', 'AUTO_MERGE', 'MERGE_MSG',
             'MERGE_HEAD', 'MERGE_MODE', 'CHERRY_PICK_HEAD', 'REVERT_HEAD',
             'MERGE_AUTOSTASH', 'SQUASH_MSG', 'MERGE_RR', 'rebase-merge', 'rebase-apply', 'sequencer')
    for name in names:
        p = os.path.join(git_dir, name)
        if not os.path.lexists(p): continue
        if stat.S_ISLNK(os.lstat(p).st_mode): raise ValueError('unsupported operation link')
        for folder, dirs, leaves in os.walk(p, followlinks=False) if os.path.isdir(p) else [(git_dir, [], [name])]:
            for entry in dirs + leaves:
                actual = os.path.join(folder, entry); info = os.lstat(actual)
                if stat.S_ISREG(info.st_mode):
                    fd = os.open(actual, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    try:
                        if stamp(info) != stamp(os.fstat(fd)): raise ValueError('operation entry changed')
                        with os.fdopen(fd, 'rb', closefd=False) as f: payload = f.read()
                        if stamp(info) != stamp(os.fstat(fd)): raise ValueError('operation entry changed')
                    finally: os.close(fd)
                elif stat.S_ISDIR(info.st_mode): payload = b''
                else: raise ValueError('unsupported operation entry')
                if stamp(info) != stamp(os.lstat(actual)): raise ValueError('operation entry changed')
                ops[os.path.relpath(actual, git_dir)] = (stamp(info), hashlib.sha256(payload).hexdigest())
    return {'files': files, 'operations': ops,
            'heads': git('for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads').decode(),
            'head': git('rev-parse', 'HEAD').decode()}

def participation(tips):
    commits = list(dict.fromkeys(tips + git('rev-list', tips[0] + '..' + tips[1]).decode().splitlines()))
    paths = sorted(set().union(*(tree(c) for c in commits)))
    return commits, paths

def transforms(tips):
    commits, paths = participation(tips)
    cache = {}
    def configured(key):
        if key not in cache:
            cfg = subprocess.run(['git', 'config', '--get', key], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
            if cfg.returncode not in (0, 1) or cfg.stderr:
                raise ValueError('uncertain native config query')
            cache[key] = cfg.stdout.strip() if cfg.returncode == 0 else b''
        return cache[key]
    autocrlf = configured('core.autocrlf').lower()
    if autocrlf and autocrlf not in (b'false', b'no', b'0', b'off'):
        raise ValueError('active core.autocrlf')
    attrs = ('filter', 'working-tree-encoding', 'ident', 'text', 'eol')
    payload = b'\0'.join(paths) + b'\0'
    wanted = {(path, name.encode()) for path in paths for name in attrs}
    # Default resolution includes ignored/untracked per-directory attributes.
    # Cached resolution covers index fallback; committed sources cover target
    # and replay handoffs. info/global precedence is native in every query.
    sources = [(), ('--cached',)] + [('--source=' + commit,) for commit in commits]
    for source in sources:
        query = subprocess.run(['git', 'check-attr', *source, '-z', '--stdin', *attrs],
                               input=payload, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, check=True)
        if query.stderr: raise ValueError('uncertain native attribute resolution')
        values = query.stdout.split(b'\0')
        if not values or values[-1] or len(values) != 3 * len(wanted) + 1:
            raise ValueError('incomplete native attribute resolution')
        seen = set()
        for n in range(0, len(values) - 1, 3):
            path, name, value = values[n:n + 3]
            key = (path, name)
            if key not in wanted or key in seen:
                raise ValueError('unknown native attribute resolution')
            seen.add(key)
            if value in (b'unspecified', b'unset'): continue
            if name == b'filter':
                driver = 'filter.' + os.fsdecode(value)
                for setting in ('clean', 'smudge', 'process'):
                    if configured(driver + '.' + setting):
                        raise ValueError('active tracked filter: ' + os.fsdecode(path))
                required = configured(driver + '.required').lower()
                if required and required not in (b'false', b'no', b'0', b'off'):
                    raise ValueError('unproven required tracked filter: ' + os.fsdecode(path))
            else: raise ValueError('active tracked transform: ' + os.fsdecode(path))
        if seen != wanted: raise ValueError('incomplete native attribute resolution')

try:
    command, *args = sys.argv[1:]
    if command == 'clean':
        expected = tree(args[0]); index_match(expected); raw_match(expected)
    elif command == 'entries': raw_match(entries(open(args[0], 'rb').read()))
    elif command == 'overlay':
        expected = overlay(*args[:2], args[2:]); index_match(expected); raw_match(expected)
    elif command == 'collision': collision(tree(args[0]))
    elif command == 'overlay-collision':
        collision(overlay(*args[:2], args[2:]), overlay(*args[:2], args[2:-1]))
    elif command == 'snapshot':
        with open(args[0], 'w') as f: json.dump(fingerprint(), f, sort_keys=True)
    elif command == 'unchanged':
        if json.loads(json.dumps(fingerprint())) != json.load(open(args[0])):
            raise ValueError('captured raw files/index/heads/operations changed')
    elif command == 'replay-collision': collision(dict.fromkeys(participation(args)[1]))
    elif command == 'transforms': transforms(args)
    else: raise ValueError('unknown raw proof mode')
except (OSError, ValueError, subprocess.CalledProcessError) as e:
    print('sync-upstream: raw proof refused: ' + str(e), file=sys.stderr)
    sys.exit(1)
finally: os.close(root)
PY
}

raw_require() {
  if ! raw_state "$@"; then
    RETAIN_REPLAY_STATE=1
    log "raw files, index or transition are unproven; keeping current state without push"
    return 1
  fi
}

refuse_replay_transforms() {
  local accepted_tip="${1:-$PRE_SHA}"
  raw_require replay-collision "$UPSTREAM_SHA" "$accepted_tip" || die "native replay paths collide with independent files"
  if ! raw_state transforms "$UPSTREAM_SHA" "$accepted_tip"; then
    RETAIN_REPLAY_STATE=1
    die "unsupported tracked transform before native replay; current files, index and refs retained without push"
  fi
}
require_clean() {
  if [[ "$ALLOW_DIRTY" -eq 1 ]]; then
    return 0
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    die "worktree dirty; commit/stash or pass --allow-dirty"
  fi
}

# Runs before fetch. A pre-existing operation is left exactly as found,
# including when --allow-dirty was passed.
refuse_existing_git_operation() {
  local git_dir kind
  git_dir="$(git rev-parse --absolute-git-dir)"
  kind=""
  if [[ -d "$git_dir/rebase-merge" ]]; then
    kind="rebase"
  elif [[ -d "$git_dir/rebase-apply" ]]; then
    if [[ -f "$git_dir/rebase-apply/applying" ]]; then
      kind="am"
    else
      kind="rebase"
    fi
  elif [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
    kind="cherry-pick"
  elif [[ -f "$git_dir/REVERT_HEAD" ]]; then
    kind="revert"
  elif [[ -f "$git_dir/MERGE_HEAD" ]]; then
    kind="merge"
  elif [[ -d "$git_dir/sequencer" ]]; then
    kind="cherry-pick or revert"
  fi
  if [[ -n "$kind" ]]; then
    die "${kind} already in progress; refusing to abort it"
  fi
}

# Unset REPLAY_BRANCH allocates a name this process owns. An explicit name
# that already exists is refused before any ref is moved.
prepare_replay_branch() {
  local i name
  if [[ -z "${REPLAY_BRANCH:-}" ]]; then
    for i in 1 2 3 4 5 6 7 8; do
      name="jkubo-sync-replay-${BASHPID:-$$}-${RANDOM}${RANDOM}"
      if ! git show-ref --verify --quiet "refs/heads/${name}"; then
        REPLAY_BRANCH="$name"
        return 0
      fi
    done
    die "could not allocate an unused replay branch name"
  fi
  if git show-ref --verify --quiet "refs/heads/${REPLAY_BRANCH}"; then
    die "replay branch ${REPLAY_BRANCH} already exists; refusing to change it"
  fi
}

ensure_remote() {
  local name="$1" url="$2"
  if git remote get-url "$name" >/dev/null 2>&1; then
    return 0
  fi
  git remote add "$name" "$url"
}

generated_git() {
  # am and rebase retain their input authors. Generated tooling uses these
  # author/committer values without changing the operator's persistent config.
  GIT_AUTHOR_NAME="Jay Kubo" GIT_AUTHOR_EMAIL="6161465+jkubo@users.noreply.github.com" \
    GIT_COMMITTER_NAME="Jay Kubo" GIT_COMMITTER_EMAIL="6161465+jkubo@users.noreply.github.com" \
    git "$@"
}

copy_patches() {
  local dest="$1" series line
  mkdir -p "$dest" || return 1
  : >"${dest}/order" || return 1
  series="${ROOT}/fork/series"
  if [[ -f "$series" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -f "${ROOT}/${PATCH_DIR}/${line}" ]] || die "missing patch ${line}"
      cp "${ROOT}/${PATCH_DIR}/${line}" "${dest}/" || return 1
      printf '%s\n' "${dest}/${line}" >>"${dest}/order" || return 1
    done <"$series"
  else
    local found=0 patch
    for patch in "${ROOT}/${PATCH_DIR}"/*.patch; do
      [[ -f "$patch" ]] || continue
      cp "$patch" "${dest}/" || return 1
      printf '%s\n' "${dest}/$(basename "$patch")" >>"${dest}/order" || return 1
      found=1
    done
    [[ "$found" -eq 1 ]] || die "no patches in ${PATCH_DIR}"
  fi
  [[ -s "${dest}/order" ]] || die "no patches in ${PATCH_DIR}"
}

# Product state is present only when every series patch reverse-applies, in
# series order, onto HEAD. Checked against a temporary index so a no-op does
# not dirty the worktree. One patch is the normal case; the loop still stacks.
product_applied() {
  local tmp index i line
  local -a patches=()
  tmp="$(mktemp -d)" || return 1
  if ! index="$(mktemp)"; then
    rm -rf "$tmp" || true
    return 1
  fi
  if ! copy_patches "$tmp/patches"; then
    rm -rf "$tmp" || true
    rm -f "$index" || true
    return 1
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && patches+=("$line")
  done <"$tmp/patches/order"
  if [[ ${#patches[@]} -eq 0 ]]; then
    rm -rf "$tmp"
    rm -f "$index"
    return 1
  fi
  if ! GIT_INDEX_FILE="$index" git read-tree HEAD; then
    rm -rf "$tmp"
    rm -f "$index"
    return 1
  fi
  for ((i=${#patches[@]}-1; i>=0; i--)); do
    if ! GIT_INDEX_FILE="$index" git apply --cached --reverse "${patches[$i]}" >/dev/null 2>&1; then
      rm -rf "$tmp"
      rm -f "$index"
      return 1
    fi
  done
  rm -rf "$tmp" || return 1
  rm -f "$index" || return 1
  return 0
}

restore_tooling() {
  local src_tree="$1" path diff_rc base_tree
  base_tree="$(git rev-parse HEAD)" || return 1
  raw_require clean "$base_tree" || return 1
  local -a restored=()
  git cat-file -e "${src_tree}^{commit}" || return 1
  for path in "${TOOLING_PATHS[@]}"; do
    if git cat-file -e "${src_tree}:${path}" 2>/dev/null; then
      raw_require overlay "$base_tree" "$src_tree" "${restored[@]}" || return 1
      raw_require overlay-collision "$base_tree" "$src_tree" "${restored[@]}" "$path" || return 1
      git checkout "$src_tree" -- "$path" || return 1
      restored+=("$path")
      raw_require overlay "$base_tree" "$src_tree" "${restored[@]}" || return 1
    fi
  done
  if [[ ${#restored[@]} -eq 0 ]]; then
    return 0
  fi
  if git diff --cached --quiet -- "${restored[@]}"; then
    return 0
  else
    diff_rc=$?
    [[ "$diff_rc" -eq 1 ]] || return 1
  fi
  git add -- "${restored[@]}" || return 1
  raw_require overlay "$base_tree" "$src_tree" "${restored[@]}" || return 1
  generated_git commit -m "chore(fork): restore sync tooling after patch fallback" || return 1
  raw_require clean "$(git rev-parse HEAD)" || return 1
  return 0
}

replay_has_independent_work() {
  local tip=""
  [[ "$CREATED_REPLAY_BRANCH" -eq 1 ]] || return 1
  tip="$(git rev-parse --verify --quiet "refs/heads/${REPLAY_BRANCH}" 2>/dev/null || true)"
  [[ -n "$tip" && "$tip" != "$REPLAY_BASE_SHA" ]] || return 1
  ! git merge-base --is-ancestor "$tip" "refs/heads/${FORK_BRANCH}"
}

drop_replay_branch() {
  local tip="" head_name=""
  [[ "$RETAIN_REPLAY_STATE" -ne 1 ]] || return 0
  if [[ "$CREATED_REPLAY_BRANCH" -ne 1 ]]; then
    return 0
  fi
  tip="$(git rev-parse --verify --quiet "refs/heads/${REPLAY_BRANCH}" 2>/dev/null || true)"
  [[ -n "$tip" ]] || return 0
  if [[ "$tip" != "$REPLAY_BASE_SHA" ]] && ! git merge-base --is-ancestor "$tip" "refs/heads/${FORK_BRANCH}"; then
    log "keeping ${REPLAY_BRANCH}: its new commits are not on ${FORK_BRANCH}"
    return 0
  fi
  head_name="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "$head_name" == "$REPLAY_BRANCH" ]]; then
    log "keeping checked-out ${REPLAY_BRANCH}"
    return 0
  fi
  # A later local update must make deletion fail, rather than delete its work.
  if git update-ref -d "refs/heads/${REPLAY_BRANCH}" "$tip"; then
    CREATED_REPLAY_BRANCH=0
  else
    log "keeping ${REPLAY_BRANCH}: its tip changed before cleanup"
  fi
}

preserve_fallback_tip() {
  local i name
  [[ -z "$PRESERVED_FORK_BRANCH" ]] || return 0
  for i in 1 2 3 4 5 6 7 8; do
    name="jkubo-sync-original-${BASHPID:-$$}-${RANDOM}${RANDOM}"
    if git update-ref "refs/heads/${name}" "$PRE_SHA" ""; then
      PRESERVED_FORK_BRANCH="$name"
      log "patch fallback original fork retained on ${name} at ${PRE_SHA}"
      return 0
    fi
  done
  die "could not retain the original fork tip before patch fallback"
}

finish_replay() {
  local replay_tip
  if ! replay_tip="$(git rev-parse HEAD)"; then
    RETAIN_REPLAY_STATE=1
    return 1
  fi
  raw_require clean "$replay_tip" || return 1
  raw_require collision "$replay_tip" || return 1
  if ! git update-ref "refs/heads/${FORK_BRANCH}" "$replay_tip" "$PRE_SHA"; then
    RETAIN_REPLAY_STATE=1
    log "${FORK_BRANCH} moved after capture; keeping its current ref and ${REPLAY_BRANCH}, without push"
    return 1
  fi
  REPLAY_COMMITTED=1
  if ! git checkout "$FORK_BRANCH"; then
    RETAIN_REPLAY_STATE=1
    return 1
  fi
  raw_require clean "$replay_tip" || return 1
  drop_replay_branch || return 1
  return 0
}

# Apply series patches onto a temporary branch at upstream, then restore
# fork-owned tooling from the pre-replay tip. FORK_BRANCH moves only after
# both steps succeed.
am_onto_upstream() {
  local tooling_src="$1" tmp
  local -a patches=()
  local line
  if [[ -n "$fork_lease" && "$PRE_SHA" != "$fork_lease" ]]; then
    die "patch fallback would omit unpublished fork work; refusing to replace ${FORK_BRANCH}"
  fi
  tmp="$(mktemp -d)" || return 1
  if ! copy_patches "$tmp/patches"; then
    rm -rf "$tmp" || true
    return 1
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && patches+=("$line")
  done <"$tmp/patches/order"
  if [[ ${#patches[@]} -eq 0 ]]; then
    rm -rf "$tmp"
    notify_fail "no patches to am after rebase conflict"
    return 1
  fi
  refuse_replay_transforms
  raw_require clean "$(git rev-parse HEAD)" || return 1
  raw_require collision "$UPSTREAM_SHA" || return 1
  REPLAY_BASE_SHA="$UPSTREAM_SHA"
  if ! git checkout -b "$REPLAY_BRANCH" "$UPSTREAM_SHA"; then
    die "could not create replay branch ${REPLAY_BRANCH}"
  fi
  CREATED_REPLAY_BRANCH=1
  raw_require clean "$UPSTREAM_SHA" || return 1
  refuse_replay_transforms
  raw_require collision "$tooling_src" || return 1
  OWNS_AM=1
  if generated_git am --3way "${patches[@]}"; then
    OWNS_AM=0
    raw_require clean "$(git rev-parse HEAD)" || return 1
    log "git am ok -> $(git rev-parse --short HEAD)"
    if ! restore_tooling "$tooling_src"; then
      RETAIN_REPLAY_STATE=1
      log "tooling restoration failed; keeping ${REPLAY_BRANCH}, files and index without push"
      rm -rf "$tmp" || true
      return 1
    fi
    # Even an origin-equal fork may contain work outside the recorded series
    # and tooling paths. Keep its complete accepted history before replacing it.
    preserve_fallback_tip || { RETAIN_REPLAY_STATE=1; return 1; }
    rm -rf "$tmp" || { RETAIN_REPLAY_STATE=1; return 1; }
    finish_replay || return 1
    return 0
  fi
  RETAIN_REPLAY_STATE=1
  log "git am failed; keeping ${REPLAY_BRANCH}, index, files and operation state for inspection"
  rm -rf "$tmp" || true
  notify_fail "git am failed on ${UPSTREAM_SHA:0:12}; inspect ${REPLAY_BRANCH} before manual recovery"
  return 1
}

worktree_matches_tree_entries() {
  raw_state entries "$1"
}

operation_file_matches() {
  local actual="$1" expected="$2" actual_mode expected_mode
  if [[ ! -e "$expected" && ! -L "$expected" ]]; then
    [[ ! -e "$actual" && ! -L "$actual" ]]
    return
  fi
  [[ -f "$expected" && ! -L "$expected" && -f "$actual" && ! -L "$actual" ]] || return 1
  actual_mode="$(stat -c %a -- "$actual")" || return 1
  expected_mode="$(stat -c %a -- "$expected")" || return 1
  [[ "$actual_mode" == "$expected_mode" ]] || return 1
  cmp -s "$actual" "$expected"
}

operation_directory_matches() {
  local actual="$1" expected="$2" entry
  [[ -d "$actual" && ! -L "$actual" && -d "$expected" && ! -L "$expected" ]] || return 1
  # Normal merge-backend metadata is flat. Unknown directories, symlinks,
  # additional files or edited bytes/modes are uncertain and retained.
  for entry in "$actual"/* "$actual"/.[!.]* "$actual"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    operation_file_matches "$entry" "$expected/${entry##*/}" || return 1
  done
  for entry in "$expected"/* "$expected"/.[!.]* "$expected"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    operation_file_matches "$actual/${entry##*/}" "$entry" || return 1
  done
}

rebase_operation_data_matches() {
  local actual="$1" expected="$2" name
  operation_directory_matches "$actual/rebase-merge" "$expected/rebase-merge" || return 1
  for name in HEAD ORIG_HEAD REBASE_HEAD AUTO_MERGE MERGE_MSG MERGE_HEAD MERGE_MODE \
      CHERRY_PICK_HEAD REVERT_HEAD MERGE_AUTOSTASH SQUASH_MSG MERGE_RR; do
    operation_file_matches "$actual/$name" "$expected/$name" || return 1
  done
  [[ ! -e "$actual/rebase-apply" && ! -L "$actual/rebase-apply" \
      && ! -e "$actual/sequencer" && ! -L "$actual/sequencer" ]]
}

rebase_conflict_is_unchanged() {
  local git_dir original tip ours replay_commit parent auto_tree action objects replay_date tmp proof_rc=1
  git_dir="$(git rev-parse --absolute-git-dir)" || return 1
  [[ -d "$git_dir/rebase-merge" ]] || return 1
  [[ "$(cat "$git_dir/rebase-merge/head-name")" == "refs/heads/${REPLAY_BRANCH}" ]] || return 1
  [[ "$(cat "$git_dir/rebase-merge/onto")" == "$UPSTREAM_SHA" ]] || return 1
  original="$(cat "$git_dir/rebase-merge/orig-head")" || return 1
  tip="$(git rev-parse "refs/heads/${REPLAY_BRANCH}")" || return 1
  [[ "$original" == "$tip" ]] || return 1
  git merge-base --is-ancestor "$PRE_SHA" "$original" || return 1
  ours="$(git rev-parse HEAD)" || return 1
  git merge-base --is-ancestor "$UPSTREAM_SHA" "$ours" || return 1
  action="$(git reflog -1 --format=%gs HEAD)" || return 1
  case "$action" in
    'rebase (start): checkout '*|'rebase (pick): '*) ;;
    *) return 1 ;;
  esac
  replay_commit="$(git rev-parse REBASE_HEAD)" || return 1
  git merge-base --is-ancestor "$replay_commit" "$original" || return 1
  parent="$(git rev-parse "${replay_commit}^")" || return 1
  auto_tree="$(git rev-parse 'AUTO_MERGE^{tree}')" || return 1
  objects="$(git rev-parse --path-format=absolute --git-path objects)" || return 1
  replay_date="$(git show -s --format=%cI "$ours")" || return 1
  tmp="$(mktemp -d)" || return 1
  mkdir "$tmp/empty-template" "$tmp/proof-worktree" || { rm -rf "$tmp"; return 1; }
  # This deliberately accepts only conflicts whose complete index equals
  # plain Git's three-tree result, and whose tracked files equal AUTO_MERGE.
  # Edited stages/bytes and more complex merges are retained, not guessed at.
  # Reconstruct in a separate bare inspection repo with no template hooks.
  # Candidate hooks/config remain untouched; they cannot alter expected data.
  # Full native operation data, including todo commands, must also match.
  if (
      unset GIT_COMMON_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_INDEX_FILE GIT_CONFIG_PARAMETERS
      export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0
      GIT_DIR="$tmp/proof.git" git init --bare -q --template="$tmp/empty-template" "$tmp/proof.git" || exit 1
      export GIT_DIR="$tmp/proof.git" GIT_WORK_TREE="$tmp/proof-worktree"
      # Read committed source objects through alternates. Inspection replay
      # writes only its own objects, index, worktree and operation metadata.
      printf '%s\n' "$objects" >"$GIT_DIR/objects/info/alternates" || exit 1
      export GIT_INDEX_FILE="$tmp/expected-index"
      git read-tree -m "$parent" "$ours" "$replay_commit" || exit 1
      git ls-files --stage -v >"$tmp/expected-stages" || exit 1
      unset GIT_INDEX_FILE
      git checkout -q -b "$REPLAY_BRANCH" "$original" || exit 1
      cd "$GIT_WORK_TREE" || exit 1
      # Reproduce native operation data from committed history, never from
      # a post-hook snapshot. A timestamp reproduces generated commit OIDs;
      # different earlier timestamps or complex/configured replay may refuse.
      local replay_rc=0
      GIT_COMMITTER_DATE="$replay_date" generated_git rebase "$UPSTREAM_SHA" \
        >"$tmp/expected-rebase.log" 2>&1 || replay_rc=$?
      [[ "$replay_rc" -eq 1 && -d "$GIT_DIR/rebase-merge" ]] || exit 1
      [[ "$(git rev-parse HEAD)" == "$ours" ]] || exit 1
    ) \
      && rebase_operation_data_matches "$git_dir" "$tmp/proof.git" \
      && git ls-files --stage -v >"$tmp/actual-stages" \
      && cmp -s "$tmp/expected-stages" "$tmp/actual-stages" \
      && git ls-tree -r -z "$auto_tree" >"$tmp/auto-files" \
      && worktree_matches_tree_entries "$tmp/auto-files"; then
    proof_rc=0
  fi
  rm -rf "$tmp" || return 1
  return "$proof_rc"
}

rebase_or_am() {
  local tooling_src="$PRE_SHA"
  # Capture before checkout: a normal post-checkout hook may add its own work.
  refuse_replay_transforms
  raw_require clean "$PRE_SHA" || return 1
  raw_require collision "$UPSTREAM_SHA" || return 1
  REPLAY_BASE_SHA="$PRE_SHA"
  if ! git checkout -b "$REPLAY_BRANCH" "$PRE_SHA"; then
    die "could not create replay branch ${REPLAY_BRANCH}"
  fi
  CREATED_REPLAY_BRANCH=1
  # A normal hook may add committed work. It remains foreign to cleanup:
  # REPLAY_BASE_SHA stays the captured original, and only raw committed bytes
  # of a descendant on the named replay branch may enter native replay.
  local checked_out_tip
  checked_out_tip="$(git rev-parse HEAD)" || return 1
  if ! git merge-base --is-ancestor "$PRE_SHA" "$checked_out_tip"; then
    RETAIN_REPLAY_STATE=1
    return 1
  fi
  raw_require clean "$checked_out_tip" || return 1
  refuse_replay_transforms "$checked_out_tip"
  OWNS_REBASE=1
  if generated_git rebase "$UPSTREAM_SHA"; then
    OWNS_REBASE=0
    raw_require clean "$(git rev-parse HEAD)" || return 1
    log "rebase ok -> $(git rev-parse --short HEAD)"
    finish_replay || return 1
    return 0
  fi
  log "rebase conflict; falling back to git am --3way"
  if ! rebase_conflict_is_unchanged; then
    RETAIN_REPLAY_STATE=1
    die "rebase conflict state is edited or unproven; leaving ${REPLAY_BRANCH}, files, index and operation for inspection"
  fi
  if ! git rebase --abort; then
    RETAIN_REPLAY_STATE=1
    notify_fail "git rebase --abort failed on ${UPSTREAM_SHA:0:12}"
    die "rebase --abort failed; refusing to continue with a rebase in progress"
  fi
  OWNS_REBASE=0
  raw_require clean "$REPLAY_BASE_SHA" || return 1
  if replay_has_independent_work; then
    die "replay branch ${REPLAY_BRANCH} contains independent work; leaving its commits and files in place"
  fi
  checkout_fork_pre_sha || return 1
  drop_replay_branch || return 1
  am_onto_upstream "$tooling_src" || return 1
  return 0
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
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date -Is)" "$msg" >>"${STATE_DIR}/sync.log" 2>/dev/null || true
  if command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    notify-send --urgency=critical "grok-jkubo sync failed" "$msg" || true
  fi
}

# One atomic update of the mirror and the fork. Leases are the fetch-observed
# shas, or empty when that remote branch was absent (creation). Never bare
# force, a value-less force-with-lease, or a hook bypass. This function checks
# every command itself: callers may invoke it from a context where errexit
# is disabled.
push_fork() {
  local fork_sha local_after
  if [[ "$DO_PUSH" -ne 1 ]]; then
    return 0
  fi
  if [[ "$DO_DRY" -eq 1 ]]; then
    log "dry-run: would atomically push ${FORK_BRANCH} and ${MIRROR_BRANCH}"
    return 0
  fi
  if ! fork_sha="$(git rev-parse "refs/heads/${FORK_BRANCH}")"; then
    log "push failed: local ${FORK_BRANCH} does not resolve"
    return 1
  fi
  raw_require clean "$(git rev-parse HEAD)" || return 1
  log "atomic push ${MIRROR_BRANCH} and ${FORK_BRANCH}"
  if ! git push --atomic \
      --force-with-lease="${MIRROR_BRANCH}:${mirror_lease}" \
      --force-with-lease="${FORK_BRANCH}:${fork_lease}" \
      "$ORIGIN_REMOTE" \
      "${UPSTREAM_SHA}:refs/heads/${MIRROR_BRANCH}" \
      "${fork_sha}:refs/heads/${FORK_BRANCH}"; then
    log "atomic push rejected; local replay kept; neither remote branch was published"
    return 1
  fi
  # Pin the exported sha to the oid this command uploaded. A hook may already
  # have moved the local fork ref; do not read it back and do not reset it.
  PUBLISHED_FORK_SHA="$fork_sha"
  local_after="$(git rev-parse "refs/heads/${FORK_BRANCH}" 2>/dev/null || true)"
  if [[ -n "$local_after" && "$local_after" != "$fork_sha" ]]; then
    log "local ${FORK_BRANCH} moved after capture; leaving it and exporting ${fork_sha}"
  fi
  return 0
}

# After a successful fetch and before checkout, replay, or moving the mirror
# branch: keep remote-only and unpublished history. Equal and contained
# history may proceed. Ahead or diverged history is refused in both pull modes.
refuse_history_loss() {
  local local_fork="" local_mirror=""
  if [[ "$PULL_ORIGIN" -eq 1 ]]; then
    log "fetched origin/${FORK_BRANCH} must already be contained in local ${FORK_BRANCH}"
  else
    log "not pulling origin; fetched origin/${FORK_BRANCH} must already be contained in local ${FORK_BRANCH}"
  fi
  if [[ -n "$fork_lease" ]]; then
    if git show-ref --verify --quiet "refs/heads/${FORK_BRANCH}"; then
      local_fork="$(git rev-parse "refs/heads/${FORK_BRANCH}")"
    fi
    if [[ -z "$local_fork" ]] || ! git merge-base --is-ancestor "$fork_lease" "$local_fork"; then
      die "origin/${FORK_BRANCH} is not an ancestor of local ${FORK_BRANCH}; refusing to discard remote fork history. Reconcile the reviewed remote history, then retry."
    fi
  fi
  if [[ -n "$mirror_lease" ]]; then
    if ! git merge-base --is-ancestor "$mirror_lease" "$UPSTREAM_SHA"; then
      die "origin/${MIRROR_BRANCH} is not an ancestor of ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}; refusing to discard fetched mirror work"
    fi
  fi
  if git show-ref --verify --quiet "refs/heads/${MIRROR_BRANCH}"; then
    local_mirror="$(git rev-parse "refs/heads/${MIRROR_BRANCH}")"
    if ! git merge-base --is-ancestor "$local_mirror" "$UPSTREAM_SHA"; then
      die "local ${MIRROR_BRANCH} is not an ancestor of ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}; refusing to discard unpublished mirror work"
    fi
  fi
}

refuse_existing_git_operation
if [[ "$ALLOW_DIRTY" -eq 1 ]]; then prepare_replay_branch; fi
command -v python3 >/dev/null || die "python3 is required for raw ownership checks"
if ! raw_state clean "$(git rev-parse HEAD)"; then
  RETAIN_REPLAY_STATE=1
  die "worktree dirty; commit/stash or pass --allow-dirty (raw ownership is unproven)"
fi
require_clean
if [[ "$ALLOW_DIRTY" -eq 0 ]]; then prepare_replay_branch; fi
ensure_remote "$UPSTREAM_REMOTE" "https://github.com/xai-org/grok-build.git"
ensure_remote "$ORIGIN_REMOTE" "https://github.com/jkubo/grok-build.git"

RAW_SNAPSHOT_DIR="$(mktemp -d)"
raw_require snapshot "$RAW_SNAPSHOT_DIR/before-fetch" || die "could not snapshot before fetch"

log "fetch ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH} + ${ORIGIN_REMOTE}"
if ! git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" --prune; then
  die "fetch ${UPSTREAM_REMOTE} failed"
fi
raw_require unchanged "$RAW_SNAPSHOT_DIR/before-fetch" || die "local state changed during fetch"
if ! git fetch "$ORIGIN_REMOTE" --prune; then
  die "fetch ${ORIGIN_REMOTE} failed; refusing to use a stale lease"
fi

raw_require unchanged "$RAW_SNAPSHOT_DIR/before-fetch" || die "local state changed during fetch"

UPSTREAM_SHA="$(git rev-parse "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}")"
log "upstream ${UPSTREAM_SHA:0:12} $(git log -1 --format=%s "$UPSTREAM_SHA")"

fork_lease=""
mirror_lease=""
if git show-ref --verify --quiet "refs/remotes/${ORIGIN_REMOTE}/${FORK_BRANCH}"; then
  fork_lease="$(git rev-parse "refs/remotes/${ORIGIN_REMOTE}/${FORK_BRANCH}")"
fi
if git show-ref --verify --quiet "refs/remotes/${ORIGIN_REMOTE}/${MIRROR_BRANCH}"; then
  mirror_lease="$(git rev-parse "refs/remotes/${ORIGIN_REMOTE}/${MIRROR_BRANCH}")"
fi

refuse_history_loss

if git show-ref --verify --quiet "refs/heads/${FORK_BRANCH}"; then
  fork_checkout_sha="$(git rev-parse "refs/heads/${FORK_BRANCH}")"
  raw_require clean "$(git rev-parse HEAD)" || die "raw ownership before fork checkout is unproven"
  raw_require collision "$fork_checkout_sha" || die "fork checkout target collides with independent files"
  git checkout "$FORK_BRANCH"
  raw_require clean "$fork_checkout_sha" || die "fork checkout changed raw files or index"
else
  log "creating local branch ${FORK_BRANCH}"
  fork_checkout_sha="$(git rev-parse HEAD)"
  git checkout -b "$FORK_BRANCH"
  raw_require clean "$fork_checkout_sha" || die "fork checkout changed raw files or index"
fi

PRE_SHA="$(git rev-parse HEAD)"

if git merge-base --is-ancestor "$UPSTREAM_SHA" "$(git rev-parse HEAD)"; then
  if product_applied; then
    log "already based on latest upstream and the product patch is present"
  elif [[ "$DO_DRY" -eq 1 ]]; then
    log "dry-run: product patch is not present; would replay it"
  else
    log "upstream is contained but the product patch does not reverse-apply; replaying"
    am_onto_upstream "$PRE_SHA" || die "could not replay fork patches onto upstream (resolve in a checkout, then --push)"
  fi
elif [[ "$DO_DRY" -eq 1 ]]; then
  log "dry-run: would replay $(git rev-list --count "${UPSTREAM_SHA}..HEAD") commit(s) onto ${UPSTREAM_SHA:0:12}"
else
  log "replay ${FORK_BRANCH} onto ${UPSTREAM_SHA:0:12}"
  rebase_or_am || die "could not replay fork patches onto upstream (resolve in a checkout, then --push)"
fi

raw_require clean "$(git rev-parse HEAD)" || die "raw ownership before mirror update is unproven"
if [[ "$DO_DRY" -eq 0 ]]; then
  git branch -f "$MIRROR_BRANCH" "$UPSTREAM_SHA"
fi

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
  HEAD_SHA="$(git rev-parse HEAD)"
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
    log "dry-run: would install ${bin} -> ${dest}"
  else
    install -m 755 "$bin" "$dest"
    log "installed ${dest} ($("$dest" --version 2>/dev/null || echo ok))"
    log "running TUI processes keep the old ELF until relaunch"
  fi
fi

if ! push_fork; then
  if [[ "$DO_BUILD" -eq 1 || "$DO_INSTALL" -eq 1 ]]; then
    log "push failed (local build/install kept)"
  fi
  die "push failed"
fi

log "HEAD $(git rev-parse --short HEAD) version=$(fork_version)"
