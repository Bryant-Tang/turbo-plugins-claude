#!/usr/bin/env bash
# U11 (tp-checkout-svn-branch): one-step READ-ONLY import of an EXISTING SVN branch into a
# git<->SVN bridge + a content-filled working branch. Modeled on new-remote-bridge.sh but it
# NEVER writes to SVN: no `svn copy`, no `svn:ignore` propset, no `svn commit`. It only reads
# (`svn checkout`) and writes the local git side, so a rejected URL or a mid-run failure leaves
# the target SVN branch with NO new revision. The working branch descends from the
# remote-svn/<branch> bridge ref (KTD5) so the first /tp-pull-from-svn merge is not "unrelated
# histories".
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

if [[ -z "$SVN_URL" ]]; then echo "Error: --svn-url is required (the existing SVN branch URL to import)" >&2; exit 1; fi

MAIN_WORKTREE="$(get_main_worktree)"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"
if [[ ! -d "$WORKTREES_DIR" ]]; then
  echo "Error: worktrees directory not found: $WORKTREES_DIR. Run git-svn /tp-setup first to bootstrap." >&2; exit 1
fi

# ── Resolve the working-branch name: --branch, else sanitized SVN leaf. ──
DERIVED=false
if [[ -z "$BRANCH" ]]; then
  LEAF="$SVN_URL"
  while [[ "$LEAF" == */ ]]; do LEAF="${LEAF%/}"; done   # strip trailing slashes
  LEAF="${LEAF##*/}"                                      # leaf after last '/'
  if [[ -z "$LEAF" ]]; then
    echo "Error: could not derive a branch name from the SVN URL '$SVN_URL'. Pass --branch <name> explicitly." >&2
    exit 1
  fi
  BRANCH="$LEAF"
  DERIVED=true
fi

# Resolve + sanitize (allowlist + MAX_PATH). 2>&1 so a failure's stderr is captured into the
# same var; on a derived leaf that fails the allowlist, point the user at --branch.
if ! RESOLVED="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR" 2>&1)"; then
  if [[ "$DERIVED" == true ]]; then
    echo "Error: derived branch name '$BRANCH' (from the SVN URL leaf) is not valid: $RESOLVED Pass --branch <name> explicitly." >&2
  else
    echo "$RESOLVED" >&2
  fi
  exit 1
fi
REMOTE_NAME="${RESOLVED%%|*}"
REMOTE_BRANCH="${RESOLVED#*|}"; REMOTE_BRANCH="${REMOTE_BRANCH%%|*}"
REMOTE_PATH="${RESOLVED##*|}"

