#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WT=${WT:-$ROOT_DIR/wt}
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/wt-move-suite.XXXXXX")
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
    fail "expected branch '$branch' to not exist"
  fi
}

canonical_path() {
  (cd "$1" && pwd -P)
}

make_repo() {
  local repo double_slash='//'
  repo=$(mktemp -d "$SUITE_TMP/repo.XXXXXX")
  # Normalize double slashes from TMPDIR trailing slash
  repo="${repo//$double_slash//}"
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

create_branch_only() {
  local repo="$1" branch="$2"
  git -C "$repo" branch "$branch" main >/dev/null 2>&1
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

test_move_renames_branch_moves_worktree() {
  local repo output old_expected new_expected
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" oldname
  old_expected="$repo/.worktrees/oldname"
  new_expected="$repo/.worktrees/newname"

  output=$(cd "$repo" && "$WT" -M oldname newname 2>&1)
  # Paths are on stdout, status messages on stderr — both in output via 2>&1.
  # Check the paths are present (logical paths, as stored by git worktree).
  assert_contains "$output" "$old_expected"
  assert_contains "$output" "$new_expected"
  assert_contains "$output" "Renaming branch 'oldname' to 'newname'"
  assert_contains "$output" "Moving worktree"

  branch_not_exists "$repo" oldname
  branch_exists "$repo" newname
  assert_not_exists "$repo/.worktrees/oldname"
  assert_exists "$repo/.worktrees/newname"
}

test_move_long_form() {
  local repo output
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" oldname

  output=$(cd "$repo" && "$WT" --move oldname newname 2>&1)

  branch_not_exists "$repo" oldname
  branch_exists "$repo" newname
  assert_exists "$repo/.worktrees/newname"
  assert_contains "$output" "Moving worktree"
}

test_move_defaults_old_branch_to_head() {
  local repo output
  repo=$(make_repo)
  # Checkout feature_x in the root so HEAD in root is feature_x
  git -C "$repo" checkout -b feature_x >/dev/null 2>&1

  output=$(cd "$repo" && "$WT" -M newname 2>&1)

  branch_not_exists "$repo" feature_x
  branch_exists "$repo" newname
}

test_move_branch_only_no_worktree() {
  local repo output
  repo=$(make_repo)
  create_branch_only "$repo" branchonly

  output=$(cd "$repo" && "$WT" -M branchonly newname 2>&1)

  branch_not_exists "$repo" branchonly
  branch_exists "$repo" newname
  assert_contains "$output" "Renaming branch 'branchonly' to 'newname'"
  assert_not_contains "$output" "Moving worktree"
}

test_move_no_args_shows_usage() {
  local repo output status
  repo=$(make_repo)

  set +e
  output=$(cd "$repo" && "$WT" -M 2>&1)
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "expected usage exit 2 for -M with no arg; got $status; output: $output"
  assert_contains "$output" 'Usage:'
}

test_move_three_args_shows_usage() {
  local repo output status
  repo=$(make_repo)

  set +e
  output=$(cd "$repo" && "$WT" -M a b c 2>&1)
  status=$?
  set -e

  [ "$status" -eq 2 ] || fail "expected usage exit 2 for -M a b c; got $status; output: $output"
  assert_contains "$output" 'Usage:'
}

test_move_nonexistent_old_branch_errors() {
  local repo output status
  repo=$(make_repo)

  set +e
  output=$(cd "$repo" && "$WT" -M no_such_branch newname 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected failure for nonexistent branch'
  assert_contains "$output" "Branch 'no_such_branch' does not exist"
}

test_move_existing_new_branch_errors() {
  local repo output status
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" oldname
  create_branch_worktree_with_commit "$repo" existing

  set +e
  output=$(cd "$repo" && "$WT" -M oldname existing 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected failure for existing target'
  assert_contains "$output" "Branch 'existing' already exists"
}

test_move_from_non_repo_dir_errors() {
  local output status

  set +e
  output=$(cd / && "$WT" -M old new 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected failure from non-repo dir'
  assert_contains "$output" 'Could not find .worktrees directory'
}

test_move_detached_head_with_no_oldbranch_errors() {
  local repo output status
  repo=$(make_repo)
  git -C "$repo" checkout --detach HEAD >/dev/null 2>&1

  set +e
  output=$(cd "$repo" && "$WT" -M newname 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail 'expected failure for detached HEAD with no oldbranch'
  assert_contains "$output" 'Not on a branch'
}

test_zsh_completion_lists_move_options() {
  local output
  output=$("$WT" --zsh-completion)
  assert_contains "$output" '--move'
  assert_contains "$output" '-M'
}

# --- Zsh wrapper tests ---
# Use logical paths (avoid pwd -P) since git worktree stores logical paths
# and the zsh function uses $PWD (logical) for comparison.

assert_zsh_wrapper_moves_and_cds() {
  local form="$1" from_branch="$2" to_branch="$3" start_dir="$4" expected_new_path="$5"
  local repo output status bin_dir

  if ! command -v zsh >/dev/null 2>&1; then
    printf 'skip: zsh unavailable for %s\n' "$form"
    return 0
  fi

  repo=$(make_repo)
  if [ -n "$from_branch" ]; then
    create_branch_worktree_with_commit "$repo" "$from_branch"
  fi

  bin_dir=$(mktemp -d "$SUITE_TMP/bin.XXXXXX")
  ln -s "$WT" "$bin_dir/wt"

  set +e
  output=$(
    PATH="$bin_dir:$PATH" WT_FUNCTIONS_DIR="$ROOT_DIR/zsh/functions" \
      WT_START_CWD="$start_dir" WT_FORM="$form" WT_OLD="$from_branch" WT_NEW="$to_branch" \
      zsh -fc '
        fpath=("$WT_FUNCTIONS_DIR" $fpath)
        autoload -Uz wt
        cd "$WT_START_CWD" || exit 91
        if [[ -n "${WT_OLD:-}" ]]; then
          wt "$WT_FORM" "$WT_OLD" "$WT_NEW" || exit $?
        else
          wt "$WT_FORM" "$WT_NEW" || exit $?
        fi
        print -r -- "cwd:$PWD"
      ' 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "zsh wt $form should succeed; status $status output: $output"
  assert_contains "$output" "cwd:$expected_new_path"
}

assert_zsh_wrapper_moves_no_cd() {
  local form="$1" from_branch="$2" to_branch="$3" start_dir="$4"
  local repo output status bin_dir

  if ! command -v zsh >/dev/null 2>&1; then
    printf 'skip: zsh unavailable for %s\n' "$form"
    return 0
  fi

  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" "$from_branch"

  bin_dir=$(mktemp -d "$SUITE_TMP/bin.XXXXXX")
  ln -s "$WT" "$bin_dir/wt"

  set +e
  output=$(
    PATH="$bin_dir:$PATH" WT_FUNCTIONS_DIR="$ROOT_DIR/zsh/functions" \
      WT_START_CWD="$start_dir" WT_FORM="$form" WT_OLD="$from_branch" WT_NEW="$to_branch" \
      zsh -fc '
        fpath=("$WT_FUNCTIONS_DIR" $fpath)
        autoload -Uz wt
        cd "$WT_START_CWD" || exit 91
        wt "$WT_FORM" "$WT_OLD" "$WT_NEW" || exit $?
        print -r -- "cwd:$PWD"
      ' 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "zsh wt $form should succeed; status $status output: $output"
  assert_contains "$output" "cwd:$start_dir"
}

assert_zsh_wrapper_move_subdir_preservation() {
  local form="$1" repo old_worktree new_worktree subdir output status bin_dir

  if ! command -v zsh >/dev/null 2>&1; then
    printf 'skip: zsh unavailable for %s\n' "$form"
    return 0
  fi

  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" oldname
  old_worktree="$repo/.worktrees/oldname"
  new_worktree="$repo/.worktrees/newname"
  subdir="$old_worktree/sub/dir"
  mkdir -p "$subdir"

  bin_dir=$(mktemp -d "$SUITE_TMP/bin.XXXXXX")
  ln -s "$WT" "$bin_dir/wt"

  set +e
  output=$(
    PATH="$bin_dir:$PATH" WT_FUNCTIONS_DIR="$ROOT_DIR/zsh/functions" \
      WT_START_CWD="$subdir" WT_FORM="$form" \
      zsh -fc '
        fpath=("$WT_FUNCTIONS_DIR" $fpath)
        autoload -Uz wt
        cd "$WT_START_CWD" || exit 91
        wt "$WT_FORM" oldname newname || exit $?
        print -r -- "cwd:$PWD"
      ' 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "zsh wt $form with subdir should succeed; status $status output: $output"
  assert_contains "$output" "cwd:$new_worktree/sub/dir"
}

test_zsh_wrapper_move_cd_if_in_old_worktree() {
  local repo
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" oldname
  assert_zsh_wrapper_moves_and_cds -M oldname newname \
    "$repo/.worktrees/oldname" "$repo/.worktrees/newname"
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" oldname
  assert_zsh_wrapper_moves_and_cds --move oldname newname \
    "$repo/.worktrees/oldname" "$repo/.worktrees/newname"
}

test_zsh_wrapper_move_no_cd_if_not_in_old_worktree() {
  local repo
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" oldname
  assert_zsh_wrapper_moves_no_cd -M oldname newname "$repo"
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" oldname
  assert_zsh_wrapper_moves_no_cd --move oldname newname "$repo"
}

test_zsh_wrapper_move_preserves_subdirectory() {
  assert_zsh_wrapper_move_subdir_preservation -M
  assert_zsh_wrapper_move_subdir_preservation --move
}

test_zsh_wrapper_move_default_head_from_inside_worktree() {
  local repo
  repo=$(make_repo)
  create_branch_worktree_with_commit "$repo" myfeature
  # Run from inside the worktree with only new branch arg
  assert_zsh_wrapper_moves_and_cds -M "" renamed \
    "$repo/.worktrees/myfeature" "$repo/.worktrees/renamed"
}

# --- Runner ---

run_test '-M renames branch and moves worktree' test_move_renames_branch_moves_worktree
run_test '--move long form works' test_move_long_form
run_test '-M defaults old branch to HEAD' test_move_defaults_old_branch_to_head
run_test '-M branch-only (no worktree) renames only' test_move_branch_only_no_worktree
run_test '-M no args shows usage' test_move_no_args_shows_usage
run_test '-M three args shows usage' test_move_three_args_shows_usage
run_test '-M nonexistent old branch errors' test_move_nonexistent_old_branch_errors
run_test '-M existing new branch errors' test_move_existing_new_branch_errors
run_test '-M from non-repo dir errors' test_move_from_non_repo_dir_errors
run_test '-M detached HEAD with no oldbranch errors' test_move_detached_head_with_no_oldbranch_errors
run_test 'zsh completion lists --move and -M options' test_zsh_completion_lists_move_options
run_test 'zsh wrapper -M cd if in old worktree' test_zsh_wrapper_move_cd_if_in_old_worktree
run_test 'zsh wrapper -M no cd if not in old worktree' test_zsh_wrapper_move_no_cd_if_not_in_old_worktree
run_test 'zsh wrapper -M preserves subdirectory' test_zsh_wrapper_move_preserves_subdirectory
run_test 'zsh wrapper -M default HEAD from inside worktree' test_zsh_wrapper_move_default_head_from_inside_worktree

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all move tests passed\n'
