# Plan: Add `--move`/`-M <branch>` to `wt`

**Version**: 3  
**Objective**: `wt --move [<oldbranch>] <newbranch>` (or `wt -M`) renames a branch and moves its linked worktree. If the shell is currently inside the old worktree, cd to the equivalent location in the new worktree.

## Design decisions

- **Flag**: `--move`/`-M` only. `-m` is already taken by `--merged`. `-M` mirrors `git branch -M` (force rename), but this initial implementation is the safe variant (branch must exist, new name must not exist). Force variant could be added later.
- **Old branch default**: when only `<newbranch>` is given, old branch defaults to HEAD of the user's current working directory (via `WT_CWD` env var or `$PWD`). This means running `wt -M newname` from inside a linked worktree renames that worktree's branch, not the root branch.
- **Two-line stdout output**: old worktree path (line 1) and new worktree path (line 2). The zsh function uses this to decide whether to cd.
- **Conditional cd**: only cd if `$PWD` was inside the old worktree. The zsh function captures `$wt_cwd` before the move and compares it with the old path.
- **Subdirectory preservation**: if the shell was in a subdirectory of the old worktree (e.g., `.../worktrees/old/src/`), cd to the equivalent under the new path.
- **No worktree**: if the branch has no linked worktree (branch-only ref), only `git branch -m` is run. No paths are output, no cd happens.
- **Root worktree**: if the branch is the repo root branch, only `git branch -m` is run (the root path doesn't change). No cd happens.
- **Rollback on partial failure**: if `git branch -m` succeeds but `git worktree move` fails, the branch rename is rolled back (`git branch -m "$new_branch" "$old_branch"`). This prevents an inconsistent state where the branch is renamed but the worktree is stuck at the old path.
- **Reuse `branch_usage_error`** for arg-count errors (same pattern as `--branch`/`-b`).

## Files to change

### 1. `wt` (main executable)

#### a) `usage()` — add move entry
After the `--delete` line (~line 11):
```
       wt [--move | -M] [<oldbranch>] <newbranch>
```

#### b) New function: `move_branch()`
Insert before `delete_branch()` (~line 162). Takes two args: `$1` = old branch, `$2` = new branch.
```bash
move_branch() {
  local old_branch="$1" new_branch="$2" root old_path new_path

  root=$(find_worktrees_root) || {
    echo "Could not find .worktrees directory or Git repository root." >&2
    return 1
  }
  root=$(cd "$root" && pwd -P)
  cd "$root"

  # Validate old branch exists
  if ! git show-ref --verify --quiet "refs/heads/$old_branch"; then
    echo "Branch '$old_branch' does not exist." >&2
    return 1
  fi

  # Validate new branch does not exist
  if git show-ref --verify --quiet "refs/heads/$new_branch"; then
    echo "Branch '$new_branch' already exists." >&2
    return 1
  fi

  old_path=$(worktree_path_for_branch "$old_branch")

  # Rename the branch
  echo "Renaming branch '$old_branch' to '$new_branch'..." >&2
  git branch -m "$old_branch" "$new_branch" >&2 || return $?

  if [ -n "$old_path" ] && [ "$old_path" != "$root" ]; then
    # Move linked worktree to new path
    new_path="${old_path%/*}/$new_branch"
    echo "Moving worktree to '$new_path'..." >&2
    if ! git worktree move "$old_path" "$new_path" >&2; then
      # Rollback: rename the branch back
      echo "Worktree move failed, rolling back branch rename..." >&2
      git branch -m "$new_branch" "$old_branch" >&2 || true
      return 1
    fi
    printf '%s\n' "$old_path"
    printf '%s\n' "$new_path"
  fi
}
```

Note: explicitly returns 0 (no output) when there's no worktree move. The zsh function treats empty output as "don't cd."

#### c) Main case statement — add before `--delete|-d)` (~line 938)
```bash
  --move|-M)
    shift
    if [ "$#" -eq 0 ] || [ "$#" -gt 2 ]; then
      branch_usage_error
      exit $?
    fi
    if [ "$#" -eq 1 ]; then
      local old_branch
      old_branch=$(root_branch)
      [ -n "$old_branch" ] || { echo "Not on a branch." >&2; exit 1; }
      move_branch "$old_branch" "$1"
    else
      move_branch "$1" "$2"
    fi
    ;;
```

Hmm, `root_branch` is already a function (line ~79). But we're already `cd`'d to root at that point (inside the subshell in the zsh function, or directly from the binary). Let me use it.

Wait — at the case statement level, we haven't cd'd to root yet. `move_branch` does that internally. But `root_branch` uses `git branch --show-current` which works from the current directory. Since the zsh function does `builtin cd -q /` first and `WT_CWD="$wt_cwd"` is set, `root_branch` would run `git branch --show-current` from `/` — which would fail. Let me restructure.

Better approach: move the "old_branch defaults to HEAD" logic INSIDE `move_branch`:

```bash
move_branch() {
  local old_branch="${1:-}" new_branch="${2:-}" root old_path new_path

  if [ -z "$new_branch" ]; then
    echo "Usage: wt --move [<oldbranch>] <newbranch>" >&2
    return 2
  fi

  root=$(find_worktrees_root) || { ... }
  root=$(cd "$root" && pwd -P)
  cd "$root"

  # Default old branch to HEAD
  if [ -z "$old_branch" ]; then
    old_branch=$(git branch --show-current 2>/dev/null || true)
    if [ -z "$old_branch" ]; then
      echo "Not on a branch and no <oldbranch> given." >&2
      return 1
    fi
  fi
  ...
}
```

Then the case statement:
```bash
  --move|-M)
    shift
    if [ "$#" -eq 0 ] || [ "$#" -gt 2 ]; then
      branch_usage_error
      exit $?
    fi
    if [ "$#" -eq 1 ]; then
      move_branch "" "$1"
    else
      move_branch "$1" "$2"
    fi
    ;;
```

This is cleaner — all the logic is in `move_branch`, and the case statement just dispatches.

#### d) `print_zsh_completion()` — add completion entries
Add `--move` and `-M` to `option_values` (~line 816).
Add labels to `option_labels` (~line 818):
```
"--move    rename a branch and move its worktree"
"-M        rename a branch and move its worktree"
```

### 2. `zsh/functions/wt`

#### a) Add `--move`/`-M` block before the pass-through block (~line 41)
```zsh
if [[ "$target" == --move || "$target" == -M ]]; then
  local output old_path new_path rel
  output=$(
    builtin cd -q / || exit 1
    WT_CWD="$wt_cwd" command wt "$@"
  ) || return $?
  if [[ -z "$output" ]]; then
    return 0
  fi
  old_path="${output%%$'\n'*}"
  new_path="${output#*$'\n'}"
  if [[ -n "$new_path" && ("$wt_cwd" == "$old_path" || "$wt_cwd" == "$old_path"/*) ]]; then
    rel="${wt_cwd#$old_path}"
    cd "${new_path}${rel}" || return 1
    pwd
  fi
  return 0
fi
```

#### b) Regex update
Change `^-[bcdfm]+$` → `^-[bcdfmM]+$` so `-M` passes through to the main executable. **Note**: `M` is uppercase to distinguish from `-m` (already used by `--merged`).

Wait — but with the explicit `--move`/`-M` block added before the pass-through, the regex change is only needed for edge cases like `-M` combined with other flags (nonsensical, but safe). And actually, the pass-through block already handles `--*` (long flags). The regex is only needed for bare short flags. Since `-M` is caught by the explicit block, the regex change is a safety net.

Actually, hmm. What if someone runs `wt -Mm` or `wt -Mc`? Those are nonsensical but the regex should at least not break things. Adding `M` to the regex means `-Mm` would pass through to `command wt`, which would hit the `*` fallthrough → `is_clean_option_token` → `M` not in `[cfm]` → false → `resolve_path "-Mm"` → error. That's fine.

## Verification

| Test case | Expected |
|---|---|
| `wt -M newname` (from shell) | Renames HEAD branch, moves worktree, cds to new worktree |
| `wt --move old new` | Renames `old` → `new`, moves worktree, cds if in old worktree |
| `wt -M old new` from different worktree | Renames and moves, but does NOT cd (not in old worktree) |
| `wt -M` (no args) | Usage error |
| `wt -M a b c` (3+ args) | Usage error |
| `wt -M old new` — old doesn't exist | "Branch 'old' does not exist" |
| `wt -M old new` — new exists | "Branch 'new' already exists" |
| `wt -M old new` (branch-only, no worktree) | Renames branch only, no paths output, no cd |
| `wt -M newname` from subdir of worktree | Cds to equivalent subdir under new worktree |
| `wt -M` detached HEAD, no oldbranch | "Not on a branch and no <oldbranch> given" |
| `wt -M` from non-repo dir | "Could not find .worktrees directory" |
| zsh completion | Lists `--move` and `-M` |

Most of these need zsh wrapper tests (like `--latest` tests in `latest_option_test.sh`). The test file should use `WT_CWD` env var to simulate being inside worktrees and assert the cd behavior via the main binary output.
