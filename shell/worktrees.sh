wt() {
  local task="$1"

  if [ -z "$task" ]; then
    echo "usage: wt <task>"
    return 1
  fi

  local ROOT="$HOME/doenet"
  local REPO="tools"

  local MAIN_REPO="$ROOT/$REPO"
  local WT_ROOT="$ROOT/${REPO}-worktrees"
  local WT_PATH="$WT_ROOT/$task"

  mkdir -p "$WT_ROOT"

  echo ""
  echo "== Fetching upstream =="
  git -C "$MAIN_REPO" fetch upstream

  echo ""
  echo "== Resetting local main to upstream/main =="
  git -C "$MAIN_REPO" checkout main
  git -C "$MAIN_REPO" reset --hard upstream/main

  echo ""
  echo "== Creating worktree =="

  git -C "$MAIN_REPO" worktree add \
    "$WT_PATH" \
    -b "ai/$task"

  echo ""
  echo "=================================="
  echo "Worktree created successfully"
  echo "=================================="
  echo ""
  echo "Path:"~
  echo "  $WT_PATH"
  echo ""
  echo "Branch:"
  echo "  ai/$task"
  echo ""
  echo "Next steps:"
  echo ""
  echo "  cd $WT_PATH"
  echo "  claude"
  echo ""
}
