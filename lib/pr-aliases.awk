# Inputs: PR snapshot, registered worktrees, local branches.
function issue_match(value, number) {
  return value ~ ("(^|[^0-9])" number "([^0-9]|$)")
}
FILENAME == ARGV[1] {
  count++; numbers[count]=$1; heads[count]=$2; forks[count]=$3; issues[count]=$4; urls[count]=$5
  states[count]=$6; head_oids[count]=$7
  next
}
FILENAME == ARGV[2] {
  # A stale registration is not an existing worktree.
  worktrees[$1]=$2
  worktree_heads[$1]=$3
  next
}
{ branches[$1]=1; branch_heads[$1]=$2 }
function emit(i, branch) {
  print numbers[i] "\t" branch "\t" urls[i] "\t" states[i] "\t" head_oids[i]
}
END {
  for (i=1; i<=count; i++) {
    found=0
    if (for_status && states[i] == "MERGED") {
      if (head_oids[i] == "") continue
      for (branch in worktrees) {
        if (worktrees[branch] != root_path && worktree_heads[branch] == head_oids[i]) {
          emit(i, branch); found=1
        }
      }
      if (!found && forks[i] == "false" && branch_heads[heads[i]] == head_oids[i]) emit(i, heads[i])
      continue
    }
    n=split(issues[i], linked, ",")
    for (branch in worktrees) {
      path=worktrees[branch]
      name=path; sub(/^.*\//, "", name)
      for (j=1; j<=n; j++) {
        if (linked[j] != "" && (issue_match(branch, linked[j]) || issue_match(name, linked[j]))) {
          emit(i, branch); found=1; break
        }
      }
    }
    if (!found && forks[i] == "false" && heads[i] in branches)
      emit(i, heads[i])
  }
}
