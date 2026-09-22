#!/usr/bin/env python3
"""Check listing scale without flaky wall-clock limits, plus completion labels."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
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
    branches = ["01", "1", "stale"] + [f"topic/{i:04}" for i in range(300)]
    git("update-ref", "--stdin", input="".join(
        f"create refs/heads/{branch} {sha}\n" for branch in branches
    ).encode())
    linked = repo / ".worktrees" / "01"
    external = base / "external worktree"
    stale = repo / ".worktrees" / "stale"
    for branch, path in [("01", linked), ("1", external), ("stale", stale)]:
        git("worktree", "add", "-q", str(path), branch)
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
    assert len(rows) == len(branches) + 1
    assert len({row[0] for row in rows}) == len(rows)
    assert rows[0][:3] == ["main", str(repo), "root"]
    assert [row[0] for row in rows[1:3]] == ["1", "01"]
    by_branch = {row[0]: row for row in rows}
    assert by_branch["01"][1:3] == [str(linked), "worktree"]
    assert by_branch["1"][1:3] == [str(external), "worktree"]
    assert by_branch["stale"][1:3] == ["", "branch"]
    assert [row[0] for row in rows[3:]] == sorted(set(branches) - {"01", "1"}, reverse=True)
    assert len(trace.read_text().splitlines()) <= 6, "Git calls must not scale with worktrees"

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
    width = max(len(row[0]) for row in rows)
    sha_width = max(len(row[5]) for row in rows)
    expected = []
    for branch, path, _, _, _, short_sha in rows:
        relative = os.path.relpath(path, repo) if path else ""
        label = f"{short_sha:<{sha_width}} {branch}"
        if relative:
            label = f"{short_sha:<{sha_width}} {branch:<{width}} {relative}"
        expected.append(f"{branch}\t{label}")
    assert completed.splitlines() == expected

print("listing scale, stale worktrees, numeric branches, and completion labels passed")
