# GitHub metadata is optional. Local listings never start network requests.
pr_cache_path() {
  local root git_dir
  root=${1:-$(find_worktrees_root)} || return 1
  if [ -d "$root/.git" ]; then
    printf '%s/wt-prs\n' "$root/.git"
  else
    git_dir=$(git -C "$root" rev-parse --git-common-dir) || return 1
    [[ "$git_dir" == /* ]] || git_dir="$root/$git_dir"
    printf '%s/wt-prs\n' "$git_dir"
  fi
}

pr_identity() {
  { git config --get-regexp '^remote\..*\.url$' || true; printf '%s\n' "${GH_REPO:-}" "${GH_HOST:-}"; } | cksum
}

# Bound the whole gh invocation, including pagination, without requiring timeout.
pr_gh() (
  local child timer result=0
  GH_PROMPT_DISABLED=1 gh "$@" &
  child=$!
  (
    trap 'kill "$sleeper" 2>/dev/null || true; exit' TERM
    sleep 8 &
    sleeper=$!
    wait "$sleeper"
    kill "$child" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  timer=$!
  trap 'kill "$child" "$timer" 2>/dev/null || true' EXIT
  trap 'exit 1' INT TERM
  wait "$child" || result=$?
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  trap - EXIT
  return "$result"
)

refresh_prs() (
  local root cache tmp identity
  command -v gh >/dev/null 2>&1 || return 1
  root=$(find_worktrees_root) || return 1
  cd "$root" || return 1
  # Avoid GitHub requests (and authentication prompts) for local-only repos.
  [ -n "$(git remote)" ] || return 1
  cache=$(pr_cache_path) || return 1
  identity=$(pr_identity)
  tmp=$(mktemp "$cache.XXXXXX") || return 1
  trap 'rm -f "$tmp"' EXIT
  trap 'exit 1' INT TERM
  printf '%s\n' "$identity" > "$tmp"
  # gh paginates the PR connection. Refuse incomplete linked-issue data.
  pr_gh api graphql --paginate -F owner='{owner}' -F name='{repo}' -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(first: 100, states: OPEN, after: $endCursor) {
          nodes { number headRefName isCrossRepository url
            closingIssuesReferences(first: 100) {
              nodes { number url } pageInfo { hasNextPage }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' --jq '.data.repository.pullRequests.nodes[] |
      if .closingIssuesReferences.pageInfo.hasNextPage then error("Too many linked issues") else . end |
      . as $pr | [(.number|tostring), .headRefName, (.isCrossRepository|tostring),
      ([.closingIssuesReferences.nodes[]? |
        select((.url|split("/issues/")[0]) == ($pr.url|split("/pull/")[0])) |
        .number|tostring] | join(","))] | @tsv' >> "$tmp" || return 1
  # A remote change during the request must not publish metadata for the old repo.
  [ "$identity" = "$(pr_identity)" ] || return 1
  mv -f "$tmp" "$cache"
)

cached_prs() {
  local cache identity
  cache=$(pr_cache_path "${1:-}") || return 0
  [ -f "$cache" ] || return 0
  IFS= read -r identity < "$cache" || return 0
  [ "$identity" = "$(pr_identity)" ] || return 0
  tail -n +2 "$cache"
}

# Prefer worktrees named for linked issues. Otherwise use an exact local head
# branch. Fork heads cannot safely be identified by branch name alone.
pr_aliases() {
  awk -F '\t' -f "$WT_LIB_DIR/pr-aliases.awk" "$1" <(
    while IFS=$'\t' read -r branch path _; do
      [ -d "$path" ] && [ -e "$path/.git" ] || continue
      printf '%s\t%s\n' "$branch" "$path"
    done < <(worktree_branch_rows)
  ) <(branch_ref_rows)
}

annotate_prs() {
  local rows root prs
  rows=$(cat)
  root=$(find_worktrees_root) || { printf '%s\n' "$rows"; return; }
  cd "$root" || return 1
  prs=$(cached_prs "$root")
  if [ -z "$prs" ]; then
    printf '%s\n' "$rows"
    return
  fi
  awk -F '\t' 'BEGIN { OFS="\t" }
    FILENAME == ARGV[1] { labels[$2] = labels[$2] (labels[$2] == "" ? "" : " ") "[PR #" $1 "]"; next }
    { $10 = ($4 == "detached" ? "" : labels[$1]); print }
  ' <(pr_aliases <(printf '%s\n' "$prs")) <(printf '%s\n' "$rows")
}

resolve_pr_branch() (
  local number="$1" root prs aliases
  root=$(find_worktrees_root) || return 1
  cd "$root" || return 1
  prs=$(cached_prs "$root" | awk -F '\t' -v number="$number" '$1 == number')
  if [ -z "$prs" ]; then
    [ "${2:-}" != cached ] || return 1
    command -v gh >/dev/null 2>&1 || return 1
    [ -n "$(git remote)" ] || return 1
    prs=$(pr_gh pr view "$number" --json number,headRefName,isCrossRepository,url,closingIssuesReferences --jq '
      . as $pr | [(.number|tostring), .headRefName, (.isCrossRepository|tostring),
      ([.closingIssuesReferences[]? |
        select((.url|split("/issues/")[0]) == ($pr.url|split("/pull/")[0])) |
        .number|tostring] | join(","))] | @tsv' 2>/dev/null) || return 1
  fi
  aliases=$(pr_aliases <(printf '%s\n' "$prs") | cut -f2- | sort -u)
  [ -n "$aliases" ] || return 1
  if [[ "$aliases" == *$'\n'* ]]; then
    echo "PR #$number matches multiple linked-issue worktrees; use a branch or path:" >&2
    printf '  %s\n' "$aliases" >&2
    return 2
  fi
  printf '%s\n' "$aliases"
)
