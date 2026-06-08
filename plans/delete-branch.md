# Plan: Add `--delete`/`-d <branch>` to `wt`

**Version**: 2  
**Objective**: `wt --delete <branch>` (or `wt -d <branch>`) removes a worktree and its branch, but only if the worktree is clean and the branch is fully merged (canonical `git branch -d` semantics).

## Design decisions

- **Flags**: `--delete`, `-d` only. No `-r`/`--remove` alias (avoids confusion with `git remote`).
- **Merged check**: delegate to `git branch -d` — it checks upstream/HEAD merge status and prints canonical error messages.
- **Cleanliness check**: delegate to `git worktree remove` — it refuses dirty worktrees and prints clear errors.
- **No cd**: this is a destructive operation (like `--clean`). The shell stays in the current directory.
- **No force flag**: not in scope (the user can use `git branch -D` manually for force delete).
- **Order of operations**: worktree removed first, then branch deleted. When the branch is unmerged, the worktree is gone but the branch remains — the user can `git worktree add` to recover. The reverse order (branch first, then worktree) would leave an orphaned worktree that's harder to recover from.
- **Reuse `branch_usage_error`**: no need for a new `delete_usage_error()` function — `branch_usage_error` prints usage to stderr and returns 2, identical to what we need.

## Files to change

### 1. `wt` (main executable)

#### a) `usage()` — add delete entry
Add line after the `--branch` entry:
```
       wt [--delete | -d] <branch>
```

#### b) New function: `delete_branch()`
```bash
delete_branch() {
  local branch="$1" root worktree_path

  if [ -z "$branch" ]; then
    echo "Usage: wt --delete <branch>" >&2
    return 2
  fi

  root=$(find_worktrees_root) || return $?
  root=$(cd "$root" && pwd -P)
  cd "$root"

  # Find existing worktree for the branch
  worktree_path=$(worktree_path_for_branch "$branch")
  if [ -z "$worktree_path" ]; then
    echo "No worktree found for branch '$branch'." >&2
    return 1
  fi

  # Refuse to delete root worktree
  local worktree_abs
  worktree_abs=$(cd "$worktree_path" && pwd -P 2>/dev/null || true)
  if [ "$worktree_abs" = "$root" ]; then
    echo "Cannot delete root worktree." >&2
    return 1
  fi

  # Remove worktree (git refuses if dirty)
  echo "Removing worktree for '$branch'..." >&2
  git worktree remove "$worktree_path" >&2 || return $?

  # Delete branch (git refuses if not fully merged)
  echo "Deleting branch '$branch'..." >&2
  git branch -d "$branch" >&2 || return $?

  echo "Deleted branch '$branch' and removed worktree." >&2
}
```

#### c) Main case statement — add before `--branch|-b)`:
```bash
  --delete|-d)
    shift
    if [ "$#" -ne 1 ]; then
      branch_usage_error
      exit $?
    fi
    delete_branch "$1"
    ;;
```

#### d) `print_zsh_completion()` — add completion entries
Add to `option_values`:
```
--delete
-d
```
Add to `option_labels`:
```
"--delete  delete a branch and its worktree (clean and fully merged)"
"-d        delete a branch and its worktree (clean and fully merged)"
```

### 2. `zsh/functions/wt`

#### a) Regex update
Change `^-[bcfm]+$` → `^-[bcdfm]+$` so `-d` passes through to the main executable.

No new block needed — `--delete`/`-d` doesn't cd, so the pass-through block is correct.

### 3. `is_clean_option_token()` — no change needed
`-d` is handled explicitly before the `*` fallthrough. Combined flags like `-dc` are nonsensical and hitting `resolve_path` is an acceptable failure mode.

## Verification

| Test case | Expected |
|---|---|
| `wt -d clean-merged-branch` | Removes worktree, deletes branch |
| `wt --delete clean-merged-branch` | Same |
| `wt -d` (no arg) | Usage error |
| `wt -d dirty-branch` | `git worktree remove` errors (dirty worktree) |
| `wt -d unmerged-branch` | Worktree removed, `git branch -d` errors (not merged). Branch preserved (recoverable). |
| `wt -d non-existent-branch` | "No worktree found for branch" |
| `wt -d main` (root) | "Cannot delete root worktree" |
| `wt -d` from non-repo dir | "Could not find .worktrees directory" |
| `wt -d current-worktree` | `git worktree remove` refuses (checked-out worktree), branch preserved |
