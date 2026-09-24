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
    assert len(trace.read_text().splitlines()) <= 6, "Git calls must not scale with worktrees"

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
    expected = []
    for branch, path, _, state, _, short_sha in rows:
        shown_branch = "(detached)" if state == "detached" else branch
        relative = os.path.relpath(path, repo) if path else ""
        label = f"{short_sha:<{sha_width}} {shown_branch}"
        if relative:
            label = f"{short_sha:<{sha_width}} {shown_branch:<{width}} {relative}"
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

print("listing scale, stale worktrees, numeric branches, and completion labels passed")
