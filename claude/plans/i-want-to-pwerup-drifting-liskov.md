# Power up `wts` and `wtprune` with rich worktree status

## Context

`wts` and `wtprune` in `shell/worktrees.sh` are minimal today:

- `wts` pipes raw `git worktree list` into fzf — no signal about what's going on in each worktree.
- `wtprune` evaluates state internally but only prints terse one-liners ("skipping foo — uncommitted changes").

The user runs many worktrees in parallel and wants to glance at all of them and answer: *which worktree needs my attention?* Specifically: which has uncommitted changes, which has an open PR, which is a draft, which is waiting for review, which has changes requested. CI status (passing/failing/pending) comes free with the same GraphQL call so it's included.

Tying each worktree to a Claude session is explicitly out of scope for this iteration.

## Approach

Factor a single status helper, then rewire both commands to use it. Only `shell/worktrees.sh` changes.

### Status line format (single line per worktree)

```
<branch>            <dirty>  <pr>     <review-state>       <ci>
feat/foo            ●        #123     changes-requested    ✗
fix/bar             ·        #124     waiting-for-review   ⠿
chore/baz           ·        #125     draft                ✓
refactor/quux       ●        ----     no-PR                
test/zap            ·        #119     merged               
```

Markers:

- **Dirty**: `●` if `git status --porcelain` is non-empty OR there are unpushed commits; `·` otherwise.
- **PR number**: `#N` or `----` when no PR exists.
- **Review state**: one of `draft`, `waiting-for-review`, `changes-requested`, `approved`, `merged`, `closed`, `no-PR`. Derived from `state` + `isDraft` + `reviewDecision`.
- **CI**: `✓` (SUCCESS), `✗` (FAILURE/ERROR), `⠿` (PENDING/EXPECTED), blank when no PR or no rollup.

### New helpers (in `shell/worktrees.sh`)

1. **`_wt_resolve_repo`** — extract the upstream/origin → `owner/name` detection currently inlined in `wtprune` (lines 47–62 of the existing file). Echoes `owner/name`, returns non-zero if no GitHub remote.

2. **`_wt_status_line <path> <branch> <owner> <name>`** — returns one formatted status line. Steps:
   - `dirty` if `git -C $path status --porcelain` non-empty OR `git -C $main log $branch --not --remotes --oneline` non-empty.
   - One GraphQL call:
     ```graphql
     repository(owner, name) {
       pullRequests(last: 1, headRefName: $branch) {
         nodes {
           number state isDraft reviewDecision
           commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
         }
       }
     }
     ```
   - Map fields to the review-state label (see matrix below) and CI glyph.
   - Emit a tab-separated record; columnization happens in the caller.

   Review-state matrix:
   | state    | isDraft | reviewDecision     | label              |
   |----------|---------|--------------------|--------------------|
   | (none)   | —       | —                  | no-PR              |
   | OPEN     | true    | —                  | draft              |
   | OPEN     | false   | REVIEW_REQUIRED    | waiting-for-review |
   | OPEN     | false   | CHANGES_REQUESTED  | changes-requested  |
   | OPEN     | false   | APPROVED           | approved           |
   | OPEN     | false   | null / COMMENTED   | waiting-for-review |
   | MERGED   | —       | —                  | merged             |
   | CLOSED   | —       | —                  | closed             |

3. **`_wt_collect_status`** — iterate worktrees, fan out `_wt_status_line` calls in parallel (background `&` with output redirected to a temp dir keyed by index to preserve order), `wait`, then concat. Keeps total latency ≈ one GraphQL round-trip even with 10+ worktrees.

### Rewrites

**`wts`** (replaces lines 11–31):

- Build the table via `_wt_collect_status`.
- Pipe through `column -t -s $'\t'` for alignment.
- fzf with `--with-nth=2..` (hide the first column = worktree path) and `--ansi` so the path is selectable but invisible. On selection, `awk '{print $1}'` to recover path → `cd` + `claude --continue` (unchanged behavior).
- No-fzf fallback: print the aligned table.

**`wtprune`** (replaces lines 33–104):

- Resolve repo via `_wt_resolve_repo`.
- For each worktree, print the full status line (so the user sees state for kept *and* pruned worktrees), then decide:
  - prune iff review-state ∈ {merged, closed} AND clean AND no unpushed commits
  - otherwise print the status line and append `→ kept (<reason>)`
  - prunable worktrees print `→ pruning`, then `git worktree remove` + `git branch -D` (executed from `$main` so we're not standing inside the removed dir).

### Critical files

- `/home/charles/dotfiles/shell/worktrees.sh` — only file modified. New helpers are private (`_wt_*` prefix) and live in the same file.

### Reused / referenced existing code

- Repo detection block in `wtprune` (lines 47–62) → factored into `_wt_resolve_repo`.
- GraphQL query shape in `wtprune` (lines 75–81) → expanded with `isDraft`, `reviewDecision`, `number`, `statusCheckRollup`.
- Dirty/unpushed checks (lines 88, 93) → reused verbatim inside `_wt_status_line`.
- `gh-review-on-green.sh` already uses `gh pr checks --json bucket`; we use the GraphQL `statusCheckRollup` equivalent so it stays in the single PR query.

## Verification

1. **Visual check** — in a repo with several worktrees, run `wts`. Confirm aligned columns and that all expected glyphs render in the terminal font. Verify fzf hides the path column but selection still `cd`s correctly and launches `claude --continue`.
2. **No-fzf path** — `PATH=/usr/bin wts` in a shell where fzf is shadowed (or temporarily `alias fzf=false`) — confirm the plain table prints.
3. **State coverage** — manually create test worktrees that exercise: no PR, draft PR, open PR with no reviewer, open PR with `CHANGES_REQUESTED`, open PR `APPROVED`, merged, closed. Confirm each renders the right label.
4. **`wtprune` behavior** — run against a repo where some worktrees are mergeable-and-clean and others not. Confirm only the mergeable+clean ones are removed and the others print informative kept-reasons. Re-run; it should be idempotent (nothing left to prune).
5. **Performance** — `time wts` with 5+ worktrees; the parallel fan-out should keep it under ~1.5s (vs. ~N×500ms serial).
6. **Detached HEAD edge case** — the existing skip-on-no-branch behavior (line 69) is preserved; confirm a detached worktree prints `no-branch` and is never pruned.