# ── Collision + partial-state guards (BEFORE any mutation; zero side effects on reject). ──
EXISTING=()
while IFS= read -r line; do
  line="${line#\* }"
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  [[ "$line" == remote-svn/* ]] || continue
  EXISTING+=("${line#remote-svn/}")
done < <(git -C "$MAIN_WORKTREE" branch --list 'remote-svn/*')
COLLISION="$(find_remote_worktree_collision "$BRANCH" "${EXISTING[@]+"${EXISTING[@]}"}")"
if [[ -n "$COLLISION" ]]; then
  echo "Error: worktree name '$REMOTE_NAME' is already taken by branch '$COLLISION' (maps to the same directory). Pass --branch <name> with a different name." >&2
  exit 1
fi

BRIDGE_EXISTS=false
if git -C "$MAIN_WORKTREE" branch --list "$REMOTE_BRANCH" | grep -q .; then BRIDGE_EXISTS=true; fi
WT_EXISTS=false
if [[ -e "$REMOTE_PATH" ]]; then WT_EXISTS=true; fi
if [[ "$BRIDGE_EXISTS" == true && "$WT_EXISTS" == false ]]; then
  echo "Error: inconsistent bridge state: branch '$REMOTE_BRANCH' exists but its worktree directory is missing ($REMOTE_PATH) -- likely a leftover from an interrupted run. To recover, run in the main worktree ($MAIN_WORKTREE): 'git worktree prune', then 'git branch -D $REMOTE_BRANCH'; then re-run." >&2
  exit 1
fi
if [[ "$WT_EXISTS" == true && "$BRIDGE_EXISTS" == false ]]; then
  echo "Error: inconsistent bridge state: the worktree directory exists ($REMOTE_PATH) but branch '$REMOTE_BRANCH' is missing -- likely a leftover from an interrupted run. To recover, delete that directory and run 'git worktree prune' in the main worktree ($MAIN_WORKTREE); then re-run." >&2
  exit 1
fi
if [[ "$BRIDGE_EXISTS" == true ]]; then
  echo "Error: bridge branch '$REMOTE_BRANCH' already exists. The SVN branch is already imported; use /tp-pull-from-svn --branch $BRANCH to sync." >&2; exit 1
fi
if [[ "$WT_EXISTS" == true ]]; then
  echo "Error: worktree '$REMOTE_NAME' already exists at: $REMOTE_PATH" >&2; exit 1
fi

# R20: refuse to clobber an existing local working branch of the same name (zero side effects).
if git -C "$MAIN_WORKTREE" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null 2>&1; then
  echo "Error: a local branch '$BRANCH' already exists. Refusing to overwrite it. Pass --branch <name> with a different name, or delete/rename the existing branch first." >&2
  exit 1
fi

# ── Precondition: remote-svn-main must be a valid SVN working copy (the trust anchor). ──
# Distinguish "directory missing" from "present but not a working copy" and carry svn's reason.
# After the cheap git-only guards (name/collision surface without svn); still BEFORE any mutation.
REMOTE_MAIN_PATH="$WORKTREES_DIR/remote-svn-main"
if [[ ! -d "$REMOTE_MAIN_PATH" ]]; then
  echo "Error: remote-svn-main worktree not found at: $REMOTE_MAIN_PATH. Run git-svn /tp-setup first to bootstrap the main bridge (this skill imports into an existing bridge; it does not create the main bridge)." >&2
  exit 1
fi
if ! SVN_REASON="$(svn info "$REMOTE_MAIN_PATH" 2>&1 1>/dev/null)"; then
  echo "Error: remote-svn-main exists at $REMOTE_MAIN_PATH but is not a valid SVN working copy (svn info failed). Reason: $SVN_REASON. Re-run git-svn /tp-setup to repair the main bridge." >&2
  exit 1
fi

# ── SECURITY (R18 / KTD-8): trust check BEFORE any mutation and before the ERR rollback trap. ──
if ! assert_trusted_svn_url "$REMOTE_MAIN_PATH" "$SVN_URL" >/dev/null; then
  echo "Error: refusing to import from an untrusted/unverifiable SVN URL." >&2
  exit 1
fi

# The SVN branch must already exist (read-only import never creates it).
if ! svn info "$SVN_URL" >/dev/null 2>&1; then
  echo "Error: SVN branch does not exist (or is unreachable): $SVN_URL. tp-checkout-svn-branch imports an EXISTING branch read-only; it does not create SVN paths. Check the URL, or use /tp-push-to-svn first-push to create a new branch." >&2
  exit 1
fi

echo "Importing SVN branch '$SVN_URL' into bridge '$REMOTE_BRANCH' and working branch '$BRANCH'..."

INIT_COMMIT="$(git -C "$MAIN_WORKTREE" rev-list --max-parents=0 HEAD)"
if [[ -z "$INIT_COMMIT" ]]; then echo "Error: git rev-list --max-parents=0 HEAD found no root commit." >&2; exit 1; fi

# Rollback covers the LOCAL git side only. SVN was never written (read-only import), so the
# target SVN branch has no new revision to undo.
WORK_BRANCH_CREATED=false
_rollback() {
    local ec=$?
    echo "Import failed; rolling back local git state (SVN was not modified)..." >&2
    if [[ "$WORK_BRANCH_CREATED" == true ]]; then
      git -C "$MAIN_WORKTREE" branch -D "$BRANCH" 2>/dev/null || true
    fi
    git -C "$MAIN_WORKTREE" worktree remove --force "$REMOTE_PATH" 2>/dev/null || true
    # Prune the registration in case `worktree remove` could not fully delete the dir (e.g. a held
    # .svn handle) -- a surviving registration would wedge a re-run into a false "already imported".
    git -C "$MAIN_WORKTREE" worktree prune 2>/dev/null || true
    git -C "$MAIN_WORKTREE" branch -D "$REMOTE_BRANCH" 2>/dev/null || true
    exit "$ec"
}
trap _rollback ERR

git -C "$MAIN_WORKTREE" branch "$REMOTE_BRANCH" "$INIT_COMMIT"
git -C "$MAIN_WORKTREE" worktree add "$REMOTE_PATH" "$REMOTE_BRANCH"

# READ the SVN content onto the bridge worktree. --force: `git worktree add` already created
# `.git` + init-commit content; svn would otherwise mark them "obstructed".
echo "Running: svn checkout --force $SVN_URL $REMOTE_PATH"
svn checkout --force "$SVN_URL" "$REMOTE_PATH"

# Untrack `.git` from the svn working copy (pure-local WC fix; tolerate "not tracked"). We never
# svn-commit, so this never reaches SVN.
if [[ -e "$REMOTE_PATH/.git" ]]; then
  (cd "$REMOTE_PATH" && svn rm --keep-local '.git' 2>/dev/null || true)
fi

# Bridge worktrees ARE svn working copies; the import commit must NOT capture `.svn/`. Seed the
# bridge .gitignore from main's (so bin/obj/.turbo-plugin/worktrees are ignored too), then
# GUARANTEE `.svn/` is present regardless of main's content. Runs BEFORE `git add -A`.
PEER_GI="$REMOTE_PATH/.gitignore"
if [[ -f "$MAIN_WORKTREE/.gitignore" ]]; then
  cp -f "$MAIN_WORKTREE/.gitignore" "$PEER_GI"
fi
if ! grep -qxF '.svn/' "$PEER_GI" 2>/dev/null; then
  printf '%s\n' '.svn/' >> "$PEER_GI"
fi

# Commit the SVN content onto the bridge branch (overlay on the init commit). The working
# branch then descends from this commit, so it carries the content and the first pull shares
# history with the bridge.
git -C "$REMOTE_PATH" add -A
if ! git -C "$REMOTE_PATH" diff --cached --quiet; then
  git -C "$REMOTE_PATH" commit -m "import: svn branch $REMOTE_NAME"
else
  echo "Imported SVN content matches the repo root commit; bridge left at the root commit."
fi

# Create the working branch descending from the bridge ref (KTD5). Last mutation step.
git -C "$MAIN_WORKTREE" branch "$BRANCH" "$REMOTE_BRANCH"
WORK_BRANCH_CREATED=true

# All steps succeeded; disable the rollback trap.
trap - ERR

echo ""
echo "Imported SVN branch into a new working branch."
echo "  Working branch : $BRANCH"
echo "  Bridge branch  : $REMOTE_BRANCH"
echo "  SVN worktree   : $REMOTE_PATH"
echo "  Next           : git checkout $BRANCH, then /tp-pull-from-svn --branch $BRANCH to sync later SVN changes."
