wt() {
  local task="$1"

  if [ -z "$task" ]; then
    echo "usage: wt <task-name>"
    return 1
  fi

  # MUST be run inside a git repo
  local REPO_ROOT
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

  if [ -z "$REPO_ROOT" ]; then
    echo "error: not inside a git repository"
    return 1
  fi

  local REPO_NAME
  REPO_NAME=$(basename "$REPO_ROOT")

  local REPO_PARENT
  REPO_PARENT=$(dirname "$REPO_ROOT")

  local WT_ROOT="$REPO_PARENT/.worktrees/${REPO_NAME}"
  local WT_PATH="$WT_ROOT/$task"
  local BRANCH="ai/$task"


  if [ -d "$WT_PATH" ]; then
    echo "error: worktree already exists: $WT_PATH"
    return 1
  fi

  mkdir -p "$WT_ROOT"

  echo "== repo detected =="
  echo "root:   $REPO_ROOT"
  echo "name:   $REPO_NAME"
  echo ""

  echo "== syncing upstream/main =="
  git -C "$REPO_ROOT" fetch upstream

  echo "== resetting main to upstream/main =="
  git -C "$REPO_ROOT" checkout main
  git -C "$REPO_ROOT" reset --hard upstream/main

  echo "== creating worktree =="
  git -C "$REPO_ROOT" worktree add "$WT_PATH" -b "$BRANCH"

  echo ""
  echo "READY:"
  echo "  path:   $WT_PATH"
  echo "  branch: $BRANCH"
  echo ""

  codium -n "$WT_PATH"
  cd "$WT_PATH"
}
