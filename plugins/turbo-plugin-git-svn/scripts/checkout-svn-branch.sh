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

if [[ -z "$SVN_URL" ]]; then echo "Error: --svn-url is required (the existing SVN branch URL to import)" >&2; exit 1; fi

MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT")"
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
# Factored so it can run twice: once on the SVN-leaf-derived name (git-only early reject, no svn
# needed) and again after R7 adopts the stored original branch name in the resolution block below.
# Reads the globals BRANCH / REMOTE_NAME / REMOTE_BRANCH / REMOTE_PATH / MAIN_WORKTREE.
assert_name_free() {
  local EXISTING=() line COLLISION BRIDGE_EXISTS=false WT_EXISTS=false
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
  if git -C "$MAIN_WORKTREE" branch --list "$REMOTE_BRANCH" | grep -q .; then BRIDGE_EXISTS=true; fi
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
}

# First pass on the leaf-derived tentative name so the git-only rejects surface without svn.
assert_name_free

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

# The imported branch is based on remote-svn/main (the trunk mirror) so it shares history with this
# repo's main; require that anchor ref up-front (before any mutation).
if ! git -C "$MAIN_WORKTREE" rev-parse --verify -q 'refs/heads/remote-svn/main' >/dev/null; then
  echo "Error: bridge anchor branch 'remote-svn/main' not found. Run git-svn /tp-setup first to bootstrap the main bridge." >&2
  exit 1
fi

# ── Graded fork-point resolution (U5, READ-ONLY: svn propget / svn log / git log). ──
# Rewire the import base from "remote-svn/main tip" to the git commit replaying the branch's TRUE
# fork revision (R8-R11), so a later merge-back is not spurious-conflict-ridden. Every step is
# side-effect-free and runs BEFORE `trap _rollback ERR`, so each stop is a clean pre-mutation exit
# that leaves NO bridge/worktree. remote-svn/main stays the trust anchor + SVN working copy; it is
# just no longer the import base.

# (a) Branch metadata (U2). Absent props read back empty (never an error).
STORED_NAME="$(get_tp_branch_prop 'branch-name' "$SVN_URL")"
STORED_REV="$(get_tp_branch_prop 'last-aligned-rev' "$SVN_URL")"
if ! COPYFROM_RAW="$(get_svn_branch_copyfrom_rev "$SVN_URL")"; then
  echo "Error: could not read the branch's copyfrom-rev from SVN (svn log --stop-on-copy failed): $SVN_URL." >&2
  exit 1
fi
COPYFROM_REV=0
if [[ "$COPYFROM_RAW" =~ ^[0-9]+$ ]]; then COPYFROM_REV="$COPYFROM_RAW"; fi

# (b) R7: when --branch was not passed, prefer the stored ORIGINAL git branch name (slashes
# preserved) over the dash-form SVN leaf. Re-resolve + re-run the name guards against the FINAL
# name (still pre-mutation, zero side effects).
if [[ "$DERIVED" == true && -n "$STORED_NAME" && "$STORED_NAME" != "$BRANCH" ]]; then
  BRANCH="$STORED_NAME"
  if ! RESOLVED="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR" 2>&1)"; then
    echo "$RESOLVED" >&2; exit 1
  fi
  REMOTE_NAME="${RESOLVED%%|*}"
  REMOTE_BRANCH="${RESOLVED#*|}"; REMOTE_BRANCH="${REMOTE_BRANCH%%|*}"
  REMOTE_PATH="${RESOLVED##*|}"
  assert_name_free
fi

# (c) Target revision R + stale cross-check (R11 "stale-but-present"). tp:last-aligned-rev is
# initialized to the branch's trunk copyfrom-rev and only advances, so a stored value BELOW the
# copyfrom-rev is a provable contradiction -> refuse (never attach to a stale/contradicted base).
if [[ -n "$STORED_REV" ]]; then
  if ! [[ "$STORED_REV" =~ ^[0-9]+$ ]]; then
    echo "Error: branch metadata tp:last-aligned-rev on $SVN_URL is not a revision number ('$STORED_REV'). Refusing to guess a base; have the branch author repair it, then re-run this checkout." >&2
    exit 1
  fi
  R="$STORED_REV"
  if (( R < COPYFROM_REV )); then
    echo "Error: cannot attach: stored alignment r$R is older than the branch's fork revision r$COPYFROM_REV, so the branch metadata looks stale/contradictory. Ask the branch author to refresh it (merge main into the branch and push), then re-run this checkout." >&2
    exit 1
  fi
else
  # Pre-feature branch (metadata backfill is a deferred follow-up): fall back to the trunk
  # copyfrom-rev as the fork revision.
  R="$COPYFROM_REV"
fi

