wtmain() {
  local main
  main=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
  if [ -z "$main" ]; then
    echo "error: not inside a git repository"
    return 1
  fi
  cd "$main"
}

wts() {
  local list
  list=$(git worktree list 2>/dev/null)
  if [ -z "$list" ]; then
    echo "error: not inside a git repository"
    return 1
  fi

  local selected
  if command -v fzf &>/dev/null; then
    selected=$(echo "$list" | fzf --prompt="worktree> " | awk '{print $1}')
  else
    echo "$list"
    return 0
  fi

  if [ -n "$selected" ]; then
    cd "$selected"
    claude --continue
  fi
}

wtprune() {
  if ! command -v gh &>/dev/null; then
    echo "error: gh CLI required"
    return 1
  fi

  local main
  main=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
  if [ -z "$main" ]; then
    echo "error: not inside a git repository"
    return 1
  fi

  git worktree list | tail -n +2 | while read -r line; do
    local path branch state
    path=$(echo "$line" | awk '{print $1}')
    branch=$(echo "$line" | grep -o '\[.*\]' | tr -d '[]')

    if [ -z "$branch" ]; then
      echo "skipping $path — no branch (detached HEAD?)"
      continue
    fi

    state=$(gh pr view "$branch" --json state --jq '.state' 2>/dev/null)
    if [ "$state" != "MERGED" ]; then
      echo "skipping $branch — ${state:-no PR found}"
      continue
    fi

    if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
      echo "skipping $branch — uncommitted changes"
      continue
    fi

    if [ -n "$(git -C "$main" log "$branch" --not --remotes --oneline 2>/dev/null)" ]; then
      echo "skipping $branch — unpushed commits"
      continue
    fi

    # All checks passed — move to main repo so we're not inside the worktree being removed
    cd "$main" || return 1

    echo "pruning $branch — PR merged"
    git worktree remove "$path" && git branch -D "$branch"
  done
}

wt() {
  local type="$1"
  local task="$2"

  local valid_types="feat feat! fix chore refactor docs test ci"
  if [ -z "$type" ] || [ -z "$task" ]; then
    echo "usage: wt <type> <task-name>"
    echo "types: $valid_types"
    return 1
  fi

  if ! echo "$valid_types" | grep -qw "$type"; then
    echo "error: unknown type '$type'"
    echo "types: $valid_types"
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
  local WT_PATH="$WT_ROOT/$type/$task"
  local BRANCH="$type/$task"


  if [ -d "$WT_PATH" ]; then
    echo "error: worktree already exists: $WT_PATH"
    return 1
  fi

  mkdir -p "$WT_ROOT/$type"

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

  # codium -n "$WT_PATH"
  cd "$WT_PATH"

  if [ -f "$WT_PATH/package.json" ]; then
    npm install
  fi
  claude "PR type for this branch: $type"
}
