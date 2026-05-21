# gh-review-on-green
# Adds a reviewer to a GitHub PR once all CI checks pass.
#
# USAGE:
#   gh-review-on-green <REVIEWER> [REPO]
#   gh-review-on-green <PR_NUMBER> <REVIEWER> [REPO]   # explicit PR override
#
# EXAMPLES:
#   gh-review-on-green octocat                  # auto-detect PR and repo
#   gh-review-on-green octocat myorg/myrepo     # explicit repo
#   gh-review-on-green 42 octocat               # explicit PR number
#   gh-review-on-green octocat &                # fire and forget
#
# REQUIREMENTS:
#   - GitHub CLI (gh) installed and authenticated: https://cli.github.com
#
# Source this file or paste it into your .bashrc / .zshrc:
#   source /path/to/gh-review-on-green.sh

gh-review-on-green() {
  local POLL_INTERVAL=${POLL_INTERVAL:-30}   # seconds between polls
  local MAX_WAIT=${MAX_WAIT:-3600}           # give up after 1 hour (0 = wait forever)

  # ── Args ────────────────────────────────────────────────────────────────────
  if [[ $# -lt 1 ]]; then
    echo "Usage: gh-review-on-green <REVIEWER> [REPO]" >&2
    echo "       gh-review-on-green <PR_NUMBER> <REVIEWER> [REPO]" >&2
    return 1
  fi

  local PR REVIEWER REPO_ARG
  # If first arg is a number, treat it as an explicit PR; otherwise auto-detect
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    PR="$1"
    REVIEWER="${2:-}"
    REPO_ARG="${3:-}"
    if [[ -z "$REVIEWER" ]]; then
      echo "Usage: gh-review-on-green <PR_NUMBER> <REVIEWER> [REPO]" >&2
      return 1
    fi
  else
    PR=""
    REVIEWER="$1"
    REPO_ARG="${2:-}"
  fi

  # ── Repo detection ──────────────────────────────────────────────────────────
  # Prefer the upstream remote (for forks); fall back to gh auto-detection
  local REPO REPO_FLAG
  local detected_repo=""
  local upstream_url
  upstream_url=$(git remote get-url upstream 2>/dev/null || true)
  if [[ -n "$upstream_url" ]]; then
    detected_repo=$(echo "$upstream_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
  fi
  if [[ -z "$detected_repo" ]]; then
    detected_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  fi

  if [[ -n "$REPO_ARG" ]]; then
    REPO="$REPO_ARG"
  elif [[ -n "$detected_repo" ]]; then
    REPO="$detected_repo"
  else
    echo "Error: couldn't detect GitHub repo. Pass it explicitly: gh-review-on-green $REVIEWER owner/repo" >&2
    return 1
  fi
  REPO_FLAG="--repo $REPO"

  # ── PR detection ────────────────────────────────────────────────────────────
  if [[ -z "$PR" ]]; then
    # Don't pass --repo here: fork PRs have head "forkowner:branch" and gh's
    # auto-detection handles that correctly, but --repo restricts to exact branch match.
    PR=$(gh pr view --json number -q .number 2>/dev/null || true)
    if [[ -z "$PR" ]]; then
      echo "Error: no open PR found for the current branch in $REPO." >&2
      return 1
    fi
  fi

  # ── Helpers ─────────────────────────────────────────────────────────────────
  _grog_log() { echo "[$(date '+%H:%M:%S')] $*"; }

  _grog_checks_status() {
    local json
    json=$(gh pr checks "$PR" $REPO_FLAG --json name,bucket 2>/dev/null)

    if [[ -n "${GROG_DEBUG:-}" ]]; then
      echo "[DEBUG] json=$json" >&2
    fi

    if [[ -z "$json" || "$json" == "[]" ]]; then echo "pending"; return; fi

    if echo "$json" | grep -qF '"bucket":"fail"'; then echo "fail"; return; fi
    if echo "$json" | grep -qF '"bucket":"pending"'; then echo "pending"; return; fi

    echo "pass"
  }

  # ── Main loop ───────────────────────────────────────────────────────────────
  _grog_log "Watching $REPO #$PR for CI to pass, then will add reviewer: @$REVIEWER"
  _grog_log "Polling every ${POLL_INTERVAL}s (timeout: ${MAX_WAIT}s). Ctrl-C to cancel."

  local elapsed=0 status

  while true; do
    status=$(_grog_checks_status)

    case "$status" in
      pass)
        _grog_log "✅ All checks passed!"
        _grog_log "Adding @$REVIEWER as reviewer on PR #$PR..."
        gh pr edit "$PR" $REPO_FLAG --add-reviewer "$REVIEWER"
        _grog_log "🎉 Done! @$REVIEWER has been added as a reviewer."
        unset -f _grog_log _grog_checks_status
        return 0
        ;;
      fail)
        _grog_log "❌ One or more checks failed. Not adding reviewer."
        _grog_log "Run 'gh pr checks $PR --repo $REPO' to see details."
        unset -f _grog_log _grog_checks_status
        return 1
        ;;
      pending)
        _grog_log "⏳ Checks still running... (${elapsed}s elapsed)"
        ;;
    esac

    if [[ "$MAX_WAIT" -gt 0 && "$elapsed" -ge "$MAX_WAIT" ]]; then
      _grog_log "⏰ Timed out after ${MAX_WAIT}s. Giving up."
      unset -f _grog_log _grog_checks_status
      return 2
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
}
