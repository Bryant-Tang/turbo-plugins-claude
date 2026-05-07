#!/usr/bin/env bash
# -e (errexit) intentionally omitted: the rollback loop further down must run
# after `mv` failures. With -e enabled, the script would exit immediately on
# the first failed mv, never reaching the rollback path. Each command that
# needs failure handling uses an explicit `if ! cmd ...; then ... fi` pattern.
set -uo pipefail

BRANCH_FROM=""
BRANCH_TO=""
MOVES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch-from)
            BRANCH_FROM="${2-}"
            shift 2
            ;;
        --branch-to)
            BRANCH_TO="${2-}"
            shift 2
            ;;
        --move)
            MOVES+=("${2-}")
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$BRANCH_FROM" ]]; then echo "Missing required argument: --branch-from <old-name>" >&2; exit 1; fi
if [[ -z "$BRANCH_TO" ]]; then echo "Missing required argument: --branch-to <new-name>" >&2; exit 1; fi
if [[ ${#MOVES[@]} -eq 0 ]]; then echo "Missing required argument: --move <from>=<to> (at least one)" >&2; exit 1; fi

if [[ ! "$BRANCH_FROM" =~ ^[A-Za-z0-9._/-]+$ ]]; then echo "Invalid --branch-from value '$BRANCH_FROM'." >&2; exit 1; fi
if [[ ! "$BRANCH_TO" =~ ^[A-Za-z0-9._/-]+$ ]]; then echo "Invalid --branch-to value '$BRANCH_TO'." >&2; exit 1; fi

FROMS=()
TOS=()
for entry in "${MOVES[@]}"; do
    if [[ "$entry" != *=* ]]; then
        echo "Invalid --move entry '$entry'. Expected format: <from>=<to>" >&2
        exit 1
    fi
    FROM_REL="${entry%%=*}"
    TO_REL="${entry#*=}"
    if [[ -z "$FROM_REL" || -z "$TO_REL" ]]; then
        echo "Invalid --move entry '$entry'. Both <from> and <to> are required." >&2
        exit 1
    fi
    FROMS+=("$FROM_REL")
    TOS+=("$TO_REL")
done

COMMON_GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo "Not inside a git repository." >&2
    exit 1
}
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"

if ! git -C "$MAIN_WORKTREE" rev-parse --verify -q "refs/heads/$BRANCH_FROM" >/dev/null 2>&1; then
    echo "Source branch '$BRANCH_FROM' does not exist." >&2; exit 1
fi
if git -C "$MAIN_WORKTREE" rev-parse --verify -q "refs/heads/$BRANCH_TO" >/dev/null 2>&1; then
    echo "Target branch '$BRANCH_TO' already exists." >&2; exit 1
fi
if ! git -C "$MAIN_WORKTREE" rev-parse --verify -q "refs/heads/main" >/dev/null 2>&1; then
    echo "main branch does not exist; cannot verify merged state." >&2; exit 1
fi

if ! git -C "$MAIN_WORKTREE" merge-base --is-ancestor "$BRANCH_FROM" main >/dev/null 2>&1; then
    echo "Source branch '$BRANCH_FROM' is not yet merged into 'main'. Merge it first (e.g. via /tgs:release) before archiving." >&2
    exit 1
fi

STATUS=$(git -C "$MAIN_WORKTREE" status --porcelain)
if [[ -n "$STATUS" ]]; then
    echo "Main worktree has uncommitted changes. Commit or stash before archiving." >&2
    echo "$STATUS" >&2
    exit 1
fi

CUR=$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)
if [[ "$CUR" == "$BRANCH_FROM" ]]; then
    echo "Main worktree is currently on '$BRANCH_FROM'. Switch off before archiving." >&2
    exit 1
fi

WT_OUTPUT=$(git -C "$MAIN_WORKTREE" worktree list --porcelain)
if echo "$WT_OUTPUT" | grep -Fxq "branch refs/heads/$BRANCH_FROM"; then
    echo "Branch '$BRANCH_FROM' is checked out in another worktree. Switch that worktree off the branch before archiving." >&2
    exit 1
fi

for i in "${!FROMS[@]}"; do
    SRC="$MAIN_WORKTREE/${FROMS[$i]}"
    DST="$MAIN_WORKTREE/${TOS[$i]}"
    if [[ ! -e "$SRC" ]]; then echo "Source path does not exist: ${FROMS[$i]}" >&2; exit 1; fi
    if [[ -e "$DST" ]]; then echo "Destination path already exists: ${TOS[$i]}" >&2; exit 1; fi
done

if ! git -C "$MAIN_WORKTREE" branch -m "$BRANCH_FROM" "$BRANCH_TO"; then
    echo "git branch -m '$BRANCH_FROM' '$BRANCH_TO' failed" >&2
    exit 1
fi
echo "Renamed branch '$BRANCH_FROM' -> '$BRANCH_TO'."

MOVED_SRC=()
MOVED_DST=()
MOVED_FROM_REL=()
MOVED_TO_REL=()
CREATED_PARENTS=()
MOVE_ERROR=""

for i in "${!FROMS[@]}"; do
    SRC="$MAIN_WORKTREE/${FROMS[$i]}"
    DST="$MAIN_WORKTREE/${TOS[$i]}"
    PARENT=$(dirname "$DST")

    # Track whether PARENT existed before mkdir -p so rollback can clean
    # up the empty shell we leave behind if a subsequent mv fails.
    PARENT_PRE_EXISTED=true
    [[ -d "$PARENT" ]] || PARENT_PRE_EXISTED=false

    if ! mkdir -p "$PARENT" 2>/dev/null; then
        MOVE_ERROR="Failed to create parent directory for '${TOS[$i]}'"
        break
    fi
    [[ "$PARENT_PRE_EXISTED" == "false" ]] && CREATED_PARENTS+=("$PARENT")

    if ! mv "$SRC" "$DST" 2>/dev/null; then
        MOVE_ERROR="Failed to move '${FROMS[$i]}' -> '${TOS[$i]}'"
        break
    fi
    MOVED_SRC+=("$SRC")
    MOVED_DST+=("$DST")
    MOVED_FROM_REL+=("${FROMS[$i]}")
    MOVED_TO_REL+=("${TOS[$i]}")
    echo "Moved '${FROMS[$i]}' -> '${TOS[$i]}'."
done

if [[ -n "$MOVE_ERROR" ]]; then
    echo ""
    echo "Rolling back due to move failure..."
    ROLLBACK_ERRORS=()
    for ((i=${#MOVED_SRC[@]}-1; i>=0; i--)); do
        if ! mv "${MOVED_DST[$i]}" "${MOVED_SRC[$i]}" 2>/dev/null; then
            ROLLBACK_ERRORS+=("Could not restore '${MOVED_TO_REL[$i]}' -> '${MOVED_FROM_REL[$i]}'")
        fi
    done
    if ! git -C "$MAIN_WORKTREE" branch -m "$BRANCH_TO" "$BRANCH_FROM" 2>/dev/null; then
        ROLLBACK_ERRORS+=("Could not revert branch rename '$BRANCH_TO' -> '$BRANCH_FROM'")
    fi
    # Clean up parent directories we created. rmdir -p walks up the chain,
    # silently stopping at the first non-empty / pre-existing directory.
    # Reverse order so deeper paths are removed first.
    for ((i=${#CREATED_PARENTS[@]}-1; i>=0; i--)); do
        rmdir -p "${CREATED_PARENTS[$i]}" 2>/dev/null || true
    done
    if [[ ${#ROLLBACK_ERRORS[@]} -gt 0 ]]; then
        {
            echo "Archive failed mid-way and rollback was incomplete."
            echo "Original error: $MOVE_ERROR"
            echo "Rollback errors:"
            for e in "${ROLLBACK_ERRORS[@]}"; do echo "  - $e"; done
        } >&2
        exit 1
    else
        echo "Archive failed mid-way; rollback succeeded. Original error: $MOVE_ERROR" >&2
        exit 1
    fi
fi

echo "Archive complete: '$BRANCH_FROM' -> '$BRANCH_TO' with ${#MOVES[@]} folder move(s)."
