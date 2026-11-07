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
  git -C "$repo" config branch.autoSetupMerge false
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
  (cd "$repo" && "$WT" __path "$branch") >/dev/null 2>&1
  printf '%s\n' "$branch" > "$worktree_path/${branch##*/}.txt"
  git -C "$worktree_path" add "${branch##*/}.txt"
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

test_all_clean_force() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic_a
  create_branch_worktree_with_commit "$repo" topic_b

  output=$(cd "$repo" && "$WT" -cfa 2>&1)

  assert_not_exists "$repo/.worktrees/topic_a"
  assert_not_exists "$repo/.worktrees/topic_b"
  assert_contains "$output" 'Removed clean worktrees:'
}

test_default_cleanup_removes_only_merged_worktrees() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" merged_topic
  create_branch_worktree_with_commit "$repo" unmerged_topic
  merge_into_main "$repo" merged_topic

  output=$(cd "$repo" && "$WT" -cf 2>&1)

  assert_not_exists "$repo/.worktrees/merged_topic"
  assert_exists "$repo/.worktrees/unmerged_topic"
  assert_contains "$output" 'Removed clean worktrees:'
  assert_contains "$output" 'Skipped clean unmerged worktrees:'
}

test_dirty_merged_worktree_is_still_skipped() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" merged_topic
  merge_into_main "$repo" merged_topic
  printf 'dirty\n' > "$repo/.worktrees/merged_topic/untracked.txt"

  output=$(cd "$repo" && "$WT" -cf 2>&1)

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

  output=$(cd "$repo/.worktrees/secondary" && "$WT" -cf 2>&1)

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

test_cleanup_options_and_removed_merged_flag() {
  assert_usage_failure --all
  assert_usage_failure --force
  assert_usage_failure --interactive
  assert_usage_failure -i
  assert_usage_failure -a
  assert_usage_failure -af
  assert_usage_failure --merged
  assert_usage_failure -m
  assert_usage_failure -cfm
  assert_usage_failure -cf --merged=main
  assert_usage_failure -cf first second
  assert_usage_failure -cf -- ''
}

test_zsh_completion_lists_all_options() {
  local output
  output=$("$WT" --zsh-completion)
  assert_contains "$output" '--all'
  assert_contains "$output" '-ca'
  assert_contains "$output" '-cfa'
  assert_contains "$output" '--interactive'
  assert_contains "$output" '-ciaf'
  assert_not_contains "$output" '--merged'
  assert_not_contains "$output" '-cfm'
}

test_merged_cleanup_accepts_untouched_and_unrecorded_worktrees() {
  local repo output git_dir
  repo=$(make_repo)
  (cd "$repo" && "$WT" -b untouched) >/dev/null 2>&1
  create_branch_worktree_with_commit "$repo" completed
  merge_into_main "$repo" completed
  # Untouched points behind root; the manually created worktree has its own work.
  git -C "$repo" worktree add -b unrecorded "$repo/.worktrees/unrecorded" >/dev/null 2>&1
  git -C "$repo/.worktrees/unrecorded" commit --allow-empty -m 'manual work' >/dev/null 2>&1
  merge_into_main "$repo" unrecorded
  git_dir=$(git -C "$repo/.worktrees/completed" rev-parse --absolute-git-dir)
  printf 'obsolete invalid metadata\n' > "$git_dir/wt-start-commit"
  output=$(cd "$repo" && "$WT" -cf 2>&1)
  assert_not_exists "$repo/.worktrees/untouched"
  assert_not_exists "$repo/.worktrees/unrecorded"
  assert_not_exists "$repo/.worktrees/completed"
  assert_contains "$output" 'Removed clean worktrees:'
  git -C "$repo" show-ref --verify refs/heads/unrecorded >/dev/null
  assert_exists "$repo/.git"
}

test_merged_cleanup_accepts_moved_and_recreated_worktrees() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic
  (cd "$repo" && "$WT" -M topic renamed) >/dev/null 2>&1
  merge_into_main "$repo" renamed
  # Fast-forward root to the topic tip: equal HEADs still represent completed work.
  git -C "$repo" reset --hard renamed >/dev/null 2>&1
  (cd "$repo" && "$WT" -cf) >/dev/null 2>&1
  assert_not_exists "$repo/.worktrees/renamed"
  (cd "$repo" && "$WT" __path renamed) >/dev/null 2>&1
  output=$(cd "$repo" && "$WT" -cf 2>&1)
  assert_not_exists "$repo/.worktrees/renamed"
  assert_contains "$output" 'Removed clean worktrees:'
  git -C "$repo" show-ref --verify refs/heads/renamed >/dev/null
}

