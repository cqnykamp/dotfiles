wtmain() {
  local main
  main=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
  if [ -z "$main" ]; then
    echo "error: not inside a git repository"
    return 1
  fi
  cd "$main"
}

# Echo "owner/name" of the GitHub repo for the given main worktree.
# Prefers `upstream` (for forks) then falls back to `origin`.
_wt_resolve_repo() {
  local main="$1"
  local url remote
  for remote in upstream origin; do
    url=$(git -C "$main" remote get-url "$remote" 2>/dev/null)
    if echo "$url" | grep -q "github\.com"; then
      echo "$url" | sed -E 's|.*github\.com[:/]||; s|\.git$||'
      return 0
    fi
  done
  return 1
}

# Emit one tab-separated status record for a worktree:
#   path \t branch \t dirty \t pr \t review-state \t ci
_wt_status_line() {
  local path="$1" branch="$2" main="$3" owner="$4" name="$5"

  if [ -z "$branch" ]; then
    printf '%s\t(detached)\t·\t----\tdetached\t \n' "$path"
    return 0
  fi

  local dirty='·'
  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    dirty='●'
  elif [ -n "$(git -C "$main" log "$branch" --not --remotes --oneline 2>/dev/null)" ]; then
    dirty='●'
  fi

  local pr_field='----' state='no-PR' ci=' '
  if [ -n "$owner" ] && [ -n "$name" ]; then
    local json
    json=$(gh api graphql -f query="
      query {
        repository(owner: \"$owner\", name: \"$name\") {
          pullRequests(last: 1, headRefName: \"$branch\") {
            nodes {
              number state isDraft reviewDecision
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            }
          }
        }
      }" 2>/dev/null)

    local pr_state is_draft review_decision number ci_state
    pr_state=$(echo "$json" | jq -r '.data.repository.pullRequests.nodes[0].state // empty' 2>/dev/null)
    is_draft=$(echo "$json" | jq -r '.data.repository.pullRequests.nodes[0].isDraft // empty' 2>/dev/null)
    review_decision=$(echo "$json" | jq -r '.data.repository.pullRequests.nodes[0].reviewDecision // empty' 2>/dev/null)
    number=$(echo "$json" | jq -r '.data.repository.pullRequests.nodes[0].number // empty' 2>/dev/null)
    ci_state=$(echo "$json" | jq -r '.data.repository.pullRequests.nodes[0].commits.nodes[0].commit.statusCheckRollup.state // empty' 2>/dev/null)

    if [ -n "$number" ]; then
      pr_field="#$number"
    fi

    case "$pr_state" in
      OPEN)
        if [ "$is_draft" = "true" ]; then
          state='draft'
        else
          case "$review_decision" in
            CHANGES_REQUESTED) state='changes-requested' ;;
            APPROVED)          state='approved' ;;
            *)                 state='waiting-for-review' ;;
          esac
        fi
        ;;
      MERGED) state='merged' ;;
      CLOSED) state='closed' ;;
      '')     state='no-PR' ;;
    esac

    if [ "$pr_state" = "OPEN" ]; then
      case "$ci_state" in
        SUCCESS)          ci='✓' ;;
        FAILURE|ERROR)    ci='✗' ;;
        PENDING|EXPECTED) ci='⠿' ;;
      esac
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$branch" "$dirty" "$pr_field" "$state" "$ci"
}

# Print tab-separated status records for every worktree (main first).
# Fans out _wt_status_line calls in parallel so latency ≈ one round-trip.
_wt_collect_status() {
  local main="$1" owner="$2" name="$3"

  local tmpdir
  tmpdir=$(mktemp -d)

  local i=0
  while read -r line; do
    local path branch
    path=$(echo "$line" | awk '{print $1}')
    branch=$(echo "$line" | grep -o '\[.*\]' | tr -d '[]')
    _wt_status_line "$path" "$branch" "$main" "$owner" "$name" > "$tmpdir/$i" &
    i=$((i+1))
  done < <(git -C "$main" worktree list)

  wait

  local j
  for ((j=0; j<i; j++)); do
    cat "$tmpdir/$j"
  done

  rm -rf "$tmpdir"
}

wts() {
  local main
  main=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
  if [ -z "$main" ]; then
    echo "error: not inside a git repository"
    return 1
  fi

  local owner_name owner='' name=''
  owner_name=$(_wt_resolve_repo "$main")
  if [ -n "$owner_name" ]; then
    owner=$(echo "$owner_name" | cut -d/ -f1)
    name=$(echo "$owner_name" | cut -d/ -f2)
  fi

  local table
  table=$(_wt_collect_status "$main" "$owner" "$name" | column -t -s $'\t')

  if [ -z "$table" ]; then
    echo "no worktrees found"
    return 0
  fi

  local selected
  if command -v fzf &>/dev/null; then
    selected=$(echo "$table" | fzf --prompt="worktree> " --with-nth=2.. | awk '{print $1}')
  else
    echo "$table"
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

  local owner_name owner name
  owner_name=$(_wt_resolve_repo "$main")
  if [ -z "$owner_name" ]; then
    echo "error: no GitHub remote found"
    return 1
  fi
  owner=$(echo "$owner_name" | cut -d/ -f1)
  name=$(echo "$owner_name" | cut -d/ -f2)

  # Tab-separated records for every worktree except main.
  local records
  records=$(_wt_collect_status "$main" "$owner" "$name" | tail -n +2)

  if [ -z "$records" ]; then
    echo "no worktrees to evaluate"
    return 0
  fi

  echo "$records" | column -t -s $'\t'
  echo ""

  while IFS=$'\t' read -r path branch dirty pr state ci; do
    if [ "$branch" = "(detached)" ]; then
      echo "kept $path — detached HEAD"
      continue
    fi

    if [ "$state" != "merged" ] && [ "$state" != "closed" ]; then
      echo "kept $branch — $state"
      continue
    fi

    if [ "$dirty" = "●" ]; then
      echo "kept $branch — dirty or unpushed"
      continue
    fi

    cd "$main" || return 1
    echo "pruning $branch — $state"
    git worktree remove "$path" && git branch -D "$branch"
  done <<< "$records"
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
  claude
  # claude "PR type for this branch: $type"
}
