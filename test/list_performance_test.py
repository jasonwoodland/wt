#!/usr/bin/env python3
"""Check listing scale without flaky wall-clock limits, plus completion labels."""
import os
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
GIT = shutil.which("git")


with tempfile.TemporaryDirectory(prefix="wt-list-perf-") as temp:
    base = Path(temp).resolve()
    repo = base / "repo with spaces"
    repo.mkdir()
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

    def git(*args, **kwargs):
        return subprocess.check_output([GIT, "-C", str(repo), *args], env=env, **kwargs)

    git("init", "-q", "-b", "main")
    git("config", "user.name", "wt test")
    git("config", "user.email", "wt@example.invalid")
    git("commit", "-q", "--allow-empty", "-m", "base")
    sha = git("rev-parse", "HEAD").decode().strip()
    branches = ["01", "1", "stale", "eval/121"] + [f"topic/{i:04}" for i in range(300)]
    git("update-ref", "--stdin", input="".join(
        f"create refs/heads/{branch} {sha}\n" for branch in branches
    ).encode())
    linked = repo / ".worktrees" / "01"
    external = base / "external worktree"
    stale = repo / ".worktrees" / "stale"
    for branch, path in [("01", linked), ("1", external), ("stale", stale)]:
        git("worktree", "add", "-q", str(path), branch)
    detached_paths = [repo / ".worktrees" / "eval" / "121", base / "detached worktree"]
    for path in detached_paths:
        git("worktree", "add", "-q", "--detach", str(path), "HEAD")
    shutil.rmtree(stale)
    git("config", "branch.sort", "-refname")

    bin_dir = base / "bin"
    bin_dir.mkdir()
    trace = base / "git-calls"
    wrapper = bin_dir / "git"
    wrapper.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$WT_TRACE"\n'
                       f'exec {shlex.quote(GIT)} "$@"\n')
    wrapper.chmod(0o755)
    env.update(PATH=f"{bin_dir}:{ROOT}:{env['PATH']}", WT_TRACE=str(trace))
    output = subprocess.check_output([str(ROOT / "wt"), "__list"], cwd=repo, env=env, text=True)
    rows = [line.split("\t") for line in output.splitlines()]
    assert len(rows) == len(branches) + 1 + len(detached_paths)
    assert len({row[0] for row in rows}) == len(rows)
    assert rows[0][:3] == ["main", str(repo), "root"]
    assert [row[0] for row in rows[1:3]] == ["1", "01"]
    by_branch = {row[0]: row for row in rows}
    assert by_branch["01"][1:3] == [str(linked), "worktree"]
    assert by_branch["1"][1:3] == [str(external), "worktree"]
    assert by_branch["stale"][1:3] == ["", "branch"]
    assert [row[0] for row in rows[3:] if row[2] == "branch"] == sorted(set(branches) - {"01", "1"}, reverse=True)
    calls = trace.read_text().splitlines()
    assert len(calls) <= 9, "Only snapshots, batched ancestry, and one status check per existing worktree are needed here"
    assert sum(call.startswith("for-each-ref ") for call in calls) == 2
    assert sum(call.startswith("for-each-ref --merged=") for call in calls) == 1
    assert not any(call.startswith("merge-base ") for call in calls), "Identical tips need no ancestry checks"
    assert not any(call.startswith("branch --show-current") or call.startswith("rev-parse ") for call in calls)

    for path in detached_paths:
        assert by_branch[str(path)][1:5] == [str(path), "worktree", "detached", "0"]
        resolved = subprocess.check_output([str(ROOT / "wt"), "__path", str(path)],
                                           cwd=repo, env=env, text=True)
        assert resolved.strip() == str(path)

    # Exercise the actual completion function without an interactive terminal.
    # compadd's arrays are visible through zsh's dynamic local scope.
    script = r'''
compdef() { :; }
compadd() {
  local i
  for ((i = 1; i <= ${#values}; i++)); do
    print -r -- "${values[i]}"$'\t'"${labels[i]}"
  done
}
eval "$(command wt --zsh-completion)"
words=(wt "")
CURRENT=2
_wt
'''
    completed = subprocess.check_output(["zsh", "-f", "-c", script], cwd=repo, env=env, text=True)
    width = max(len("(detached)" if row[3] == "detached" else row[0]) for row in rows)
    sha_width = max(len(row[5]) for row in rows)
    formatted_rows = []
    for branch, path, kind, state, _, short_sha, clean, merged, tracking in rows:
        shown_branch = "(detached)" if state == "detached" else branch
        relative = os.path.relpath(path, repo) if path else ""
        statuses = []
        if clean == "0":
            statuses.append("[dirty]")
        if kind == "root":
            statuses.append("[root]")
        elif merged == "1":
            statuses.append("[merged]")
        if tracking:
            statuses.append(tracking)
        status = " ".join(statuses)
        formatted_rows.append((branch, short_sha, shown_branch, status, relative))
    status_width = max(len(row[3]) for row in formatted_rows)
    expected = []
    for branch, short_sha, shown_branch, status, relative in formatted_rows:
        label = f"{short_sha:<{sha_width}} {shown_branch:<{width}} {status:<{status_width}}"
        if relative:
            label += f" {relative}"
        expected.append(f"{branch}\t{label}")
    assert completed.splitlines() == expected

    # fzf returns the original hidden target, including spaces, not display text.
    fzf = bin_dir / "fzf"
    fzf.write_text("#!/bin/sh\nawk -F '\\t' '$1 == ENVIRON[\"WT_SELECTED\"]'\n")
    fzf.chmod(0o755)
    for path in detached_paths:
        selection_env = dict(env, WT_SELECTED=str(path))
        selected = subprocess.check_output([str(ROOT / "wt")], cwd=repo,
                                           env=selection_env, text=True)
        assert selected.strip() == str(path)
        switched = subprocess.check_output([
            "zsh", "-f", "-c",
            'fpath=("$WT_FUNCTIONS" $fpath); autoload -Uz wt; wt "$WT_SELECTED"; pwd',
        ], cwd=repo, env=dict(selection_env, WT_FUNCTIONS=str(ROOT / "zsh/functions")), text=True)
        assert switched.splitlines() == [str(path), str(path)]

    # A detached root must remain a root row (including delete protection).
    git("checkout", "-q", "--detach")
    detached_rows = subprocess.check_output([str(ROOT / "wt"), "__list"],
                                            cwd=repo, env=env, text=True).splitlines()
    assert detached_rows[0].split("\t")[:5] == [str(repo), str(repo), "root", "detached", "0"]
    assert sum(row.split("\t")[1] == str(repo) for row in detached_rows) == 1

    # Different tips must still use a single branch ancestry query. Include
    # detached tips and an untracked directory.
    tree = git("rev-parse", "HEAD^{tree}").decode().strip()
    child = git("commit-tree", tree, "-p", sha, input=b"child\n").decode().strip()
    ahead = git("commit-tree", tree, "-p", child, input=b"ahead\n").decode().strip()
    git("update-ref", "HEAD", child)
    git("update-ref", "refs/heads/01", ahead)
    subprocess.check_call([GIT, "-C", str(detached_paths[0]), "update-ref", "HEAD", ahead], env=env)
    nested = external / "untracked" / "nested"
    nested.mkdir(parents=True)
    (nested / "file").write_text("dirty\n")
    trace.write_text("")
    varied = subprocess.check_output([str(ROOT / "wt"), "__list"], cwd=repo, env=env, text=True)
    varied_rows = {row[0]: row for row in (line.split("\t") for line in varied.splitlines())}
    assert varied_rows["01"][7] == "0", "Ahead branch is unmerged"
    assert varied_rows["1"][6:8] == ["0", "1"], "Ancestor branch is merged and untracked directory is dirty"
    assert varied_rows[str(detached_paths[0])][7] == "0", "Ahead detached tip is unmerged"
    assert varied_rows[str(detached_paths[1])][7] == "1", "Ancestor detached tip is merged"
    calls = trace.read_text().splitlines()
    assert sum(call.startswith("for-each-ref --merged=") for call in calls) == 1
    assert sum(call.startswith("merge-base ") for call in calls) == len(detached_paths)

    # Exercise more worktrees than the worker limit, with delayed status
    # processes. Check the actual overlap and output order, not a time budget.
    for i in range(12):
        git("worktree", "add", "-q", "-b", f"parallel/{i}", str(repo / ".worktrees" / f"parallel-{i}"), sha)
    expected = subprocess.check_output([str(ROOT / "wt"), "__list"], cwd=repo, env=env)
    events = base / "status-events"
    wrapper.write_text(f"#!{sys.executable}\n" + r'''
import fcntl
import json
import os
import subprocess
import sys
import time

args = sys.argv[1:]
real_git = os.environ["WT_REAL_GIT"]
if "status" not in args:
    os.execv(real_git, [real_git, *args])

def record(change):
    with open(os.environ["WT_STATUS_EVENTS"], "a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(change) + "\n")
        stream.flush()

record(1)
try:
    time.sleep(0.1)
    result = subprocess.call([real_git, *args])
finally:
    record(-1)
sys.exit(result)
''')
    concurrent_env = dict(env, WT_REAL_GIT=GIT, WT_STATUS_EVENTS=str(events))
    concurrent = subprocess.check_output([str(ROOT / "wt"), "__list"], cwd=repo, env=concurrent_env)
    assert concurrent == expected, "Parallel checks must preserve every row and its ordering"
    active = peak = starts = 0
    for change in map(json.loads, events.read_text().splitlines()):
        active += change
        starts += change == 1
        peak = max(peak, active)
        assert 0 <= active <= 8, "At most eight status checks may run together"
    assert active == 0 and starts == 17, "All existing worktrees must finish their checks"
    assert peak > 1, "Status checks should overlap"

    # Hundreds of cached PRs must add a fixed number of Git queries, with no
    # network calls while listing. Keep upstream and PR fields independent.
    wrapper.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$WT_TRACE"\n'
                       f'exec {shlex.quote(GIT)} "$@"\n')
    git("remote", "add", "origin", "https://github.com/example/performance.git")
    trace.write_text("")
    subprocess.check_output([str(ROOT / "wt"), "__list"], cwd=repo, env=env)
    baseline_calls = len(trace.read_text().splitlines())
    gh_trace = base / "gh-calls"
    gh = bin_dir / "gh"
    gh.write_text('#!/bin/sh\nprintf call >> "$WT_GH_TRACE"\n'
                  + "cat <<'EOF'\n"
                  + "".join(f"{10000+i}\t{branch}\tfalse\t\n" for i, branch in enumerate(branches))
                  + "EOF\n")
    gh.chmod(0o755)
    cached_env = dict(env, WT_GH_TRACE=str(gh_trace))
    subprocess.check_call([str(ROOT / "wt"), "__pr_refresh"], cwd=repo, env=cached_env)
    trace.write_text("")
    cached = subprocess.check_output([str(ROOT / "wt"), "__list"], cwd=repo, env=cached_env, text=True)
    assert gh_trace.read_text() == "call", "Reading PR metadata must not refresh it"
    assert len(trace.read_text().splitlines()) <= baseline_calls + 3, "PR joins must batch Git queries"
    cached_rows = {fields[0]: fields for fields in (line.split("\t") for line in cached.splitlines())}
    for i, branch in enumerate(branches):
        assert cached_rows[branch][9] == f"[PR #{10000+i}]"
        assert "PR #" not in cached_rows[branch][8]

print("listing scale, cached PR scale, stale worktrees, numeric branches, and completion labels passed")
