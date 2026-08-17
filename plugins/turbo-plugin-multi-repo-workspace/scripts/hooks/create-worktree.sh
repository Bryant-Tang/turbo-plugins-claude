#!/usr/bin/env bash
# WorktreeCreate hook — turbo-plugin-multi-repo-workspace.
#
# WHY THIS EXISTS
# A multi-repo workspace is a folder that is NOT itself a git repository, with several independent
# repos side by side. Claude Code's built-in isolation needs a git repository, so at the workspace
# root it fails outright; `cd`-ing into one sub-project first works but pins the session to that
# one project, which throws away the entire point of the workspace. This hook makes isolation work
# AT the workspace root: it hands back a mirror of the workspace whose children are real worktrees,
# so `git -C <project>` still reaches every project while nothing touches a main checkout.
#
# ⚠ THIS HOOK REPLACES THE BUILT-IN FOR **EVERY** REPO, NOT JUST WORKSPACES.
# Verified empirically (2026-08-14): a WorktreeCreate hook fires even when the session starts
# inside an ordinary git repository. The docs' "Outside a git repository: delegates to hooks" line
# describes one case, not a restriction; the hooks reference's "Replaces default git behavior" is
# the accurate one. So the ordinary-repo branch below is NOT dead code -- it is what happens every
# time anyone with this plugin installed opens an isolated session in any repo, and if it is wrong
# the damage is not limited to workspaces.
#
# CONTRACT (observed, not just documented)
#   stdin : {"session_id":…,"transcript_path":…,"cwd":"C:\\…","hook_event_name":"WorktreeCreate",
#            "name":"<generated-slug>"}
#   stdout: the ABSOLUTE PATH of the created working copy — nothing else on stdout, ever.
#   exit  : any non-zero fails worktree creation, so diagnostics go to stderr.
#
# Claude Code VALIDATES the path we print: if git resolves it to an enclosing checkout it refuses
# with a clear message. That protects against returning a bogus path — it does NOT protect against
# returning a valid worktree branched from the wrong base. See pick_base_ref.
set -uo pipefail