test_targeted_cleanup_resolves_exact_substring_and_path() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" feat/320-some-thing
  create_branch_worktree_with_commit "$repo" other
  output=$(cd "$repo" && "$WT" -cfa 320 2>&1)
  assert_not_exists "$repo/.worktrees/feat/320-some-thing"
  assert_exists "$repo/.worktrees/other"
  assert_contains "$output" 'Removed clean worktrees:'
  create_branch_worktree_with_commit "$repo" feat/other-more
  (cd "$repo" && "$WT" -cfa other) >/dev/null 2>&1
  assert_not_exists "$repo/.worktrees/other"
  assert_exists "$repo/.worktrees/feat/other-more"
  (cd "$repo" && "$WT" -cfa "$repo/.worktrees/feat/other-more") >/dev/null 2>&1
  assert_not_exists "$repo/.worktrees/feat/other-more"
}

test_targeted_cleanup_rejects_ambiguous_missing_branch_only_and_root() {
  local repo target
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" feat/320-one
  create_branch_worktree_with_commit "$repo" feat/320-two
  git -C "$repo" branch 320
  # Exact branch-only matches must not fall back to substring matches or create.
  for target in 320 feat/320 missing . main "$repo"; do
    if (cd "$repo" && "$WT" -cf "$target") >/dev/null 2>&1; then
      fail "expected cleanup to reject '$target'"
    fi
    assert_exists "$repo/.worktrees/feat/320-one"
    assert_exists "$repo/.worktrees/feat/320-two"
  done
  assert_not_exists "$repo/.worktrees/320"
}

test_targeted_cleanup_keeps_dirty_and_supports_confirmation() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" topic
  create_branch_worktree_with_commit "$repo" other
  printf 'dirty\n' > "$repo/.worktrees/topic/untracked"
  output=$(cd "$repo" && "$WT" -cfa topic 2>&1)
  assert_exists "$repo/.worktrees/topic"
  assert_contains "$output" 'Skipped unclean worktrees:'
  rm "$repo/.worktrees/topic/untracked"
  output=$(cd "$repo" && printf 'y\n' | "$WT" -ca topic 2>&1)
  assert_not_exists "$repo/.worktrees/topic"
  assert_exists "$repo/.worktrees/other"
  assert_contains "$output" 'Remove 1 clean non-main worktree(s)?'
}

test_targeted_merged_cleanup_argument_forms() {
  local repo form
  for form in combined separate long default; do
    repo=$(make_repo)
    create_branch_worktree_with_commit "$repo" feat/320-topic
    create_branch_worktree_with_commit "$repo" other
    merge_into_main "$repo" feat/320-topic
    case "$form" in
      combined) (cd "$repo" && "$WT" -cf 320) >/dev/null 2>&1 ;;
      separate) (cd "$repo" && "$WT" -c -f 320) >/dev/null 2>&1 ;;
      long) (cd "$repo" && "$WT" --clean --force 320) >/dev/null 2>&1 ;;
      default) (cd "$repo" && "$WT" -cf -- 320) >/dev/null 2>&1 ;;
    esac
    assert_not_exists "$repo/.worktrees/feat/320-topic"
    assert_exists "$repo/.worktrees/other"
  done
}

test_targeted_merged_cleanup_preserves_ineligible_worktrees() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" unmerged
  (cd "$repo" && "$WT" -b untouched) >/dev/null 2>&1
  output=$(cd "$repo/.worktrees/unmerged" && "$WT" -cf -- unmerged 2>&1)
  assert_exists "$repo/.worktrees/unmerged"
  assert_contains "$output" 'Skipped clean unmerged worktrees:'
  output=$(cd "$repo" && "$WT" -cf -- untouched 2>&1)
  assert_not_exists "$repo/.worktrees/untouched"
  assert_contains "$output" 'Removed clean worktrees:'
}

run_test 'targeted merged cleanup preserves ineligible worktrees' test_targeted_merged_cleanup_preserves_ineligible_worktrees
run_test 'cleanup options reject removed flags and invalid arguments' test_cleanup_options_and_removed_merged_flag
run_test 'zsh completion lists --all and omits --merged' test_zsh_completion_lists_all_options
run_test 'targeted cleanup resolves exact names, substrings, and paths' test_targeted_cleanup_resolves_exact_substring_and_path
run_test 'targeted cleanup rejects ambiguous, missing, branch-only, and root targets' test_targeted_cleanup_rejects_ambiguous_missing_branch_only_and_root
run_test 'targeted cleanup keeps dirty worktrees and supports confirmation' test_targeted_cleanup_keeps_dirty_and_supports_confirmation
run_test 'targeted cleanup supports short and long options' test_targeted_merged_cleanup_argument_forms
run_test 'merged cleanup accepts untouched, manual and legacy worktrees' test_merged_cleanup_accepts_untouched_and_unrecorded_worktrees
run_test 'merged cleanup accepts moved and recreated worktrees' test_merged_cleanup_accepts_moved_and_recreated_worktrees
run_test '--all removes all clean worktrees' test_all_clean_force
run_test '-cf removes only clean worktrees merged to default target' test_default_cleanup_removes_only_merged_worktrees
run_test 'dirty merged worktree is still skipped' test_dirty_merged_worktree_is_still_skipped
run_test 'default merged target is root HEAD, not secondary cwd HEAD' test_default_merged_target_is_root_head_not_secondary_head

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all clean merged tests passed\n'