# (d) Grade R against cur (highest replayed revision on main) FIRST, then floor-resolve inside the
# R<=cur region. Grading before the floor is load-bearing: an R>cur target would otherwise silently
# floor onto the STALE cur commit and hide un-replayed trunk revisions -- regressing AE3/R9.
#
# BUT grade on the EFFECTIVE revision, not on R itself. SVN revision numbers are repository-global:
# r(cur+1)..R may consist entirely of commits to OTHER paths, in which case trunk@R is byte-identical
# to trunk@cur and there is nothing to pull. Comparing R directly then produced an UNBREAKABLE
# deadlock -- checkout demanded a pull, and the pull correctly reported "already up to date" because
# trunk had no new revision, so every retry failed the same way. Real case: a branch copied from
# main@r52 while main's last actual change was r46.
# R_EFF = the newest revision <= R in which the trunk path ITSELF changed (`svn info` on a pegged
# URL; read-only, one call). R_EFF > CUR is then the genuine "trunk really has un-replayed
# revisions" case that AE3/R9 is about, and R_EFF <= CUR correctly falls through to the floor
# lookup, which lands on the commit for r46 and attaches. Fail-safe: if the probe cannot be
# resolved, fall back to R (the previous, conservative behavior).
CUR="$(svn_highest_replayed_rev "$MAIN_WORKTREE")"
MAIN_SVN_URL="$(svn info --show-item url "$REMOTE_MAIN_PATH" 2>/dev/null | tr -d '[:space:]' || true)"
R_EFF="$R"
if [[ -n "$MAIN_SVN_URL" ]]; then
  PROBE="$(svn info --show-item last-changed-revision "${MAIN_SVN_URL}@${R}" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$PROBE" =~ ^[0-9]+$ ]]; then R_EFF="$PROBE"; fi
fi
if (( R_EFF > CUR )); then
  echo "Error: cannot attach: the branch's aligned trunk revision r$R is newer than the newest replayed revision on local main (r$CUR). Pull trunk first: run /tp-pull-from-svn --branch main, then re-run this checkout." >&2
  exit 1
fi
if ! FORK_COMMIT="$(svn_floor_commit_for_rev "$MAIN_WORKTREE" "$R")"; then
  echo "Error: could not resolve a unique fork commit for r$R on local main (ambiguous replayed history). Refusing to guess a base." >&2
  exit 1
fi
if [[ -z "$FORK_COMMIT" ]]; then
  echo "Error: cannot attach: the branch's aligned trunk revision r$R has no replayed commit on local main and cannot be pulled (it predates the earliest replayed revision, or its range was squashed away). Ask the branch author to merge main into the branch and push, then re-run this checkout." >&2
  exit 1
fi
# $FORK_COMMIT is the base ref for the bridge branch (replaces 'remote-svn/main' below): a real
# ancestor on main carrying svn-revision <= R. The import machinery keeps the SVN branch tree; only
# the import commit's PARENT moves to $FORK_COMMIT.

echo "Importing SVN branch '$SVN_URL' into bridge '$REMOTE_BRANCH' and working branch '$BRANCH'..."

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

# Base the bridge branch on the FORK COMMIT resolved above (the replayed-trunk commit at the
# branch's true fork revision, U5) so the imported branch shares history with this repo's main AT
# the fork-point: a later merge-back is not spurious-conflict-ridden, and `git merge-base main
# <branch>` resolves to $FORK_COMMIT. This is a base-ref SWAP only -- the import machinery below
# (empty worktree -> svn checkout -> git add -A -> commit) captures the EXACT SVN branch tree
# regardless of the base, so only the import commit's PARENT moves; a naive `git branch <name>
# <forkCommit>` (trunk-at-fork content, no import commit) would be wrong. $FORK_COMMIT is an
# ancestor on main and was verified non-empty above.
git -C "$MAIN_WORKTREE" branch "$REMOTE_BRANCH" "$FORK_COMMIT"
git -C "$MAIN_WORKTREE" worktree add --no-checkout "$REMOTE_PATH" "$REMOTE_BRANCH"
# Clear any pin left behind by 0.7.x BEFORE anything materialises files, so this bridge matters:
# written the same way every other working copy is. The old pin forced LF here because SVN,
# carrying no svn:eol-style, stored whatever bytes it was handed; SVN normalises on commit now,
# so a bridge that behaved differently from the user own worktrees would be a pure surprise.
ensure_bridge_eol_platform_native "$MAIN_WORKTREE" "$REMOTE_PATH"
git -C "$REMOTE_PATH" reset --hard --quiet
# EMPTY the worktree (keep the .git pointer) so the plain `svn checkout` below yields the EXACT SVN
# branch tree. `git add -A` then records precisely the branch's delta from trunk (adds/mods/deletes)
# as ONE commit whose parent is remote-svn/main -- content-accurate AND connected to main.
git -C "$REMOTE_PATH" rm -rf . >/dev/null 2>&1 || true
git -C "$REMOTE_PATH" clean -dffx

# READ the SVN content onto the (empty) bridge worktree. PLAIN svn checkout (no --force): the
# worktree is empty except the .git pointer file.
echo "Running: svn checkout $SVN_URL $REMOTE_PATH"
svn checkout "$SVN_URL" "$REMOTE_PATH"

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

# Commit the branch's delta onto the bridge branch (a commit whose parent is remote-svn/main).
# The working branch then descends from this commit, so it carries the content, connects to main,
# and the first pull shares history with the bridge. When the SVN branch is identical to trunk
# (no delta), seed an --allow-empty commit so the working branch still has a HEAD to descend from.
git -C "$REMOTE_PATH" add -A
if ! git -C "$REMOTE_PATH" diff --cached --quiet; then
  git -C "$REMOTE_PATH" commit -m "import: svn branch $REMOTE_NAME"
else
  git -C "$REMOTE_PATH" commit --allow-empty -m "import: svn branch $REMOTE_NAME (empty)"
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
