#!/usr/bin/env python3
"""Merged cleanup preserves ahead worktrees, dirty files and new local commits."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WT = str(ROOT / "wt")
with tempfile.TemporaryDirectory(prefix="wt-clean-upstream-") as temporary:
    base = Path(temporary).resolve()
    repo, bin_dir = base / "repo", base / "bin"
    repo.mkdir()
    bin_dir.mkdir()
    data, trace = base / "prs", base / "calls"
    gh = bin_dir / "gh"
    gh.write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
with open(os.environ['CLEAN_TRACE'],'a') as f: f.write('call\\n')
if os.environ.get('CLEAN_FAIL'): sys.exit(1)
print(Path(os.environ['CLEAN_DATA']).read_text(),end='')
''')
    gh.chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}:{ROOT}:{os.environ['PATH']}",
               CLEAN_DATA=str(data), CLEAN_TRACE=str(trace),
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")

    def git(*args, cwd=None, input=None):
        return subprocess.check_output(["git", "-C", str(cwd or repo), *args], env=env,
                                       input=input, text=True, stderr=subprocess.DEVNULL).strip()

    def wt(*args, input=None, **extra):
        return subprocess.run([WT, *args], cwd=repo, env=dict(env, **extra),
                              input=input, text=True, capture_output=True, timeout=15)

    git("init", "-q", "-b", "main")
    git("config", "user.name", "wt test")
    git("config", "user.email", "wt@example.invalid")
    git("commit", "-q", "--allow-empty", "-m", "base")
    git("remote", "add", "origin", "https://github.com/example/repo.git")
    initial = git("rev-parse", "HEAD")
    paths, heads, records = {}, {}, []

    def create(name, tracking="equal", via_wt=True, worked=True, state="MERGED"):
        path = repo / ".worktrees" / name
        paths[name] = path
        if via_wt:
            result = wt("-b", name)
            assert result.returncode == 0, result.stderr
        else:
            git("worktree", "add", "-q", "-b", name, str(path), initial)
        if worked:
            git("commit", "-q", "--allow-empty", "-m", name, cwd=path)
        head = heads[name] = git("rev-parse", "HEAD", cwd=path)
        if tracking != "none":
            upstream = head
            if tracking == "ahead":
                upstream = initial
            elif tracking in ("behind", "diverged"):
                parent = head if tracking == "behind" else initial
                upstream = git("commit-tree", git("rev-parse", "HEAD^{tree}"), "-p", parent,
                               input=f"remote {name}")
            git("update-ref", f"refs/remotes/origin/{name}", upstream)
            git("config", f"branch.{name}.remote", "origin")
            git("config", f"branch.{name}.merge", f"refs/heads/{name}")
        number = 1000 + len(records)
        records.append(f"{number}\t{name}\tfalse\t\thttps://github.com/example/repo/pull/{number}\t{state}\t{head}\n")
        return path

    def snapshot():
        data.write_text("".join(records))
        result = wt("__pr_refresh")
        assert result.returncode == 0, result.stderr

    create("pushed")
    create("ahead", tracking="ahead")
    create("diverged", tracking="diverged")
    create("behind", tracking="behind")
    create("no-tracking", tracking="none")
    create("dirty", via_wt=False)
    (paths["dirty"] / "untracked").write_text("keep me")
    create("new-work", via_wt=False)
    git("commit", "-q", "--allow-empty", "-m", "after PR merge", cwd=paths["new-work"])
    create("unrecorded", via_wt=False)
    create("unrecorded-ahead", via_wt=False, tracking="ahead")
    create("untouched", worked=False)
    create("open", state="OPEN")
    create("local-ahead", tracking="ahead")
    git("merge", "--no-ff", "local-ahead", "-m", "merge local work")
    detached_merged = repo / ".worktrees/detached-merged"
    detached_unmerged = repo / ".worktrees/detached-unmerged"
    git("worktree", "add", "-q", "--detach", str(detached_merged), initial)
    git("worktree", "add", "-q", "--detach", str(detached_unmerged), heads["pushed"])
    snapshot()

    # Cache evidence suffices, and declining confirmation preserves the worktree.
    calls = trace.read_text()
    result = wt("-c", "--", "pushed", input="n\n")
    assert result.returncode == 130 and paths["pushed"].exists(), result.stdout
    assert trace.read_text() == calls
    # Detached worktrees require local ancestry, even with matching PR evidence.
    result = wt("-cf", str(detached_unmerged))
    assert result.returncode == 0 and detached_unmerged.exists(), result.stdout
    assert trace.read_text() == calls

    result = wt("-cf")
    assert result.returncode == 0, result.stderr
    for name in ("pushed", "behind", "no-tracking", "unrecorded", "untouched"):
        assert not paths[name].exists(), (name, result.stdout)
        git("show-ref", "--verify", "refs/heads/" + name)
    for name in ("ahead", "diverged", "dirty", "new-work", "unrecorded-ahead", "open", "local-ahead"):
        assert paths[name].exists(), (name, result.stdout)
    assert "Skipped clean worktrees ahead of upstream:" in result.stdout
    assert not detached_merged.exists() and detached_unmerged.exists()
    assert repo.exists()
    assert len(trace.read_text().splitlines()) <= len(calls.splitlines()) + 1, "Refresh must happen at most once"

    # A cold cache is refreshed once; a failed lookup preserves upstream-only work.
    create("cold")
    data.write_text("".join(records))
    (repo / ".git/wt-prs").unlink()
    calls = len(trace.read_text().splitlines())
    result = wt("-cf", "--", "cold")
    assert result.returncode == 0 and not paths["cold"].exists(), result.stdout
    assert len(trace.read_text().splitlines()) == calls + 1
    # Ahead worktrees are rejected before any remote lookup is needed.
    (repo / ".git/wt-prs").unlink()
    calls = trace.read_text()
    for name in ("diverged", "local-ahead"):
        result = wt("-cf", "--", name)
        assert result.returncode == 0 and paths[name].exists(), result.stdout
    assert trace.read_text() == calls
    create("offline")
    result = wt("-cf", "--", "offline", CLEAN_FAIL="1")
    assert result.returncode == 0 and paths["offline"].exists(), result.stdout

    # Recheck after confirmation: either a new commit or an upstream-ref change
    # must invalidate eligibility before the worktree can be removed.
    for name, change, flag in (("prompt-new-work", "commit", "-c"), ("prompt-ahead", "tracking", "-c"),
                               ("prompt-local-ahead", "tracking", "-c"),
                               ("prompt-dirty", "dirty", "-c"), ("prompt-all-dirty", "dirty", "-ca")):
        create(name)
        if name == "prompt-local-ahead":
            git("merge", "--no-ff", name, "-m", "locally merged before prompt")
        snapshot()
        calls = trace.read_text()
        process = subprocess.Popen([WT, flag, "--", name], cwd=repo, env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        first = process.stdout.readline()
        expected = "Remove 1 clean merged" if flag == "-c" else "Remove 1 clean non-main"
        assert first.startswith(expected), first
        if change == "commit":
            git("commit", "-q", "--allow-empty", "-m", "while prompting", cwd=paths[name])
        elif change == "tracking":
            git("update-ref", "refs/remotes/origin/" + name, initial)
        elif change == "dirty":
            (paths[name] / "while-prompting").write_text("keep me")
        output, error = process.communicate("y\n", timeout=10)
        assert process.returncode == 0 and paths[name].exists(), (output, error)
        assert "no longer eligible" in output
        assert trace.read_text() == calls, "Removal rechecks must not refresh PRs"

    # --all explicitly bypasses the merge and ahead safeguards.
    result = wt("-cfa", "ahead")
    assert result.returncode == 0 and not paths["ahead"].exists(), result.stdout
    assert (paths["dirty"] / "untracked").read_text() == "keep me"

    for index, flags in enumerate((("-ca",), ("--clean", "--all"), ("-ac",),
                                   ("-cfa",), ("--all", "--clean", "--force"), ("-fac",),
                                   ("--force", "--all", "--clean"), ("-a", "-f", "-c"))):
        name = f"all-{index}"
        create(name, tracking="ahead", via_wt=False)
        calls = trace.read_text()
        forced = any(flag == "--force" or (not flag.startswith("--") and "f" in flag) for flag in flags)
        if not forced:
            result = wt(*flags, name, input="n\n")
            assert result.returncode == 130 and paths[name].exists()
        result = wt(*flags, name, input="y\n")
        assert result.returncode == 0 and not paths[name].exists(), (flags, result.stdout, result.stderr)
        assert trace.read_text() == calls, "--all must stay offline"
        git("show-ref", "--verify", "refs/heads/" + name)

    # The shell wrapper must route combined -a flags to cleanup, not navigation.
    create("wrapped", tracking="ahead", worked=False)
    script = 'fpath=("$CLEAN_FUNCTIONS" $fpath); wt() { return 99; }; source "$CLEAN_INIT"; wt -cfa wrapped; result=$?; pwd; exit $result'
    wrapped = subprocess.run(["zsh", "-f", "-c", script], cwd=repo,
                             env=dict(env, CLEAN_FUNCTIONS=str(ROOT / "zsh/functions"), CLEAN_INIT=str(ROOT / "zsh/init.zsh")),
                             text=True, capture_output=True)
    assert wrapped.returncode == 0 and not paths["wrapped"].exists(), wrapped.stderr
    assert wrapped.stdout.splitlines()[-1] == str(repo)

    # Removed flags fail before deleting even a locally merged candidate.
    create("removed-flag")
    git("merge", "--no-ff", "removed-flag", "-m", "completed")
    for flags in (("-cm",), ("-cfm",), ("--clean", "--merged"), ("--merged=main",)):
        result = wt(*flags, input="y\n")
        assert result.returncode == 2 and paths["removed-flag"].exists(), (flags, result.stdout, result.stderr)

    # --all still protects dirty worktrees and root when cleaning the whole repo.
    result = wt("-cfa")
    assert result.returncode == 0 and repo.exists(), result.stdout
    for name in ("dirty", "prompt-dirty", "prompt-all-dirty"):
        assert paths[name].exists()
    assert not detached_unmerged.exists()
    for name in ("diverged", "new-work", "unrecorded-ahead", "open", "removed-flag", "local-ahead"):
        assert not paths[name].exists(), (name, result.stdout)
        git("show-ref", "--verify", "refs/heads/" + name)
    print("Upstream merged cleanup, ahead guards, confirmation races and offline fallback passed")
