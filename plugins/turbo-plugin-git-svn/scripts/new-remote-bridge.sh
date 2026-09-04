#!/usr/bin/env bash
# Internal helper: create the git<->SVN bridge for an EXISTING local branch
# on its first push. Generalized from new-remote-test.sh (no test-<n>; takes --branch +
# --svn-url). Does NOT create a working branch -- that is already the caller's current
# branch; this only creates the remote-svn/<branch> bridge branch + worktree + svn checkout.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

SVN_URL=''
BRANCH=''
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
REPO_ROOT=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --svn-url)   [[ $# -ge 2 ]] || { echo "Error: --svn-url requires a value" >&2; exit 1; }; SVN_URL="$2"; shift 2 ;;
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]];  then echo "Error: --branch is required" >&2; exit 1; fi
if [[ -z "$SVN_URL" ]]; then echo "Error: --svn-url is required" >&2; exit 1; fi

MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT")"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

if [[ ! -d "$WORKTREES_DIR" ]]; then
  echo "Error: worktrees directory not found: $WORKTREES_DIR. Run /tp-setup first." >&2; exit 1
fi

# Resolve + sanitize the branch: rejects unsafe names; computes ref + dir + MAX_PATH.
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

# Base the new bridge branch on remote-svn/main's tip (the git mirror of trunk). The SVN feature
# path below is `svn copy`d from trunk, so its git side must start from trunk's mirror -- this makes
# the post-checkout worktree content match the branch tree (clean, no untracked-overwrite on the
# first push merge) and gives the merge-back a recent common ancestor.
# NOT `rev-list --max-parents=0 HEAD`: once the repo has been through a bridge merge it has MULTIPLE
# root commits (the empty native root + each `sync:` import root), so that returned a multi-line
# value that broke `git branch` with "not a valid object name". remote-svn/main is always a single
# commit and always exists here (it is the trust anchor validated above).
if ! BASE_REF="$(git -C "$MAIN_WORKTREE" rev-parse --verify -q 'refs/heads/remote-svn/main')"; then
  echo "Error: bridge anchor branch 'remote-svn/main' not found. Run /tp-setup first to bootstrap the main bridge." >&2
  exit 1
fi

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

git -C "$MAIN_WORKTREE" branch "$REMOTE_BRANCH" "$BASE_REF"
git -C "$MAIN_WORKTREE" worktree add --no-checkout "$REMOTE_PATH" "$REMOTE_BRANCH"
# Pin the bridge to byte-faithful checkouts BEFORE anything materialises files. Order matters:
# with core.autocrlf still true, `worktree add` would write CRLF and the files on disk would no
# longer match their blobs -- and for a bridge whose SVN side does not carry them yet, that turns
# a harmless "phantom M" into a real diff the drift check would report.
ensure_bridge_eol_platform_native "$MAIN_WORKTREE" "$REMOTE_PATH"
# --no-checkout leaves the index EMPTY, so populate explicitly; now the bytes on disk are the
# bytes git stores.
git -C "$REMOTE_PATH" reset --hard --quiet

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
# otherwise mark these "obstructed". --force treats existing files as already-versioned --
# but it does NOT overwrite them: each one is adopted as locally MODIFIED, keeping git's bytes.
svn checkout --force "$SVN_URL" "$REMOTE_PATH"

# Take SVN's bytes for everything --force just adopted.
#
# Without this the bridge is born dirty. `core.autocrlf=true` is the SYSTEM-level default in Git
# for Windows, so `git worktree add` writes every text file with CRLF; --force then adopts those
# CRLF copies as modifications of SVN's LF originals. Observed on a real machine 2026-07-31: a
# one-line README change on a new branch pushed 11 whole-file rewrites into SVN, permanently, with
# blame destroyed. `svn revert` is the exact undo -- the working copy was created seconds ago, so
# the only "local changes" it can throw away are those adopted copies.
#
# Deliberately NOT the sibling scripts' shape (empty the worktree, then a plain `svn checkout`):
# emptying also deletes files git tracks that SVN does not carry yet -- `.gitignore` is the normal
# case -- so git would see a deletion and the bridge would need an extra commit to get clean again.
# That commit is not free: an unmarked non-merge commit on remote-svn/<branch> is exactly what the
# pull path reports as an orphaned sync (sync-from-svn.sh, `$BRANCH..$REMOTE_BRANCH`), because here
# the working branch does not descend from the bridge. Reverting touches only SVN-versioned paths
# and leaves git-only files alone, so no commit is needed at all.
(cd "$REMOTE_PATH" && svn revert -R .)

# Untrack `.git` from the svn working copy BEFORE setting svn:ignore (else `.git`, pointing
# at the original committer's local path, lands in permanent SVN history). --keep-local
# removes it from svn versioning but keeps the file for git.
if [[ -e "$REMOTE_PATH/.git" ]]; then
  (cd "$REMOTE_PATH" && svn rm --keep-local '.git' 2>/dev/null || true)
fi

# svn:ignore is fixed to exactly `.git` (see New-RemoteBridge.ps1 for rationale): it is the
# only must-exclude path the push scripts' git check-ignore filter cannot catch. No
# inheritance from remote-svn-main -- a fixed value avoids inheriting a stale set that omits `.git`.
IGNORE_TO_APPLY='.git'

