#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WT=${WT:-$ROOT_DIR/wt}
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/wt-list-candidates-suite.XXXXXX")
EMPTY_XDG_CONFIG_HOME="$SUITE_TMP/empty-xdg"
failures=0

cleanup() {
  rm -rf "$SUITE_TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
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

create_branch() {
  local repo="$1" branch="$2"
  git -C "$repo" branch "$branch" main >/dev/null 2>&1
}

create_branch_worktree() {
  local repo="$1" branch="$2" path="${3:-}"
  [ -n "$path" ] || path="$repo/.worktrees/$branch"
  create_branch "$repo" "$branch"
  git -C "$repo" worktree add "$path" "$branch" >/dev/null 2>&1
}

candidate_order() {
  awk -F '\t' '{ print $1 ":" $3 }'
}

run_wt_without_branch_sort_config() {
  GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    XDG_CONFIG_HOME="$EMPTY_XDG_CONFIG_HOME" \
    "$WT" __list
}

assert_order() {
  local actual="$1" expected="$2"
  if [ "$actual" != "$expected" ]; then
    fail "expected order:
$expected
actual order:
$actual"
  fi
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

test_branch_sort_orders_worktrees_and_branch_only_rows_from_linked_cwd() {
  local repo actual expected
  repo=$(make_repo)
  create_branch_worktree "$repo" alpha
  create_branch_worktree "$repo" beta
  create_branch "$repo" delta
  create_branch "$repo" zeta
  git -C "$repo" config branch.sort -refname

  actual=$(cd "$repo/.worktrees/beta" && "$WT" __list | candidate_order)
  expected=$(cat <<EOF
main:root
beta:worktree
alpha:worktree
zeta:branch
delta:branch
EOF
)

  assert_order "$actual" "$expected"
}

test_without_branch_sort_preserves_native_worktree_path_order() {
  local repo actual expected
  repo=$(make_repo)
  create_branch_worktree "$repo" beta
  create_branch_worktree "$repo" alpha
  create_branch "$repo" delta
  create_branch "$repo" zeta

  actual=$(cd "$repo" && run_wt_without_branch_sort_config | candidate_order)
  expected=$(cat <<EOF
main:root
alpha:worktree
beta:worktree
delta:branch
zeta:branch
EOF
)

  assert_order "$actual" "$expected"
}

run_test 'branch.sort orders linked worktrees and branch-only rows from linked cwd' test_branch_sort_orders_worktrees_and_branch_only_rows_from_linked_cwd
run_test 'without branch.sort native worktree path order is preserved' test_without_branch_sort_preserves_native_worktree_path_order

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all list candidate ordering tests passed\n'
