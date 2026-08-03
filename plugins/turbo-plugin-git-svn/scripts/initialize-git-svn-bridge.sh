#!/usr/bin/env bash
# First-bridge bootstrap for tp-setup case (a) "new git+SVN bridge" and case (b) "take over an
# existing git+SVN repo". A single re-invocable script that bridges the CURRENT repo to a given
# SVN URL and merges the SVN content into the current branch.
#
# This is the FIRST bridge, so there is NO trust anchor to compare against (KTD7): we do NOT call
# assert_trusted_svn_url. Instead the URL is validated against an anchored scheme allowlist
# (http(s)/svn/file) which both rejects malformed URLs and blocks svn-arg injection.
#
# DIFFERS from new-remote-bridge.sh: git init + empty-main-first + orphan/clean of the bridge
# worktree + PLAIN svn checkout (no --force) + merge --allow-unrelated-histories. No svn copy and
# no branch-from-init.
#
# Re-invocability: the identity exit (step 4) leaves only a bare empty .git from `git init` (no
# commit); a re-run is a clean re-run. Mid-run failures after the bridge worktree/branch creation
# roll the LOCAL git side back; an already-executed `svn commit` (svn:ignore) is permanent and a
# re-run absorbs it. A MERGE_CONFLICT (step 13) is NOT rolled back -- the agent resolves it.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

