#!/usr/bin/env python3
"""Verify cached upstream status in candidate rows and both shell displays."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="wt-upstream-") as temporary:
    base = Path(temporary).resolve()
    repo = base / "repo"
    repo.mkdir()
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")

    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args], env=env, text=True).strip()

    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.invalid")
    git("commit", "-q", "--allow-empty", "-m", "base")
    initial = git("rev-parse", "HEAD")
    git("commit", "-q", "--allow-empty", "-m", "local")
    local = git("rev-parse", "HEAD")
    git("checkout", "-q", "--detach", initial)
    git("commit", "-q", "--allow-empty", "-m", "remote")
    remote = git("rev-parse", "HEAD")
    git("checkout", "-q", "main")
    git("remote", "add", "origin", "https://example.invalid/repository.git")
    expected = {
        "main": "[ahead 1]",
        "behind": "[behind 1]",
        "diverged": "[ahead 1] [behind 1]",
        "equal": "",
        "untracked": "[no upstream]",
        "gone": "[gone]",
        "branchonly": "[ahead 1]",
    }
    for branch, head, upstream in [
        ("main", local, initial),
        ("behind", initial, remote),
        ("diverged", local, remote),
        ("equal", local, local),
        ("untracked", initial, None),
        ("gone", initial, None),
        ("branchonly", local, initial),
    ]:
        if branch != "main":
            git("branch", branch, head)
        if upstream:
            git("update-ref", f"refs/remotes/origin/{branch}", upstream)
        if upstream or branch == "gone":
            git("config", f"branch.{branch}.remote", "origin")
            git("config", f"branch.{branch}.merge", f"refs/heads/{branch}")
        if branch not in ("main", "branchonly"):
            git("worktree", "add", "-q", str(repo / ".worktrees" / branch), branch)
    detached = repo / ".worktrees" / "detached"
    git("worktree", "add", "-q", "--detach", str(detached), initial)
    (repo / ".worktrees" / "diverged" / "untracked").write_text("dirty")

    bin_dir = base / "bin"
    bin_dir.mkdir()
    trace = base / "git-calls"
    git_wrapper = bin_dir / "git"
    git_wrapper.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$WT_TRACE"\n'
                           f'exec {shlex.quote(shutil.which("git"))} "$@"\n')
    git_wrapper.chmod(0o755)
    capture = base / "picker"
    fzf = bin_dir / "fzf"
    fzf.write_text('#!/bin/sh\ncat > "$WT_CAPTURE"\nexit 130\n')
    fzf.chmod(0o755)
    env.update(PATH=f"{bin_dir}:{ROOT}:{env['PATH']}", WT_CAPTURE=str(capture), WT_TRACE=str(trace))
    rows = subprocess.check_output([str(ROOT / "wt"), "__list"], cwd=repo, env=env, text=True)
    calls = trace.read_text().splitlines()
    assert sum(call.startswith("for-each-ref ") for call in calls) == 1, calls
    assert sum(call.startswith(f"-C {repo} status ") for call in calls) == 1, calls
    by_branch = {row[0]: row for row in (line.split("\t") for line in rows.splitlines())}
    for branch, status in expected.items():
        assert by_branch[branch][8] == status, (branch, by_branch[branch])
    assert by_branch[str(detached)][8] == ""

    subprocess.run([str(ROOT / "wt")], cwd=repo, env=env, check=False, capture_output=True)
    picker = dict(line.split("\t", 1) for line in capture.read_text().splitlines())
    script = '''
compdef() { :; }
compadd() {
  local i
  for ((i = 1; i <= ${#values}; i++)); do
    print -r -- "${values[i]}"$'\\t'"${labels[i]}"
  done
}
eval "$(command wt --zsh-completion)"
words=(wt "")
CURRENT=2
_wt
'''
    completion = subprocess.check_output(["zsh", "-f", "-c", script], cwd=repo, env=env, text=True)
    completion = dict(line.split("\t", 1) for line in completion.splitlines())
    for display in (picker, completion):
        for branch, status in expected.items():
            for label in ("[ahead 1]", "[behind 1]", "[no upstream]", "[gone]"):
                assert (label in display[branch]) == (label in status), (branch, display[branch])
        assert "[dirty]" in display["diverged"]
        assert "[unmerged]" not in display["diverged"]  # Same commit as root.
        assert "[root]" in display["main"]
        assert "[no upstream]" not in display[str(detached)]
    # Updating the cached ref removes the ahead label without any fetch.
    git("update-ref", "refs/remotes/origin/main", local)
    rows = subprocess.check_output([str(ROOT / "wt"), "__list"], cwd=repo, env=env, text=True)
    assert rows.splitlines()[0].split("\t")[8] == ""
    git("checkout", "-q", "--detach", local)
    rows = subprocess.check_output([str(ROOT / "wt"), "__list"], cwd=repo, env=env, text=True)
    detached_root = rows.splitlines()[0].split("\t")
    assert detached_root[:4] == [str(repo), str(repo), "root", "detached"]
    assert detached_root[5] == local[:7]
    assert detached_root[8] == ""
print("All upstream status checks passed.")