log() { printf 'turbo-plugin worktree-create: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

payload="$(cat)"

# Field extraction by sed, deliberately not jq or node: neither is guaranteed present on a stock
# Git-for-Windows box, and a missing parser here would mean "no isolated session at all".
# Both fields are flat scalars in a one-line object, so this is sufficient.
json_str() {
  printf '%s' "$payload" |
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' |
    head -n 1
}

NAME="$(json_str name)"
RAW_CWD="$(json_str cwd)"
[[ -n "$NAME" ]] || die "no 'name' in the hook payload"

# The name is pasted straight into a path and a branch name below. It is a Claude Code session
# slug today, not user input, but a separator or a `..` in it would silently place the worktree
# outside the directory we mean to use. Refuse loudly instead of creating it somewhere else.
case "$NAME" in
  */*|*\\*|*..*|-*) die "implausible worktree name from the hook payload: $NAME" ;;
esac

# The payload carries a Windows path with escaped backslashes (C:\\Users\\…). Turn it into the
# forward-slash form git and bash both accept on every platform.
to_unix_path() {
  local p="$1"
  p="${p//\\\\//}"
  p="${p//\\//}"
  printf '%s' "$p"
}

WORKSPACE="$(to_unix_path "$RAW_CWD")"
[[ -n "$WORKSPACE" ]] || WORKSPACE="$PWD"
[[ -d "$WORKSPACE" ]] || die "cwd from the payload is not a directory: $WORKSPACE"

# Base ref for new worktrees.
#
# Claude Code's built-in default is `fresh`: branch from origin/<default-branch>, NOT from whatever
# the checkout happens to be sitting on. That default is the safer one and we keep it -- inheriting
# an arbitrary current branch is exactly the "the folder you were standing in was perfectly legal"
# failure this plugin exists to warn about.
#
# KNOWN LIMITATION: the `worktree.baseRef` setting is not read. Honouring it would mean resolving
# and merging Claude Code's settings files here, and doing that without a guaranteed JSON parser is
# more likely to break the hook than to help. A user who has set `baseRef: head` gets `fresh`
# behaviour from this hook instead. Documented in the plugin README.
pick_base_ref() {
  local repo="$1" head_ref default_branch
  head_ref="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$head_ref" ]]; then
    printf '%s' "${head_ref#refs/remotes/}"
    return 0
  fi
  for default_branch in main master; do
    if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$default_branch" >/dev/null 2>&1; then
      printf 'origin/%s' "$default_branch"
      return 0
    fi
  done
  # No origin at all (a purely local repo, which is the norm for the git↔SVN workflow this suite
  # serves): HEAD is the only meaningful base.
  printf 'HEAD'
}

# Add one worktree. Never fatal on its own: a single unco-operative project must not cost the user
# the whole isolated session, and the absence of that directory is a LOUD failure later (the agent
# gets file-not-found) rather than a silent write to the main checkout.
add_worktree() {
  local repo="$1" dest="$2" branch="$3" base
  [[ -e "$dest" ]] && { log "already present, leaving alone: $dest"; return 0; }
  base="$(pick_base_ref "$repo")"
  if git -C "$repo" worktree add --quiet -b "$branch" "$dest" "$base" 2>/dev/null; then
    return 0
  fi
  # A branch of that name may already exist (a re-entered session); attach to it rather than fail.
  if git -C "$repo" worktree add --quiet "$dest" "$branch" 2>/dev/null; then
    return 0
  fi
  log "could not create a worktree for '$repo' (base '$base') — that project will be absent"
  return 1
}

# A workspace root DECLARES itself rather than being inferred.
#
# The branch below used to be chosen purely by "is this directory a git repository?", which made the
# whole multi-repo mirror depend on the ABSENCE of something. One `git init` at the workspace root
# -- the exact mistake tp-multi-repo-workspace-setup warns about, in its own words "事後沒有東西能
# 還原" -- and every later session silently isolated the root repo alone, with none of the projects
# in it. Nothing failed; the feature just stopped existing. Reading the marker the setup skill
# writes turns that inference into a declaration, so the accident can be reported instead.
has_workspace_marker() {
  local f="$1/CLAUDE.md"
  [[ -f "$f" ]] || return 1
  grep -q 'turbo-plugin:begin multi-repo-workspace' "$f" 2>/dev/null
}

# Direct children that are non-bare git repositories. Used both to build the mirror and to notice
# the "root became a repo" accident above.
list_projects() {
  local root="$1" child
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    [[ -d "$child" ]] || continue
    git -C "$child" rev-parse --git-dir >/dev/null 2>&1 || continue
    # A child WITHOUT its own .git resolves UP to an enclosing repo, so the moment the workspace
    # root is itself a repository every plain folder answers "yes" to the line above and would be
    # surveyed as a project. Require the child to own its repository.
    #
    # Tested by the presence of `.git` rather than by comparing `rev-parse --show-toplevel` against
    # the path: git answers with a Windows path (C:/Users/...) while `find` yields the MSYS spelling
    # (/c/Users/... or /tmp/...), so that comparison never matches on Git Bash and would filter out
    # every project. `.git` is a directory in a normal clone and a file in a linked worktree, so
    # -e covers both.
    [[ -e "$child/.git" ]] || continue
    # A bare repo has no working tree, so `worktree add` on it is meaningless. Local bare mirrors
    # do sit next to projects in practice; without this they were surveyed as projects, failed, and
    # produced an alarming log line about a project that was never a project.
    [[ "$(git -C "$child" rev-parse --is-bare-repository 2>/dev/null)" == "true" ]] && continue
    printf '%s\n' "$child"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | LC_ALL=C sort)
}

# ── ordinary git repository ──────────────────────────────────────────────────
# Reproduce the built-in: one worktree under <repo>/.claude/worktrees/<name>, on a new branch.
if ! has_workspace_marker "$WORKSPACE" && git -C "$WORKSPACE" rev-parse --git-dir >/dev/null 2>&1; then
  top="$(git -C "$WORKSPACE" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || die "inside a git dir but no working tree: $WORKSPACE"
  # Loud, because this is the one shape that is legal, silent and wrong: a repository that also has
  # repositories directly inside it is almost always a workspace root somebody ran `git init` in.
  # We still do the ordinary thing (guessing the other way could isolate the wrong tree), but the
  # user gets told why their projects are missing instead of discovering it later.
  # `-e "$WORKSPACE/.git"`, not a comparison against `$top`: git answers with the Windows spelling
  # (C:/Users/...) while the payload carries the MSYS one, so a string compare never matches on Git
  # Bash and this warning would never fire -- which is how it was written the first time.
  if [[ -e "$WORKSPACE/.git" ]] && [[ -n "$(list_projects "$WORKSPACE" | head -n 1)" ]]; then
    log "'$top' is a git repository AND holds git repositories directly inside it."
    log "Isolating the outer repository only -- the projects will NOT be in this worktree."
    log "If this is meant to be a multi-repo workspace, it must not be a git repository itself;"
    log "run tp-multi-repo-workspace-setup, which writes the marker this hook looks for."
  fi
  dest="$top/.claude/worktrees/$NAME"
  mkdir -p "$top/.claude/worktrees"
  add_worktree "$top" "$dest" "$NAME" || die "git worktree add failed for $top"
  printf '%s\n' "$dest"
  exit 0
fi

# ── multi-repo workspace ─────────────────────────────────────────────────────
# Only DIRECT children are scanned, matching get-workspace-projects.sh: git-svn keeps its bridge
# worktrees at <project>/.turbo-plugin/worktrees/remote-svn-*, which are grandchildren, so one
# level deep never mistakes a bridge for a project.
projects=()
while IFS= read -r child; do
  [[ -n "$child" ]] || continue
  projects+=("$child")
done < <(list_projects "$WORKSPACE")

if (( ${#projects[@]} == 0 )); then
  die "'$WORKSPACE' is neither a git repository nor a folder containing any — nothing to isolate"
fi

MIRROR="$WORKSPACE/.worktrees/$NAME"
mkdir -p "$MIRROR" || die "could not create $MIRROR"

created=0
for repo in "${projects[@]}"; do
  if add_worktree "$repo" "$MIRROR/$(basename "$repo")" "$NAME"; then
    created=$(( created + 1 ))
  fi
done

(( created > 0 )) || die "no project worktree could be created under $MIRROR"
log "isolated $created of ${#projects[@]} project(s) under $MIRROR"

# NOTE ON THE WORKSPACE ROOT'S OWN FILES (issue #86): they are deliberately NOT copied in here.
# Claude Code loads CLAUDE.md by walking UP from the session's working directory, and the mirror
# sits at <workspace>/.worktrees/<name>, so <workspace>/CLAUDE.md is an ancestor and loads by
# itself. Copying it in would put the SAME guidance in context twice, and any edit to the copy
# would leave two versions loaded at once -- contradictory instructions Claude picks between
# arbitrarily. Editing those files stays a job for a session that is not isolated.

# The mirror itself is an ordinary directory in a NON-repo parent, so git resolves no enclosing
# checkout for it and Claude Code's path validation is satisfied. Its children are the real
# worktrees, which is what keeps `git -C <project>` working from the session's cwd.
printf '%s\n' "$MIRROR"
