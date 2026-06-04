#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WT=${WT:-$ROOT_DIR/wt}
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/wt-clean-merged-suite.XXXXXX")
failures=0

cleanup() {
  rm -rf "$SUITE_TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
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

test_existing_clean_force_unchanged() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic_a
  create_branch_worktree_with_commit "$repo" topic_b

  output=$(cd "$repo" && "$WT" -cf 2>&1)

  assert_not_exists "$repo/.worktrees/topic_a"
  assert_not_exists "$repo/.worktrees/topic_b"
  assert_contains "$output" 'Removed clean worktrees:'
}

test_cfm_removes_only_merged_clean_worktrees() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" merged_topic
  create_branch_worktree_with_commit "$repo" unmerged_topic
  merge_into_main "$repo" merged_topic

  output=$(cd "$repo" && "$WT" -cfm 2>&1)

  assert_not_exists "$repo/.worktrees/merged_topic"
  assert_exists "$repo/.worktrees/unmerged_topic"
  assert_contains "$output" 'Removed clean worktrees:'
  assert_contains "$output" 'Skipped clean unmerged worktrees:'
}

test_long_merged_treats_following_flag_as_no_rev() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" merged_topic
  create_branch_worktree_with_commit "$repo" unmerged_topic
  merge_into_main "$repo" merged_topic

  output=$(cd "$repo" && "$WT" -c --merged -f 2>&1)

  assert_not_exists "$repo/.worktrees/merged_topic"
  assert_exists "$repo/.worktrees/unmerged_topic"
}

test_merged_space_rev_removes_branch_merged_to_explicit_target() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic
  git -C "$repo" branch release topic >/dev/null 2>&1

  output=$(cd "$repo" && "$WT" -c -f --merged release 2>&1)

  assert_not_exists "$repo/.worktrees/topic"
  assert_contains "$output" 'Removed clean worktrees:'
}

test_merged_equals_rev_removes_branch_merged_to_explicit_target() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic
  git -C "$repo" branch release topic >/dev/null 2>&1

  output=$(cd "$repo" && "$WT" -cf --merged=release 2>&1)

  assert_not_exists "$repo/.worktrees/topic"
  assert_contains "$output" 'Removed clean worktrees:'
}

test_invalid_merged_rev_fails_before_prompt_or_removal() {
  local repo output status
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" merged_topic
  merge_into_main "$repo" merged_topic

  set +e
  output=$(cd "$repo" && printf 'y\n' | "$WT" -c --merged does-not-exist 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected invalid --merged target to fail'
  assert_exists "$repo/.worktrees/merged_topic"
  assert_not_contains "$output" 'Remove 1 clean'
  assert_contains "$output" 'Invalid --merged target'
}

test_dirty_merged_worktree_is_still_skipped() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" merged_topic
  merge_into_main "$repo" merged_topic
  printf 'dirty\n' > "$repo/.worktrees/merged_topic/untracked.txt"

  output=$(cd "$repo" && "$WT" -cfm 2>&1)

  assert_exists "$repo/.worktrees/merged_topic"
  assert_contains "$output" 'Skipped unclean worktrees:'
}

test_default_merged_target_is_root_head_not_secondary_head() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" candidate
  git -C "$repo" branch secondary candidate >/dev/null 2>&1
  git -C "$repo" worktree add "$repo/.worktrees/secondary" secondary >/dev/null 2>&1
  create_branch_worktree_with_commit "$repo" merged_topic
  merge_into_main "$repo" merged_topic

  output=$(cd "$repo/.worktrees/secondary" && "$WT" -cfm 2>&1)

  assert_not_exists "$repo/.worktrees/merged_topic"
  assert_exists "$repo/.worktrees/candidate"
  assert_exists "$repo/.worktrees/secondary"
  assert_contains "$output" 'Skipped clean unmerged worktrees:'
}

assert_usage_failure() {
  local repo output status
  repo=$(make_repo)

  set +e
  output=$(cd "$repo" && "$WT" "$@" 2>&1)
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "expected usage exit 2 for: $*; got $status; output: $output"
  assert_contains "$output" 'Usage:'
}

test_merged_options_require_clean_mode_and_bare_revs_are_rejected() {
  assert_usage_failure --merged
  assert_usage_failure -m
  assert_usage_failure -fm
  assert_usage_failure -c main
}

test_zsh_completion_lists_merged_options() {
  local output
  output=$("$WT" --zsh-completion)
  assert_contains "$output" '--merged'
  assert_contains "$output" '-cm'
  assert_contains "$output" '-cfm'
}

run_test 'existing -cf cleanup is unchanged' test_existing_clean_force_unchanged
run_test '-cfm removes only clean worktrees merged to default target' test_cfm_removes_only_merged_clean_worktrees
run_test '--merged followed by -f uses default target, not -f as a rev' test_long_merged_treats_following_flag_as_no_rev
run_test '--merged <rev> filters against explicit target' test_merged_space_rev_removes_branch_merged_to_explicit_target
run_test '--merged=<rev> filters against explicit target' test_merged_equals_rev_removes_branch_merged_to_explicit_target
run_test 'invalid --merged target fails before prompt/removal' test_invalid_merged_rev_fails_before_prompt_or_removal
run_test 'dirty merged worktree is still skipped' test_dirty_merged_worktree_is_still_skipped
run_test 'default merged target is root HEAD, not secondary cwd HEAD' test_default_merged_target_is_root_head_not_secondary_head
run_test '--merged/-m require clean mode and bare revs are rejected' test_merged_options_require_clean_mode_and_bare_revs_are_rejected
run_test 'zsh completion lists merged cleanup options' test_zsh_completion_lists_merged_options

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all clean merged tests passed\n'
