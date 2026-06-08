#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WT=${WT:-$ROOT_DIR/wt}
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/wt-delete-suite.XXXXXX")
failures=0

cleanup() {
  rm -rf "$SUITE_TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" != "$expected" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_exists() {
  [ -e "$1" ] || fail "expected path to exist: $1"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected path to be removed: $1"
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) fail "expected output to contain '$2'; got: $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected output not to contain '$2'; got: $1" ;;
    *) return 0 ;;
  esac
}

branch_exists() {
  local repo="$1" branch="$2"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"
}

branch_not_exists() {
  local repo="$1" branch="$2"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    fail "expected branch '$branch' to be deleted"
  fi
}

make_repo() {
  local repo
  repo=$(mktemp -d "$SUITE_TMP/repo.XXXXXX")
  if ! git init -b main "$repo" >/dev/null 2>&1; then
    git init "$repo" >/dev/null 2>&1
    git -C "$repo" checkout -b main >/dev/null 2>&1
  fi
  git -C "$repo" config user.email wt@example.invalid
  git -C "$repo" config user.name 'wt tests'
  mkdir -p "$repo/.worktrees"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -m base >/dev/null 2>&1
  printf '%s\n' "$repo"
}

create_branch_worktree_with_commit() {
  local repo="$1" branch="$2" worktree_path
  worktree_path="$repo/.worktrees/$branch"
  git -C "$repo" branch "$branch" main >/dev/null 2>&1
  git -C "$repo" worktree add "$worktree_path" "$branch" >/dev/null 2>&1
  printf '%s\n' "$branch" > "$worktree_path/$branch.txt"
  git -C "$worktree_path" add "$branch.txt"
  git -C "$worktree_path" commit -m "$branch commit" >/dev/null 2>&1
}

merge_into_main() {
  local repo="$1" branch="$2"
  git -C "$repo" merge --no-ff "$branch" -m "merge $branch" >/dev/null 2>&1
}

run_test() {
  local name="$1"
  shift
  printf 'test: %s ... ' "$name"
  if ( set -euo pipefail; "$@" ); then
    printf 'ok\n'
  else
    printf 'FAILED\n'
    failures=$((failures + 1))
  fi
}

# --- Tests ---

test_delete_removes_clean_merged_branch_worktree_and_branch() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic_a
  merge_into_main "$repo" topic_a

  output=$(cd "$repo" && "$WT" -d topic_a 2>&1)

  assert_not_exists "$repo/.worktrees/topic_a"
  branch_not_exists "$repo" topic_a
  assert_contains "$output" "Deleted branch 'topic_a' and removed worktree."
}

test_delete_long_form() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic_a
  merge_into_main "$repo" topic_a

  output=$(cd "$repo" && "$WT" --delete topic_a 2>&1)

  assert_not_exists "$repo/.worktrees/topic_a"
  branch_not_exists "$repo" topic_a
  assert_contains "$output" "Deleted branch 'topic_a' and removed worktree."
}

test_delete_dirty_worktree_fails_and_preserves_everything() {
  local repo output status
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic_a
  merge_into_main "$repo" topic_a
  printf 'dirty\n' > "$repo/.worktrees/topic_a/untracked.txt"

  set +e
  output=$(cd "$repo" && "$WT" -d topic_a 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected dirty worktree deletion to fail'
  assert_exists "$repo/.worktrees/topic_a"
  branch_exists "$repo" topic_a
}

test_delete_unmerged_branch_removes_worktree_preserves_branch() {
  local repo output status
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic_a
  # NOT merged — branch is ahead of main

  set +e
  output=$(cd "$repo" && "$WT" -d topic_a 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected unmerged branch deletion to fail'
  assert_not_exists "$repo/.worktrees/topic_a"
  branch_exists "$repo" topic_a
  assert_contains "$output" "not fully merged"
}

test_delete_no_arg_shows_usage() {
  local repo output status
  repo=$(make_repo)

  set +e
  output=$(cd "$repo" && "$WT" -d 2>&1)
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "expected usage exit 2 for -d with no arg; got $status; output: $output"
  assert_contains "$output" 'Usage:'
}

test_delete_nonexistent_branch_errors() {
  local repo output status
  repo=$(make_repo)

  set +e
  output=$(cd "$repo" && "$WT" -d no_such_branch 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected failure for non-existent branch'
  assert_contains "$output" "No worktree found for branch 'no_such_branch'"
}

test_delete_root_worktree_errors() {
  local repo output status
  repo=$(make_repo)

  set +e
  output=$(cd "$repo" && "$WT" -d main 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected failure for root worktree'
  assert_contains "$output" 'Cannot delete root worktree'
}

test_delete_from_non_repo_dir_errors() {
  local output status

  set +e
  output=$(cd / && "$WT" -d some_branch 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected failure from non-repo dir'
  assert_contains "$output" 'Could not find .worktrees directory'
}

test_zsh_completion_lists_delete_options() {
  local output
  output=$("$WT" --zsh-completion)
  assert_contains "$output" '--delete'
  assert_contains "$output" '-d'
}

# --- Runner ---

run_test '-d removes clean merged branch worktree and branch' test_delete_removes_clean_merged_branch_worktree_and_branch
run_test '--delete long form works' test_delete_long_form
run_test '-d with dirty worktree fails, preserves worktree and branch' test_delete_dirty_worktree_fails_and_preserves_everything
run_test '-d with unmerged branch removes worktree, preserves branch' test_delete_unmerged_branch_removes_worktree_preserves_branch
run_test '-d with no arg shows usage' test_delete_no_arg_shows_usage
run_test '-d with non-existent branch errors' test_delete_nonexistent_branch_errors
run_test '-d with root worktree errors' test_delete_root_worktree_errors
run_test '-d from non-repo dir errors' test_delete_from_non_repo_dir_errors
run_test 'zsh completion lists --delete and -d options' test_zsh_completion_lists_delete_options

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all delete tests passed\n'
