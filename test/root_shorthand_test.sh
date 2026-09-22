#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WT=${WT:-$ROOT_DIR/wt}
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/wt-root-shorthand-suite.XXXXXX")
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
  git -C "$repo" commit -m base >/dev/null 2>&1
  printf '%s\n' "$repo"
}

create_branch_worktree() {
  local repo="$1" branch="$2" worktree_path
  worktree_path="$repo/.worktrees/$branch"
  git -C "$repo" branch "$branch" main >/dev/null 2>&1
  git -C "$repo" worktree add "$worktree_path" "$branch" >/dev/null 2>&1
  printf '%s\n' "$worktree_path"
}

assert_command_resolves_root() {
  local repo="$1" cwd="$2" label="$3" expected output status
  shift 3

  expected=$(canonical_path "$repo")
  set +e
  output=$(cd "$cwd" && "$WT" "$@" 2>&1)
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "$label: expected success, got status $status and output: $output"
  assert_eq "$output" "$expected" "$label"
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

test_dot_root_shorthand_resolves_repo_root() {
  local repo
  repo=$(make_repo)

  assert_command_resolves_root "$repo" "$repo" 'wt .' .
  assert_command_resolves_root "$repo" "$repo" 'wt __path .' __path .
}

test_dash_legacy_root_alias_still_resolves_repo_root() {
  local repo
  repo=$(make_repo)

  assert_command_resolves_root "$repo" "$repo" 'wt -' -
  assert_command_resolves_root "$repo" "$repo" 'wt __path -' __path -
}

test_dot_root_shorthand_resolves_root_from_linked_worktree() {
  local repo linked_path
  repo=$(make_repo)
  linked_path=$(create_branch_worktree "$repo" topic)

  assert_command_resolves_root "$repo" "$linked_path" 'wt . from linked worktree' .
}

test_zsh_wrapper_dot_from_deleted_worktree_resolves_root_without_getcwd_noise() {
  local repo linked_path expected output status bin_dir

  if ! command -v zsh >/dev/null 2>&1; then
    printf 'skip: zsh unavailable\n'
    return 0
  fi

  repo=$(make_repo)
  linked_path=$(create_branch_worktree "$repo" topic)
  expected=$(canonical_path "$repo")
  bin_dir=$(mktemp -d "$SUITE_TMP/bin.XXXXXX")
  ln -s "$WT" "$bin_dir/wt"

  set +e
  output=$(
    PATH="$bin_dir:$PATH" WT_FUNCTIONS_DIR="$ROOT_DIR/zsh/functions" WT_DELETED_CWD="$linked_path" \
      zsh -fc '
        fpath=("$WT_FUNCTIONS_DIR" $fpath)
        autoload -Uz wt
        cd "$WT_DELETED_CWD" || exit 91
        rm -rf "$WT_DELETED_CWD" || exit 92
        wt .
      ' 2>&1
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "zsh wt . from deleted worktree: expected success, got status $status and output: $output"
  assert_eq "$output" "$expected" 'zsh wt . from deleted worktree emits only repo root'
}

run_test 'dot shorthand resolves repo root' test_dot_root_shorthand_resolves_repo_root
run_test 'dash legacy root alias still resolves repo root' test_dash_legacy_root_alias_still_resolves_repo_root
run_test 'dot shorthand resolves root from linked worktree' test_dot_root_shorthand_resolves_root_from_linked_worktree
run_test 'zsh wrapper dot resolves root from deleted worktree without getcwd noise' test_zsh_wrapper_dot_from_deleted_worktree_resolves_root_without_getcwd_noise

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all root shorthand tests passed\n'
