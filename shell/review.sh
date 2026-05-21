review() {
  local task="$1"

  if [ -z "$task" ]; then
    echo "usage: review <task-name>"
    return 1
  fi

  local REPO="$HOME/doenet/tools"

  echo "Fetching latest..."
  git -C "$REPO" fetch upstream

  echo "Comparing main vs ai/$task..."

  git -C "$REPO" difftool main..ai/$task
}