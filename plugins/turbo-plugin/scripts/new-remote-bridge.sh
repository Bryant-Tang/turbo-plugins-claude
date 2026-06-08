#!/usr/bin/env bash
# Internal helper (v0.5.0 U9): create the git<->SVN bridge for an EXISTING local branch
# on its first push. Generalized from new-remote-test.sh (no test-<n>; takes --branch +
# --svn-url). Does NOT create a working branch -- that is already the caller's current
# branch; this only creates the remote-svn/<branch> bridge branch + worktree + svn checkout.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

SVN_URL=''
BRANCH=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --svn-url) [[ $# -ge 2 ]] || { echo "Error: --svn-url requires a value" >&2; exit 1; }; SVN_URL="$2"; shift 2 ;;
    --branch)  [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]];  then echo "Error: --branch is required" >&2; exit 1; fi
if [[ -z "$SVN_URL" ]]; then echo "Error: --svn-url is required" >&2; exit 1; fi

MAIN_WORKTREE="$(get_main_worktree)"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

if [[ ! -d "$WORKTREES_DIR" ]]; then
  echo "Error: worktrees directory not found: $WORKTREES_DIR. Run /tp-setup first." >&2; exit 1
fi

# Resolve + sanitize the branch (U7): rejects unsafe names; computes ref + dir + MAX_PATH.
RESOLVED="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")" || exit 1
REMOTE_NAME="${RESOLVED%%|*}"
REMOTE_BRANCH="${RESOLVED#*|}"; REMOTE_BRANCH="${REMOTE_BRANCH%%|*}"
REMOTE_PATH="${RESOLVED##*|}"

