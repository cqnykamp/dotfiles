# gh-auto-reviewer
# Adds a reviewer to a GitHub PR once all CI checks pass.
#
# USAGE:
#   gh-auto-reviewer <REVIEWER> [REPO]
#   gh-auto-reviewer <PR_NUMBER> <REVIEWER> [REPO]   # explicit PR override
#
# EXAMPLES:
#   gh-auto-reviewer octocat                  # auto-detect PR and repo
#   gh-auto-reviewer octocat myorg/myrepo     # explicit repo
#   gh-auto-reviewer 42 octocat               # explicit PR number
#   gh-auto-reviewer octocat &                # fire and forget
#
# REQUIREMENTS:
#   - GitHub CLI (gh) installed and authenticated: https://cli.github.com
#
# Source this file or paste it into your .bashrc / .zshrc:
#   source /path/to/gh-auto-reviewer.bash

gh-auto-reviewer() {
  local POLL_INTERVAL=${POLL_INTERVAL:-30}   # seconds between polls
  local MAX_WAIT=${MAX_WAIT:-3600}           # give up after 1 hour (0 = wait forever)

  # ── Args ────────────────────────────────────────────────────────────────────
  if [[ $# -lt 1 ]]; then
    echo "Usage: gh-auto-reviewer <REVIEWER> [REPO]" >&2
    echo "       gh-auto-reviewer <PR_NUMBER> <REVIEWER> [REPO]" >&2
    return 1
  fi

  local PR REVIEWER REPO_ARG
  # If first arg is a number, treat it as an explicit PR; otherwise auto-detect
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    PR="$1"
    REVIEWER="${2:-}"
    REPO_ARG="${3:-}"
    if [[ -z "$REVIEWER" ]]; then
      echo "Usage: gh-auto-reviewer <PR_NUMBER> <REVIEWER> [REPO]" >&2
      return 1
    fi
  else
    PR=""
    REVIEWER="$1"
    REPO_ARG="${2:-}"
  fi

  # ── Repo detection ──────────────────────────────────────────────────────────
  local REPO REPO_FLAG
  local detected_repo
  detected_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  if [[ -n "$REPO_ARG" ]]; then
    REPO="$REPO_ARG"
  elif [[ -n "$detected_repo" ]]; then
    REPO="$detected_repo"
  else
    echo "Error: couldn't detect GitHub repo. Pass it explicitly: gh-auto-reviewer $REVIEWER owner/repo" >&2
    return 1
  fi
  REPO_FLAG="--repo $REPO"

  # ── PR detection ────────────────────────────────────────────────────────────
  if [[ -z "$PR" ]]; then
    PR=$(gh pr view $REPO_FLAG --json number -q .number 2>/dev/null || true)
    if [[ -z "$PR" ]]; then
      echo "Error: no open PR found for the current branch in $REPO." >&2
      return 1
    fi
  fi

  # ── Helpers ─────────────────────────────────────────────────────────────────
  _gar_log() { echo "[$(date '+%H:%M:%S')] $*"; }

  _gar_checks_status() {
    local json
    json=$(gh pr checks "$PR" $REPO_FLAG --json name,state,conclusion 2>/dev/null) || {
      echo "pending"; return
    }

    local total pending failed
    total=$(echo "$json" | grep -c '"name"' || echo 0)

    if [[ "$total" -eq 0 ]]; then echo "pending"; return; fi

    failed=$(echo "$json" | grep -c '"conclusion":"FAILURE"\|"conclusion":"TIMED_OUT"\|"conclusion":"CANCELLED"' || echo 0)
    if [[ "$failed" -gt 0 ]]; then echo "fail"; return; fi

    pending=$(echo "$json" | grep -c '"state":"PENDING"\|"state":"IN_PROGRESS"\|"conclusion":""' || echo 0)
    if [[ "$pending" -gt 0 ]]; then echo "pending"; return; fi

    echo "pass"
  }

  # ── Main loop ───────────────────────────────────────────────────────────────
  _gar_log "Watching $REPO #$PR for CI to pass, then will add reviewer: @$REVIEWER"
  _gar_log "Polling every ${POLL_INTERVAL}s (timeout: ${MAX_WAIT}s). Ctrl-C to cancel."

  local elapsed=0 status

  while true; do
    status=$(_gar_checks_status)

    case "$status" in
      pass)
        _gar_log "✅ All checks passed!"
        _gar_log "Adding @$REVIEWER as reviewer on PR #$PR..."
        gh pr edit "$PR" $REPO_FLAG --add-reviewer "$REVIEWER"
        _gar_log "🎉 Done! @$REVIEWER has been added as a reviewer."
        return 0
        ;;
      fail)
        _gar_log "❌ One or more checks failed. Not adding reviewer."
        _gar_log "Run 'gh pr checks $PR --repo $REPO' to see details."
        return 1
        ;;
      pending)
        _gar_log "⏳ Checks still running... (${elapsed}s elapsed)"
        ;;
    esac

    if [[ "$MAX_WAIT" -gt 0 && "$elapsed" -ge "$MAX_WAIT" ]]; then
      _gar_log "⏰ Timed out after ${MAX_WAIT}s. Giving up."
      return 2
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
}