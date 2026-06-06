#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WT=${WT:-$ROOT_DIR/wt}
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/wt-latest-option-suite.XXXXXX")
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

canonical_path() {
  (cd "$1" && pwd -P)
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
  GIT_AUTHOR_DATE='2000-01-01T00:00:00 +0000' \
    GIT_COMMITTER_DATE='2000-01-01T00:00:00 +0000' \
    git -C "$repo" commit -m base >/dev/null 2>&1
  printf '%s\n' "$repo"
}

make_empty_repo() {
  local repo
  repo=$(mktemp -d "$SUITE_TMP/empty-repo.XXXXXX")
  if ! git init -b main "$repo" >/dev/null 2>&1; then
    git init "$repo" >/dev/null 2>&1
    git -C "$repo" checkout -b main >/dev/null 2>&1
  fi
  git -C "$repo" config user.email wt@example.invalid
  git -C "$repo" config user.name 'wt tests'
  mkdir -p "$repo/.worktrees"
  printf '%s\n' "$repo"
}

commit_file() {
  local path="$1" branch="$2" date="$3" message="$4" safe_branch
  safe_branch=${branch//\//_}
  printf '%s\n' "$message" > "$path/$safe_branch.txt"
  git -C "$path" add "$safe_branch.txt"
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    git -C "$path" commit -m "$message" >/dev/null 2>&1
}

create_branch_worktree_with_commit() {
  local repo="$1" branch="$2" date="$3" worktree_path
  worktree_path="$repo/.worktrees/$branch"
  mkdir -p "$(dirname "$worktree_path")"
  git -C "$repo" branch "$branch" main >/dev/null 2>&1
  git -C "$repo" worktree add "$worktree_path" "$branch" >/dev/null 2>&1
  commit_file "$worktree_path" "$branch" "$date" "$branch commit"
  printf '%s\n' "$worktree_path"
}

create_branch_worktree_at_with_commit() {
  local repo="$1" branch="$2" worktree_path="$3" date="$4"
  mkdir -p "$(dirname "$worktree_path")"
  git -C "$repo" branch "$branch" main >/dev/null 2>&1
  git -C "$repo" worktree add "$worktree_path" "$branch" >/dev/null 2>&1
  commit_file "$worktree_path" "$branch" "$date" "$branch commit"
  printf '%s\n' "$worktree_path"
}

create_branch_only_with_commit() {
  local repo="$1" branch="$2" date="$3" worktree_path
  worktree_path="$repo/.worktrees/$branch.tmp"
  mkdir -p "$(dirname "$worktree_path")"
  git -C "$repo" branch "$branch" main >/dev/null 2>&1
  git -C "$repo" worktree add "$worktree_path" "$branch" >/dev/null 2>&1
  commit_file "$worktree_path" "$branch" "$date" "$branch commit"
  git -C "$repo" worktree remove "$worktree_path" >/dev/null 2>&1
}

update_root_with_commit() {
  local repo="$1" date="$2"
  printf 'root latest\n' >> "$repo/file.txt"
  git -C "$repo" add file.txt
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    git -C "$repo" commit -m 'root latest' >/dev/null 2>&1
}

run_wt() {
  local cwd="$1"
  shift
  (cd "$cwd" && "$WT" "$@")
}

run_wt_combined() {
  local cwd="$1"
  shift
  (cd "$cwd" && "$WT" "$@" 2>&1)
}

run_wt_with_wt_cwd_combined() {
  local wt_cwd="$1"
  shift
  (cd / && WT_CWD="$wt_cwd" "$WT" "$@" 2>&1)
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

test_latest_long_resolves_newest_existing_worktree_independent_of_branch_sort() {
  local repo latest_path output status expected
  repo=$(make_repo)
  latest_path=$(create_branch_worktree_with_commit "$repo" alpha '2020-01-03T00:00:00 +0000')
  create_branch_worktree_with_commit "$repo" zeta '2020-01-02T00:00:00 +0000' >/dev/null
  git -C "$repo" config branch.sort -refname

  set +e
  output=$(run_wt "$repo" --latest)
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "wt --latest should succeed; status $status output: $output"
  expected=$(canonical_path "$latest_path")
  assert_eq "$output" "$expected" 'wt --latest resolves newest worktree by committer date'
}

test_latest_short_creates_worktree_for_newest_branch_only_ref() {
  local repo output status expected
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" older '2020-01-02T00:00:00 +0000' >/dev/null
  create_branch_only_with_commit "$repo" newest '2020-01-04T00:00:00 +0000'
  expected="$repo/.worktrees/newest"

  set +e
  output=$(run_wt "$repo" -l)
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "wt -l should succeed; status $status output: $output"
  assert_exists "$expected"
  assert_eq "$output" "$(canonical_path "$expected")" 'wt -l creates and resolves newest branch-only worktree'
}

test_latest_root_branch_resolves_repo_root() {
  local repo linked_path output status expected
  repo=$(make_repo)
  linked_path=$(create_branch_worktree_with_commit "$repo" topic '2020-01-02T00:00:00 +0000')
  update_root_with_commit "$repo" '2020-01-05T00:00:00 +0000'

  set +e
  output=$(run_wt "$linked_path" --latest)
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "wt --latest from linked worktree should succeed; status $status output: $output"
  expected=$(canonical_path "$repo")
  assert_eq "$output" "$expected" 'wt --latest resolves root when root branch is newest'
}

test_latest_wt_cwd_repo_without_worktrees_resolves_root() {
  local repo output status expected
  repo=$(make_repo)
  rm -rf "$repo/.worktrees"

  set +e
  output=$(run_wt_with_wt_cwd_combined "$repo" -l)
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "WT_CWD wt -l without .worktrees should succeed; status $status output: $output"
  expected=$(canonical_path "$repo")
  assert_eq "$output" "$expected" 'WT_CWD wt -l resolves repo root without .worktrees'
}

test_latest_direct_repo_without_worktrees_still_resolves_root() {
  local repo output status expected
  repo=$(make_repo)
  rm -rf "$repo/.worktrees"

  set +e
  output=$(run_wt "$repo" --latest)
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "direct wt --latest without .worktrees should succeed; status $status output: $output"
  expected=$(canonical_path "$repo")
  assert_eq "$output" "$expected" 'direct wt --latest resolves repo root without .worktrees'
}

test_latest_wt_cwd_no_refs_without_worktrees_reports_no_local_branches() {
  local repo output status
  repo=$(make_empty_repo)
  rm -rf "$repo/.worktrees"

  set +e
  output=$(run_wt_with_wt_cwd_combined "$repo" --latest)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'WT_CWD wt --latest should fail without local branches'
  assert_contains "$output" 'No local branches found.'
}

test_latest_wt_cwd_linked_subdir_without_worktrees_resolves_latest_worktree() {
  local repo linked_path linked_subdir output status expected
  repo=$(make_repo)
  linked_path=$(create_branch_worktree_at_with_commit "$repo" topic "$SUITE_TMP/topic-linked" '2020-01-03T00:00:00 +0000')
  rm -rf "$repo/.worktrees"
  linked_subdir="$linked_path/subdir"
  mkdir -p "$linked_subdir"

  set +e
  output=$(run_wt_with_wt_cwd_combined "$linked_subdir" -l)
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "WT_CWD wt -l from linked subdir without .worktrees should succeed; status $status output: $output"
  expected=$(canonical_path "$linked_path")
  assert_eq "$output" "$expected" 'WT_CWD wt -l resolves latest linked worktree from subdir without .worktrees'
}

test_latest_branch_helper_returns_newest_branch_without_creating_worktree() {
  local repo output status
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" older '2020-01-02T00:00:00 +0000' >/dev/null
  create_branch_only_with_commit "$repo" newest '2020-01-04T00:00:00 +0000'
  git -C "$repo" config branch.sort -refname

  set +e
  output=$(run_wt "$repo" __latest_branch)
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "wt __latest_branch should succeed; status $status output: $output"
  assert_eq "$output" newest 'wt __latest_branch returns newest branch by committer date'
  [ ! -e "$repo/.worktrees/newest" ] || fail 'wt __latest_branch should not create a branch-only worktree'
}

test_latest_branch_helper_returns_root_branch_when_root_is_latest() {
  local repo linked_path output status
  repo=$(make_repo)
  linked_path=$(create_branch_worktree_with_commit "$repo" topic '2020-01-02T00:00:00 +0000')
  update_root_with_commit "$repo" '2020-01-05T00:00:00 +0000'

  set +e
  output=$(run_wt "$linked_path" __latest_branch)
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "wt __latest_branch from linked worktree should succeed; status $status output: $output"
  assert_eq "$output" main 'wt __latest_branch returns root branch when root is latest'
}

test_latest_branch_helper_errors_when_no_local_branches_exist() {
  local repo output status
  repo=$(make_empty_repo)

  set +e
  output=$(run_wt_combined "$repo" __latest_branch)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'wt __latest_branch should fail without local branches'
  assert_contains "$output" 'No local branches found.'
}

assert_usage_failure_no_cleanup() {
  local repo="$1" output status
  shift

  set +e
  output=$(run_wt_combined "$repo" "$@")
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "expected usage exit 2 for: $*; got $status; output: $output"
  assert_contains "$output" 'Usage:'
  assert_exists "$repo/.worktrees/cleanup_candidate"
}

test_latest_rejects_extra_args_and_clean_combinations_without_cleanup() {
  local repo
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" cleanup_candidate '2020-01-02T00:00:00 +0000' >/dev/null

  assert_usage_failure_no_cleanup "$repo" --latest foo
  assert_usage_failure_no_cleanup "$repo" -l foo
  assert_usage_failure_no_cleanup "$repo" -cl
  assert_usage_failure_no_cleanup "$repo" -c -l
  assert_usage_failure_no_cleanup "$repo" --clean --latest
}

test_latest_errors_when_no_local_branches_exist() {
  local repo output status
  repo=$(make_empty_repo)

  set +e
  output=$(run_wt_combined "$repo" --latest)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'wt --latest should fail without local branches'
  assert_contains "$output" 'No local branches found.'
}

test_zsh_completion_lists_latest_options_without_clean_combo() {
  local output option_line normalized_option_line
  output=$("$WT" --zsh-completion)
  option_line=$(printf '%s\n' "$output" | grep 'option_values=' || true)
  normalized_option_line=${option_line//(/ }
  normalized_option_line=${normalized_option_line//)/ }

  assert_contains "$output" '--latest  switch to the latest local branch by committer date'
  assert_contains "$output" '-l        switch to the latest local branch by committer date'
  assert_contains "$option_line" '--latest'
  assert_contains " $normalized_option_line " ' -l '
  assert_not_contains " $normalized_option_line " ' -cl '
}

assert_zsh_wrapper_switches_for_latest_form() {
  local form="$1" repo latest_path target output status expected bin_dir

  if ! command -v zsh >/dev/null 2>&1; then
    printf 'skip: zsh unavailable for %s\n' "$form"
    return 0
  fi

  repo=$(make_repo)
  latest_path=$(create_branch_worktree_with_commit "$repo" latest_worktree '2020-01-03T00:00:00 +0000')
  create_branch_worktree_with_commit "$repo" older_worktree '2020-01-02T00:00:00 +0000' >/dev/null
  target=$(canonical_path "$latest_path")
  bin_dir=$(mktemp -d "$SUITE_TMP/bin.XXXXXX")
  ln -s "$WT" "$bin_dir/wt"

  set +e
  output=$(
    PATH="$bin_dir:$PATH" WT_FUNCTIONS_DIR="$ROOT_DIR/zsh/functions" WT_START_CWD="$repo" WT_FORM="$form" \
      zsh -fc '
        fpath=("$WT_FUNCTIONS_DIR" $fpath)
        autoload -Uz wt
        cd "$WT_START_CWD" || exit 91
        wt "$WT_FORM" || exit $?
        print -r -- "cwd:$PWD"
      ' 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "zsh wt $form should succeed; status $status output: $output"
  expected="$target"$'\n'"cwd:$target"
  assert_eq "$output" "$expected" "zsh wt $form changes the caller directory"
}

test_zsh_wrapper_latest_changes_caller_directory() {
  assert_zsh_wrapper_switches_for_latest_form --latest
  assert_zsh_wrapper_switches_for_latest_form -l
}

run_test '--latest resolves newest existing worktree independent of branch.sort' test_latest_long_resolves_newest_existing_worktree_independent_of_branch_sort
run_test '-l creates a worktree for the newest branch-only ref' test_latest_short_creates_worktree_for_newest_branch_only_ref
run_test '--latest resolves root when root branch is newest' test_latest_root_branch_resolves_repo_root
run_test 'WT_CWD -l resolves repo root without .worktrees' test_latest_wt_cwd_repo_without_worktrees_resolves_root
run_test 'direct --latest still resolves repo root without .worktrees' test_latest_direct_repo_without_worktrees_still_resolves_root
run_test 'WT_CWD --latest without refs and .worktrees reports no local branches' test_latest_wt_cwd_no_refs_without_worktrees_reports_no_local_branches
run_test 'WT_CWD -l from linked subdir without .worktrees resolves latest worktree' test_latest_wt_cwd_linked_subdir_without_worktrees_resolves_latest_worktree
run_test '__latest_branch returns newest branch without creating worktree' test_latest_branch_helper_returns_newest_branch_without_creating_worktree
run_test '__latest_branch returns root branch when root is latest' test_latest_branch_helper_returns_root_branch_when_root_is_latest
run_test '__latest_branch errors when no local branches exist' test_latest_branch_helper_errors_when_no_local_branches_exist
run_test '--latest/-l reject extra args and clean combinations without cleanup' test_latest_rejects_extra_args_and_clean_combinations_without_cleanup
run_test '--latest errors when no local branches exist' test_latest_errors_when_no_local_branches_exist
run_test 'zsh completion lists latest options without clean combo' test_zsh_completion_lists_latest_options_without_clean_combo
run_test 'zsh wrapper --latest/-l changes the caller directory' test_zsh_wrapper_latest_changes_caller_directory

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all latest option tests passed\n'