# Collision: reject if a DIFFERENT existing remote-svn branch maps to the same dir name.
EXISTING=()
while IFS= read -r line; do
  line="${line#\* }"
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  [[ "$line" == remote-svn/* ]] || continue
  EXISTING+=("${line#remote-svn/}")
done < <(git -C "$MAIN_WORKTREE" branch --list 'remote-svn/*')
COLLISION="$(find_remote_worktree_collision "$BRANCH" "${EXISTING[@]+"${EXISTING[@]}"}")"
if [[ -n "$COLLISION" ]]; then
  echo "Error: worktree name '$REMOTE_NAME' is already taken by branch '$COLLISION' (maps to the same directory). Rename your branch to avoid the collision." >&2
  exit 1
fi

# Bridge-only already-exists guard (no working-branch creation). Detect the inconsistent
# partial states (ref XOR dir) left by an interrupted run and give explicit recovery steps
# instead of a dead-end "already exists" that blocks the advertised re-run.
# NOTE: the unit tests distinguish the two arms by their UNIQUE wording -- the ref-without-dir
# arm says 'git branch -D', the dir-without-ref arm says 'delete that directory'. If you reword
# these two messages, update new-remote-bridge.test.sh / New-RemoteBridge.test.ps1 to match.
BRIDGE_EXISTS=false
if git -C "$MAIN_WORKTREE" branch --list "$REMOTE_BRANCH" | grep -q .; then BRIDGE_EXISTS=true; fi
WT_EXISTS=false
if [[ -e "$REMOTE_PATH" ]]; then WT_EXISTS=true; fi
if [[ "$BRIDGE_EXISTS" == true && "$WT_EXISTS" == false ]]; then
  echo "Error: inconsistent bridge state: branch '$REMOTE_BRANCH' exists but its worktree directory is missing ($REMOTE_PATH) -- likely a leftover from an interrupted first push. To recover, run in the main worktree ($MAIN_WORKTREE): 'git worktree prune', then 'git branch -D $REMOTE_BRANCH'; then re-run the first push." >&2
  exit 1
fi
if [[ "$WT_EXISTS" == true && "$BRIDGE_EXISTS" == false ]]; then
  echo "Error: inconsistent bridge state: the worktree directory exists ($REMOTE_PATH) but branch '$REMOTE_BRANCH' is missing -- likely a leftover from an interrupted first push. To recover, delete that directory and run 'git worktree prune' in the main worktree ($MAIN_WORKTREE); then re-run the first push." >&2
  exit 1
fi
if [[ "$BRIDGE_EXISTS" == true ]]; then
  echo "Error: bridge branch '$REMOTE_BRANCH' already exists." >&2; exit 1
fi
if [[ "$WT_EXISTS" == true ]]; then
  echo "Error: worktree '$REMOTE_NAME' already exists at: $REMOTE_PATH" >&2; exit 1
fi

# SECURITY (KTD-8): trust check BEFORE any mutation and before the ERR rollback trap.
REMOTE_MAIN_PATH="$WORKTREES_DIR/remote-svn-main"
if ! assert_trusted_svn_url "$REMOTE_MAIN_PATH" "$SVN_URL" >/dev/null; then
  echo "Error: refusing to create bridge with untrusted/unverifiable SVN URL." >&2
  exit 1
fi

echo "Creating SVN bridge for branch '$BRANCH'..."

INIT_COMMIT="$(git -C "$MAIN_WORKTREE" rev-list --max-parents=0 HEAD)"

# Use the SANITIZED dash-form (not raw user input) for the svn copy commit message.
SVN_MSG_BRANCH="$REMOTE_NAME"

# Rollback covers ONLY local git (branch + worktree). An executed `svn copy` writes SVN's
# PERMANENT history and is NOT rolled back (orphan SVN path); re-running first-push is
# idempotent: `svn info` detects the path and checks out instead of re-copying.
_rollback_bridge() {
    local exit_code=$?
    echo "Bridge setup failed; rolling back local git state (an already-created SVN path is permanent)..." >&2
    git -C "$MAIN_WORKTREE" worktree remove --force "$REMOTE_PATH" 2>/dev/null || true
    git -C "$MAIN_WORKTREE" branch -D "$REMOTE_BRANCH" 2>/dev/null || true
    exit "$exit_code"
}
trap _rollback_bridge ERR

git -C "$MAIN_WORKTREE" branch "$REMOTE_BRANCH" "$INIT_COMMIT"
git -C "$MAIN_WORKTREE" worktree add "$REMOTE_PATH" "$REMOTE_BRANCH"

if svn info "$SVN_URL" >/dev/null 2>&1; then
  # Idempotent re-entry: a prior run's `svn copy` is permanent, so a re-run finds the
  # path present and takes the checkout branch (no re-copy).
  echo "SVN path exists, will checkout: $SVN_URL"
else
  MAIN_SVN_URL="$(svn info --show-item url "$REMOTE_MAIN_PATH")"
  echo "SVN path '$SVN_URL' does not exist. Creating from '$MAIN_SVN_URL'..."
  svn copy "$MAIN_SVN_URL" "$SVN_URL" -m "create $SVN_MSG_BRANCH branch"
fi

echo "Running: svn checkout --force $SVN_URL $REMOTE_PATH"
# --force: `git worktree add` already created `.git` + init-commit content; svn would
# otherwise mark these "obstructed". --force treats existing files as already-versioned.
svn checkout --force "$SVN_URL" "$REMOTE_PATH"

# Untrack `.git` from the svn working copy BEFORE setting svn:ignore (else `.git`, pointing
# at the original committer's local path, lands in permanent SVN history). --keep-local
# removes it from svn versioning but keeps the file for git.
if [[ -e "$REMOTE_PATH/.git" ]]; then
  (cd "$REMOTE_PATH" && svn rm --keep-local '.git' 2>/dev/null || true)
fi

IGNORE_TO_APPLY=$'.git\n.gitignore'
if [[ -d "$REMOTE_MAIN_PATH" ]]; then
  INHERITED="$(svn propget svn:ignore "$REMOTE_MAIN_PATH" 2>/dev/null || true)"
  if [[ -n "$INHERITED" ]]; then IGNORE_TO_APPLY="$INHERITED"; fi
fi

# Sync main's current .gitignore into the bridge BEFORE svn commit (prevents first-push
# add/add conflict). Independent of any .svn handling; retained.
if [[ -f "$MAIN_WORKTREE/.gitignore" ]]; then
  cp -f "$MAIN_WORKTREE/.gitignore" "$REMOTE_PATH/.gitignore"
  echo "Synced main's .gitignore into $REMOTE_NAME for first-push consistency."
fi

(
  cd "$REMOTE_PATH"
  svn propset svn:ignore "$IGNORE_TO_APPLY" '.'
  svn commit -m 'svn:ignore: copy from remote-svn-main; sync .gitignore from main'
)

# All SVN steps succeeded; disable the rollback trap.
trap - ERR

echo ""
echo "SVN bridge created for branch '$BRANCH'."
echo "  Bridge branch : $REMOTE_BRANCH"
echo "  SVN worktree  : $REMOTE_PATH"
