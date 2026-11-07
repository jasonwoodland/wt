#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WT=${WT:-$ROOT_DIR/wt}
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
repo="$TASK_TMP/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email wt@example.invalid
git -C "$repo" config user.name 'wt tests'
git -C "$repo" commit -q --allow-empty -m base
repo=$(cd "$repo" && pwd -P)
cd "$repo"
mkdir .worktrees
git worktree add -q -b feature/123-login .worktrees/custom-login
expected="$repo/.worktrees/custom-login"
for target in 123 login custom __path; do
  if [ "$target" = __path ]; then
    actual=$("$WT" __path 123)
  else
    actual=$("$WT" "$target")
  fi
  [ "$actual" = "$expected" ]
done
# Literal matching and case sensitivity, with no destination on failure.
for target in '1*3' LOGIN missing; do
  if "$WT" "$target" >"$TASK_TMP/out" 2>"$TASK_TMP/err"; then exit 1; fi
  [ ! -s "$TASK_TMP/out" ]
done
git worktree add -q -b feature/123-other .worktrees/other
if "$WT" 123 >"$TASK_TMP/out" 2>"$TASK_TMP/err"; then exit 1; fi
[ ! -s "$TASK_TMP/out" ]
[[ $(cat "$TASK_TMP/err") == *feature/123-login*feature/123-other* ]]
# Exact branches win even when several worktrees match the substring.
git branch 123
[ "$("$WT" 123 2>"$TASK_TMP/err")" = "$repo/.worktrees/123" ]
git worktree add -q --detach .worktrees/detached-456
[ "$("$WT" 456)" = "$repo/.worktrees/detached-456" ]
# Local branches without worktrees participate in literal substring matching.
git branch fix/380-dashboard-ui-improvements
[ "$("$WT" 380)" = "$repo/.worktrees/fix/380-dashboard-ui-improvements" ]
git branch feature/789-first
git branch feature/789-second
if "$WT" 789 >"$TASK_TMP/out" 2>"$TASK_TMP/err"; then exit 1; fi
[ ! -s "$TASK_TMP/out" ]
[[ $(cat "$TASK_TMP/err") == *feature/789-first*feature/789-second* ]]
[ ! -d .worktrees/feature/789-first ]
# Existing worktree matches take priority over branches without worktrees.
git worktree add -q .worktrees/first feature/789-first
[ "$("$WT" 789)" = "$repo/.worktrees/first" ]
[ ! -d .worktrees/feature/789-second ]
printf 'all substring tests passed\n'