SVN_URL=''
BRANCH='main'
GRANULARITY=''
RANGE=''
ALLOW_EXISTING_REMOTE=false
ALLOW_NESTED_REPOS=false
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
# Load-bearing here more than anywhere else: this is the one script that can CREATE a repository,
# so naming the target outright is the difference between bootstrapping the project the caller
# meant and bootstrapping whatever checkout the process happened to be standing in.
REPO_ROOT=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --svn-url)     [[ $# -ge 2 ]] || { echo "Error: --svn-url requires a value" >&2; exit 1; }; SVN_URL="$2"; shift 2 ;;
    --branch)      [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --granularity) [[ $# -ge 2 ]] || { echo "Error: --granularity requires a value" >&2; exit 1; }; GRANULARITY="$2"; shift 2 ;;
    --range)       [[ $# -ge 2 ]] || { echo "Error: --range requires a value" >&2; exit 1; }; RANGE="$2"; shift 2 ;;
    --repo-root)   [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    --allow-existing-remote) ALLOW_EXISTING_REMOTE=true; shift ;;
    --allow-nested-repos) ALLOW_NESTED_REPOS=true; shift ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

# ---- step 1: git available + new enough. ----
probe_git_version

if [[ -z "$SVN_URL" ]]; then echo "Error: --svn-url is required" >&2; exit 1; fi
if [[ -z "$BRANCH" ]]; then BRANCH='main'; fi

# ---- step 2: URL format validation (anchored scheme allowlist; NO trust anchor exists). ----
# Anchoring (^) + the scheme allowlist rejects malformed URLs AND blocks svn-arg injection
# (e.g. a leading '-' or a non-URL token). This is intentionally NOT assert_trusted_svn_url:
# there is no trusted remote-svn-main yet to derive a repos-root from (KTD7).
if [[ ! "$SVN_URL" =~ ^(https?|svn|file):// ]]; then
  echo "Error: invalid SVN URL '$SVN_URL': only http(s)://, svn://, or file:// URLs are accepted." >&2
  exit 1
fi

# ---- step 3: wrong-repo guards, then git init -b main (idempotent; no identity needed). ----
# `git init` MUST run before the identity check so a later `git config --local` has a repo to write
# to. Only init when NOT already a repo: re-init on an existing repo prints a harmless stderr
# warning and is redundant. Skipping it on re-invoke / case (b) keeps the re-run clean; still
# idempotent.
#
# When we ARE already in a repo, two guards run FIRST, before anything is mutated, so a refusal
# leaves the repo byte-identical. Both exist because, absent --repo-root, this script resolves its
# target from the AMBIENT cwd (git walks up from wherever it was invoked), so an invocation made in
# the wrong directory silently bootstraps a bridge into a repo the caller never named. Passing
# --repo-root removes that failure mode at the source; the guards stay because the ambient default
# is still supported and still the common way this is called.
GIT_ROOT="$(resolve_git_root "$REPO_ROOT")"
if git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  # Guard 1 -- must be the MAIN worktree. From a linked worktree get_main_worktree resolves to a
  # DIFFERENT checkout, so we would create the bridge branch/worktree there and merge SVN content
  # into ITS current branch -- not the branch the caller is standing on. tp-setup already routes
  # peer worktrees to its "verify config only" case; this enforces the same rule for callers that
  # reach the script directly.
  if ! test_is_main_worktree "$REPO_ROOT"; then
    HERE="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --show-toplevel 2>/dev/null || true)"
    echo "Error: refusing to bootstrap an SVN bridge from a linked worktree." >&2
    echo "  you are in:    ${HERE:-<unknown>}" >&2
    echo "  would act on:  $(get_main_worktree "$REPO_ROOT")" >&2
    echo "Bootstrapping here would create the bridge branch and worktree in that OTHER checkout and merge SVN content into its current branch. Re-run from the main worktree instead." >&2
    exit 1
  fi

  # Guard 2 -- an existing git remote means this repo already has a git server, which is the exact
  # situation this plugin does NOT bridge (it exists for SVN-only teams). Far more often than not
  # it means the cwd was wrong. Not a hard refusal: emit a token so the agent can confirm with the
  # user in plain language and re-invoke with --allow-existing-remote.
  if [[ "$ALLOW_EXISTING_REMOTE" != true ]]; then
    EXISTING_REMOTES="$(git -C "$GIT_ROOT" remote 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)"
    if [[ -n "$EXISTING_REMOTES" ]]; then
      echo "TP_TOKEN:EXISTING_GIT_REMOTE remotes=$EXISTING_REMOTES"
      echo "This repository already has git remote(s): $EXISTING_REMOTES"
      echo "turbo-plugin bridges projects whose only shared server is SVN, so this is usually the wrong directory."
      echo "Nothing was changed. Confirm with the user, then re-run with --allow-existing-remote to proceed anyway."
      exit 1
    fi
  fi
else
  # Guard 3 -- not a repo HERE, but child directories are. That is the shape of a workspace folder
  # holding several independent projects side by side, and `git init` here would wrap all of them
  # into one repository: the wrong outcome, and one nothing later undoes. The two guards above
  # cannot catch it, because this directory genuinely has no git and `git rev-parse` only searches
  # UPWARD, never down. Not a hard refusal -- a real project can legitimately contain a vendored
  # sub-repo -- so emit a token and let the agent ask which project was meant.
  if [[ "$ALLOW_NESTED_REPOS" != true ]]; then
    NESTED=''
    for _child in "$GIT_ROOT"/*/; do
      [[ -d "$_child" ]] || continue
      [[ -e "${_child}.git" ]] || continue
      _name="$(basename -- "${_child%/}")"
      NESTED="${NESTED:+$NESTED }$_name"
    done
    if [[ -n "$NESTED" ]]; then
      echo "TP_TOKEN:NESTED_GIT_REPOS dirs=$NESTED"
      echo "This directory is not a git repository, but these subdirectories are: $NESTED"
      echo "Creating a repository here would wrap those separate projects into one."
      echo "Nothing was changed. Switch to the project you meant, or re-run with --allow-nested-repos if a repository really belongs here."
      exit 1
    fi
  fi

  git -C "$GIT_ROOT" init -b main
fi

MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT")"

# ---- step 4: git identity check (merged local+global; plain reads, NOT --local). ----
# `git commit` needs an identity. If EITHER name or email is empty, emit the token on stdout so
# the agent can set identity and re-invoke; the bare .git from step 3 makes the re-run clean.
GIT_NAME="$(git -C "$MAIN_WORKTREE" config user.name 2>/dev/null || true)"
GIT_EMAIL="$(git -C "$MAIN_WORKTREE" config user.email 2>/dev/null || true)"
if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
  echo 'TP_TOKEN:IDENTITY_REQUIRED'
  echo 'git identity is not configured (user.name and/or user.email). Set them with:'
  echo '  git config user.name "<your name>"'
  echo '  git config user.email "<you@example.com>"'
  echo 'then re-run.'
  exit 1
fi

# ---- step 5: case split on "has root commit" (NOT ".git exists"). ----
# EAP-safe HEAD probe via `if`: no HEAD is the NORMAL case (a) state, not a hard failure.
if git -C "$MAIN_WORKTREE" rev-parse --verify HEAD >/dev/null 2>&1; then
  HAS_ROOT=true
else
  HAS_ROOT=false
fi
if [[ "$HAS_ROOT" == false ]]; then
  # case (a): seed an empty root commit so the current branch ('main') has a HEAD to merge into.
  git -C "$MAIN_WORKTREE" commit --allow-empty -m "chore: initial commit (turbo-plugin setup)"
fi
# case (b) (has root commit): use the current branch as-is, no commit.

# ---- step 6: resolve the bridge ref + worktree dir, with collision + partial-state guards. ----
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

RESOLVED="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")" || exit 1
REMOTE_NAME="${RESOLVED%%|*}"
REMOTE_BRANCH="${RESOLVED#*|}"; REMOTE_BRANCH="${REMOTE_BRANCH%%|*}"
REMOTE_PATH="${RESOLVED##*|}"

# Collision: a DIFFERENT existing remote-svn branch mapping to the same worktree dir name.
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

# Bridge already-exists / inconsistent partial-state (ref XOR dir) guards. SAME wording as
# new-remote-bridge.sh -- the unit tests distinguish the two arms by their UNIQUE wording (the
# ref-without-dir arm says 'git branch -D'; the dir-without-ref arm says 'delete that directory').
BRIDGE_EXISTS=false
if git -C "$MAIN_WORKTREE" branch --list "$REMOTE_BRANCH" | grep -q .; then BRIDGE_EXISTS=true; fi
WT_EXISTS=false
if [[ -e "$REMOTE_PATH" ]]; then WT_EXISTS=true; fi
if [[ "$BRIDGE_EXISTS" == true && "$WT_EXISTS" == false ]]; then
  echo "Error: inconsistent bridge state: branch '$REMOTE_BRANCH' exists but its worktree directory is missing ($REMOTE_PATH) -- likely a leftover from an interrupted bootstrap. To recover, run in the main worktree ($MAIN_WORKTREE): 'git worktree prune', then 'git branch -D $REMOTE_BRANCH'; then re-run /tp-setup." >&2
  exit 1
fi
if [[ "$WT_EXISTS" == true && "$BRIDGE_EXISTS" == false ]]; then
  echo "Error: inconsistent bridge state: the worktree directory exists ($REMOTE_PATH) but branch '$REMOTE_BRANCH' is missing -- likely a leftover from an interrupted bootstrap. To recover, delete that directory and run 'git worktree prune' in the main worktree ($MAIN_WORKTREE); then re-run /tp-setup." >&2
  exit 1
fi
if [[ "$BRIDGE_EXISTS" == true ]]; then
  echo "Error: bridge branch '$REMOTE_BRANCH' already exists." >&2; exit 1
fi
if [[ "$WT_EXISTS" == true ]]; then
  echo "Error: worktree '$REMOTE_NAME' already exists at: $REMOTE_PATH" >&2; exit 1
fi

# ---- step 6.5 (U7): decide the first-import granularity from the URL's history, BEFORE creating
# the bridge worktree, so a ">5 needs choice" exit leaves ZERO residue (a clean re-run). ----
# HEAD_REV=0 (empty repo) or an empty log => LEGACY single import commit (today's shape). <=5
# revisions => per-revision (silent). >5 => needs a granularity choice; absent one, emit the
# structured token + exit 0 with nothing created (so the SKILL can prompt, then re-invoke).
# Two failures hide behind one `svn info`, and they need opposite responses: the server being
# unreachable is an environment problem, while the PATH not existing is normal and fixable right
# here (nothing in this plugin ever ran `svn mkdir`, so a project's landing spot had to be created
# by hand first -- even though case (a) of tp-setup advertises "brand new git + SVN").
#
# The old code collapsed both into "Is the URL reachable?" AND swallowed stderr, so pointing it at
# a perfectly reachable repository with a typo'd path produced a message about reachability. svn's
# own answer is precise -- `W170000: URL ... non-existent in revision N` -- it was just discarded.
# So: keep svn's message, classify on it, and emit a token the SKILL can act on. Both arms exit
# before anything is created, so a re-run after fixing is clean.
SVN_INFO_ERR=''
if ! SVN_INFO_ERR="$(svn info "$SVN_URL" 2>&1 >/dev/null)"; then
  if printf '%s' "$SVN_INFO_ERR" | grep -qE 'non-existent in revision|W170000|E200009'; then
    echo "TP_TOKEN:SVN_PATH_MISSING url=$SVN_URL"
    echo "Error: the repository is reachable, but '$SVN_URL' does not exist in it." >&2
  else
    echo "TP_TOKEN:SVN_UNREACHABLE url=$SVN_URL"
    echo "Error: could not reach the SVN repository for '$SVN_URL'." >&2
  fi
  # svn's own words, verbatim -- they name the actual cause (auth, DNS, a typo'd path).
  printf '%s\n' "$SVN_INFO_ERR" >&2
  exit 1
fi

HEAD_REV="$(svn info --show-item revision "$SVN_URL" 2>/dev/null | tr -d '[:space:]')" \
  || { echo "Error: could not read SVN revision from '$SVN_URL'." >&2; exit 1; }

FIRST_REV=0
IMPORT_COUNT=0
if [[ "$HEAD_REV" =~ ^[0-9]+$ ]] && (( HEAD_REV > 0 )); then
  IMPORT_LOG_XML="$(svn log --xml -r "1:$HEAD_REV" "$SVN_URL" 2>/dev/null)" \
    || { echo "Error: could not read SVN history from '$SVN_URL'." >&2; exit 1; }
  # FIRST_REV = earliest revision touching the URL path; IMPORT_COUNT = total (U1 enumerator).
  while IFS= read -r -d '' rec; do
    IMPORT_COUNT=$((IMPORT_COUNT + 1))
    if (( FIRST_REV == 0 )); then FIRST_REV="${rec%%$'\037'*}"; fi
  done < <(printf '%s' "$IMPORT_LOG_XML" | svn_enumerate_revisions)
fi

MODE='per-revision'
if (( IMPORT_COUNT == 0 )); then
  MODE='legacy-empty'
elif (( IMPORT_COUNT > TP_GRANULARITY_THRESHOLD )); then
  if [[ -z "$GRANULARITY" ]]; then
    printf 'TP_TOKEN:GRANULARITY_REQUIRED count=%s range=r%s:r%s\n' "$IMPORT_COUNT" "$FIRST_REV" "$HEAD_REV"
    exit 0
  fi
  MODE="$GRANULARITY"
fi

# The worktrees container does not exist yet on a first bootstrap; create it so `git worktree add`
# has a parent. new-remote-bridge.sh can assume it exists (it runs post-setup); this script IS the
# setup, so it must create it.
mkdir -p "$WORKTREES_DIR"

echo "Connecting current repo to SVN bridge '$REMOTE_BRANCH'..."

SVN_REV=''

# Rollback covers the LOCAL git side only. An already-executed `svn commit` is permanent and is NOT
# rolled back (a re-run absorbs it). FIRST `chmod -R +w` the bridge dir -- SVN's .svn/pristine files
# are read-only and otherwise block `git worktree remove --force`. Prune as a fallback in case the
# dir could not be fully deleted (a held .svn handle), so a re-run isn't wedged into a false
# "already exists".
_rollback() {
    local ec=$?
    echo "Bridge setup failed; rolling back local git state (an already-executed svn commit is permanent)..." >&2
    if [[ -e "$REMOTE_PATH" ]]; then
      chmod -R +w "$REMOTE_PATH" 2>/dev/null || true
    fi
    git -C "$MAIN_WORKTREE" worktree remove --force "$REMOTE_PATH" 2>/dev/null || true
    git -C "$MAIN_WORKTREE" worktree prune 2>/dev/null || true
    git -C "$MAIN_WORKTREE" branch -D "$REMOTE_BRANCH" 2>/dev/null || true
    exit "$ec"
}
trap _rollback ERR

# ---- step 7: build the EMPTY bridge worktree (orphan branch, empty index + working tree). ----
git -C "$MAIN_WORKTREE" worktree add --detach --no-checkout "$REMOTE_PATH"
git -C "$REMOTE_PATH" checkout --orphan "$REMOTE_BRANCH"
# Clear the index. Tolerate "pathspec '.' did not match" when the index is already empty.
git -C "$REMOTE_PATH" rm -rf --cached . >/dev/null 2>&1 || true
git -C "$REMOTE_PATH" clean -dffx

# ---- step 8 (U7): svn checkout (no --force; the worktree is empty except the .git pointer).
# per-revision/range replay forward from the FIRST revision; squash/legacy start at HEAD. ----
if [[ "$MODE" == "per-revision" || "$MODE" == "range" ]]; then
  echo "Running: svn checkout -r $FIRST_REV $SVN_URL $REMOTE_PATH"
  svn checkout -r "$FIRST_REV" "$SVN_URL" "$REMOTE_PATH"
else
  echo "Running: svn checkout $SVN_URL $REMOTE_PATH"
  svn checkout "$SVN_URL" "$REMOTE_PATH"
fi

# ---- step 9b: keep svn metadata out of git for the WHOLE import, independent of .gitignore. ----
# The bridge .gitignore can only be written AFTER the import (step 10 below explains why), so
# `git add -A` needs a different ignore source while the replay runs. info/exclude is repo-local,
# unversioned and idempotent -- and `.svn/` should never be tracked in this repo anyway. Must be the
# repo's COMMON git dir: git reads info/exclude from there, not from a linked worktree's own gitdir.
ensure_svn_git_excluded "$MAIN_WORKTREE"

# ---- step 9: untrack .git from the svn working copy (tolerate "not tracked"). ----
if [[ -e "$REMOTE_PATH/.git" ]]; then
  (cd "$REMOTE_PATH" && svn rm --keep-local '.git' 2>/dev/null || true)
fi

# ---- step 11 (U7): materialise the import commit(s) onto the orphan bridge branch. ----
# legacy-empty (empty / no-content URL): today's single import commit. Otherwise reuse the shared
# U3 enumerate+replay dispatch so the bootstrap and the steady-state pull mint IDENTICAL commit
# shapes (author / date / svn-revision trailer). cur = FIRST_REV-1 so the loop starts at FIRST_REV.
if [[ "$MODE" == "legacy-empty" ]]; then
  git -C "$REMOTE_PATH" add -A
  SVN_REV="$(svn info --show-item revision "$REMOTE_PATH" 2>/dev/null || true)"
  if git -C "$REMOTE_PATH" diff --cached --quiet; then
    git -C "$REMOTE_PATH" commit --allow-empty -m "init: remote-svn/$BRANCH branch"
  else
    git -C "$REMOTE_PATH" commit -m "sync: svn r$SVN_REV"
  fi
else
  svn_replay_dispatch "$REMOTE_PATH" "$REMOTE_NAME" "$((FIRST_REV - 1))" "$HEAD_REV" "$MODE" "$RANGE"
fi

# ---- step 10 (REMOVED): the bridge no longer invents a .gitignore. ----
# It used to append `.svn/` to the bridge worktree's .gitignore here. That single line was the sole
# cause of a guaranteed first-time conflict: the bridge branch and the project's branch share no
# history, so `merge --allow-unrelated-histories` compares them with an EMPTY base -- and git
# conflicts on add/add unless the two sides are byte-identical. A project with any .gitignore at all
# (proj-2 had one line, `*.log`) therefore ALWAYS conflicted, on a file whose only difference was
# the line this tool had just written. Verified against git: identical content merges clean, a
# strict superset still conflicts.
#
# Nothing is lost by dropping it. `.svn/` must stay out of git for the import's `git add -A`, and
# that is guaranteed independently by ensure_svn_git_excluded above (info/exclude, which does not
# care what SVN carries); the project's own .gitignore gets `.svn/` and `.turbo-plugin/worktrees/`
# appended by tp-setup right after this script returns, and reaches SVN through the normal push.
# The bridge now mirrors exactly what SVN has -- which is what a bridge is for.
#
# Keep the capture below: it is a fail-safe for anything the import left in the worktree, not a
# consequence of the write that used to be here.
# bridge commit with no `svn-revision:` trailer is exactly the shape the pull path treats as an
# orphaned sync, and a second commit carrying the HEAD trailer would break the floor lookup's
# fail-loud-on-duplicate rule. Amending keeps the message (trailer), author and date intact, so the
# end state matches the squash path: the import commit at HEAD contains the bridge .gitignore.
if [[ -n "$(git -C "$REMOTE_PATH" status --porcelain)" ]]; then
  PRE_AMEND_SHA="$(git -C "$REMOTE_PATH" rev-parse --verify --quiet HEAD || true)"
  git -C "$REMOTE_PATH" add -A
  if [[ -n "$PRE_AMEND_SHA" ]]; then
    git -C "$REMOTE_PATH" -c commit.gpgsign=false commit --amend --no-edit
    # The amend REWROTE that commit, so any refs/tp/svn/<N> still pointing at the pre-amend SHA now
    # references an object no longer on the branch (it would read as an unmarked, orphan-shaped
    # commit). Move those markers onto the rewritten commit.
    AMEND_NEW_SHA="$(git -C "$REMOTE_PATH" rev-parse HEAD)"
    while read -r _mrev _msha; do
      [[ -z "$_mrev" ]] && continue
      if [[ "$_msha" == "$PRE_AMEND_SHA" ]]; then
        svn_rev_mark_set "$REMOTE_PATH" "$_mrev" "$AMEND_NEW_SHA"
      fi
    done < <(svn_rev_marks "$REMOTE_PATH")
  else
    # No import commit exists (empty/no-content URL never reaches here, but stay fail-safe).
    git -C "$REMOTE_PATH" -c commit.gpgsign=false commit -m "init: remote-svn/$BRANCH branch"
  fi
fi

# ---- step 11b: the bridge branch MUST exist as a commit before step 13 can merge it. ----
# An SVN path that EXISTS BUT IS EMPTY imports no files and dirties nothing, so none of the commit
# paths above fire and `remote-svn/<branch>` stays unborn -- step 13 then dies on "not something we
# can merge". That state used to be unreachable: the (now removed) step 10 always wrote a .gitignore
# into the bridge, which made the tree dirty and sent us down the fail-safe below. It became
# reachable the moment `new-svn-path` let a user create a trunk and bootstrap straight into it, so
# the guard has to be unconditional rather than a branch of the dirty-tree check.
if ! git -C "$REMOTE_PATH" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  git -C "$REMOTE_PATH" -c commit.gpgsign=false commit --allow-empty -m "init: remote-svn/$BRANCH branch"
fi

# ---- step 12: pin svn:ignore=.git on the SVN side and commit it (permanent; re-run absorbs), then
# `svn update` so the whole WC sits uniformly at SVN HEAD -- a subsequent tp-pull-from-svn then
# resolves cur=HEAD and imports nothing (no double-import; KTD4 mixed-revision floor). ----
(
  cd "$REMOTE_PATH"
  svn propset svn:ignore '.git' '.'
  svn commit -m 'svn:ignore=.git (turbo-plugin bridge)'
  svn update
)
SVN_REV="$(svn info --show-item revision "$REMOTE_PATH" 2>/dev/null | tr -d '[:space:]' || true)"

# All bridge-creation steps succeeded; disable the rollback trap before the merge.
trap - ERR

# ---- step 13: merge the bridge content into the current branch (OUTSIDE the rollback scope). ----
# --allow-unrelated-histories because the orphan bridge branch shares no history with the current
# branch. A conflict only happens in case (b) with overlapping files: emit the token (conflicted
# files, space-separated) and leave the conflict in place for the agent/user -- do NOT
# `git merge --abort` and do NOT roll back.
if ! git -C "$MAIN_WORKTREE" merge --allow-unrelated-histories -m "chore: connect SVN bridge via turbo-plugin" "$REMOTE_BRANCH"; then
  CONFLICTS="$(git -C "$MAIN_WORKTREE" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
  CONFLICTS="${CONFLICTS% }"
  if [[ -n "$CONFLICTS" ]]; then
    echo "TP_TOKEN:MERGE_CONFLICT $CONFLICTS"
  else
    # The merge was refused for a reason that is NOT a content conflict. Reporting a conflict here
    # sends the reader hunting for conflicted files that do not exist -- observed on a real machine,
    # where the actual cause (an unborn bridge branch) was two steps upstream. Git's own message is
    # already on stderr; do not overwrite it with a wrong diagnosis.
    echo "TP_TOKEN:MERGE_FAILED branch=$REMOTE_BRANCH"
  fi
  exit 1
fi

# ---- step 14: success summary. ----
echo ""
echo "SVN bridge connected."
echo "  Bridge branch : $REMOTE_BRANCH"
echo "  SVN worktree  : $REMOTE_PATH"
echo "  SVN revision  : r$SVN_REV"
