# Inputs: PR snapshot, registered worktrees, local branches.
function issue_match(value, number) {
  return value ~ ("(^|[^0-9])" number "([^0-9]|$)")
}
FILENAME == ARGV[1] {
  count++; numbers[count]=$1; heads[count]=$2; forks[count]=$3; issues[count]=$4
  next
}
FILENAME == ARGV[2] {
  # A stale registration is not an existing worktree.
  worktrees[$1]=$2
  next
}
{ branches[$1]=1 }
END {
  for (i=1; i<=count; i++) {
    found=0
    n=split(issues[i], linked, ",")
    for (branch in worktrees) {
      path=worktrees[branch]
      name=path; sub(/^.*\//, "", name)
      for (j=1; j<=n; j++) {
        if (linked[j] != "" && (issue_match(branch, linked[j]) || issue_match(name, linked[j]))) {
          print numbers[i] "\t" branch; found=1; break
        }
      }
    }
    if (!found && forks[i] == "false" && heads[i] in branches)
      print numbers[i] "\t" heads[i]
  }
}