# U4/KTD5: read the trunk copyfrom-rev this branch was `svn copy`d from (U2 reader) to INITIALIZE
# tp:last-aligned-rev. This is the trunk revision the branch is aligned to at creation -- NOT the
# branch's own creation rev (which never touched trunk). `|| true` so a read failure leaves it empty
# (tp:last-aligned-rev simply stays unset) rather than tripping the rollback trap; the branch is a
# copy here (create path svn-copies it; re-entry finds the prior copy) so it is present in practice.
BRANCH_COPYFROM_REV="$(get_svn_branch_copyfrom_rev "$SVN_URL" || true)"

# Do NOT sync .gitignore here. `svn copy` already brought svn:ignore=.git onto the new branch
# (properties copy with the tree), so the bridge excludes .git from the start. The old pre-sync
# copied main's .gitignore into the worktree WITHOUT a git commit, leaving the bridge git-dirty
# so the immediately-following build-svn-commit refused ("uncommitted git changes"). Any real
# .gitignore change now reaches SVN through the normal (confirmed) push that follows -- the branch
# is merged into the bridge by build-svn-commit and committed by submit-svn-commit.
(
  cd "$REMOTE_PATH"
  svn propset svn:ignore "$IGNORE_TO_APPLY" '.'
  # U4/KTD5: fold the branch metadata into THIS same infra commit (avoids a 2nd revision). Both
  # properties ride on '.' -- already a --depth empty commit target -- so no extra commit is paid.
  #   tp:branch-name       = the ORIGINAL git branch name, raw (slashes preserved for R7 checkout).
  #   tp:last-aligned-rev  = the trunk copyfrom-rev (init alignment; advanced later on merge-main).
  svn propset tp:branch-name "$BRANCH" '.'
  if [[ -n "$BRANCH_COPYFROM_REV" ]]; then
    svn propset tp:last-aligned-rev "$BRANCH_COPYFROM_REV" '.'
  fi
  # Commit ONLY '.' -- the svn:ignore + tp:* properties (--depth empty, so nothing under the tree
  # can be swept in) -- plus a real .git deletion if one was scheduled. The `svn revert` above now
  # leaves nothing to sweep, but the scoping stays: it is the guard, not a consequence. The
  # tp:* props are new (never inherited from the copy), so this is the ONE dedicated property commit
  # first-push pays (bounded cost, KTD5); the trailing `svn update` clears the mixed-revision lag.
  COMMIT_TARGETS=('.')
  if svn status '.git' 2>/dev/null | grep -q '^D'; then
    COMMIT_TARGETS+=('.git')
  fi
  svn commit --depth empty -m 'svn:ignore=.git (turbo-plugin bridge)' "${COMMIT_TARGETS[@]}"
  svn update >/dev/null
)

# Re-align git's index with the bytes on disk. The CONTENT is unchanged -- `git diff` is empty and
# the blob hashes still match HEAD -- but the files shrank (CRLF -> LF), and under
# `core.autocrlf=true` git reports every one of them as ` M` in `git status --porcelain` anyway
# (the other face of its "LF will be replaced by CRLF" warning). build-svn-commit refuses to run on
# a non-empty `git status --porcelain`, so without this the push that immediately follows would be
# blocked by our own guard. `git add -A` clears it and provably does NOT change the tree.
#
# `.svn/` MUST be excluded before that runs. The bootstrap already writes this exclusion, but
# inheriting it is not good enough for the failure it prevents: unexcluded, `git add -A` pulls
# `.svn/pristine/*` through the CRLF filter and the next `svn commit` dies with "Working copy text
# base is corrupt" -- a destroyed working copy, not merely a dirty one. Idempotent.
ensure_svn_git_excluded "$MAIN_WORKTREE"
git -C "$REMOTE_PATH" add -A

# Anything still staged after that is a REAL content difference between the SVN branch path and
# this repo's mirror of trunk -- normally because trunk moved on since the last pull, so the freshly
# copied branch already carries content this repo has never seen. The bridge is left in place (the
# `svn copy` is permanent and re-running is idempotent), but say plainly what happened: the push
# that follows will stop on its own git-clean gate, and "uncommitted git changes" on a worktree the
# user never touched explains nothing by itself.
if ! git -C "$REMOTE_PATH" diff --cached --quiet; then
  echo "" >&2
  echo "Note: the SVN branch content differs from this repo's mirror of trunk:" >&2
  git -C "$REMOTE_PATH" -c core.quotePath=false diff --cached --name-only | sed 's/^/  /' >&2
  echo "This usually means trunk moved since your last pull. Run '/tp-pull-from-svn' on main," >&2
  echo "merge it into '$BRANCH', then run the push again (the bridge is already created; re-running is safe)." >&2
fi

# All SVN steps succeeded; disable the rollback trap.
trap - ERR

echo ""
echo "SVN bridge created for branch '$BRANCH'."
echo "  Bridge branch : $REMOTE_BRANCH"
echo "  SVN worktree  : $REMOTE_PATH"
