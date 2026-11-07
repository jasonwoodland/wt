#!/usr/bin/env python3
"""Interactive cleanup selects only eligible worktrees and rechecks changes."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
WT = str(ROOT / "wt")
REAL_FZF = shutil.which("fzf")
with tempfile.TemporaryDirectory(prefix="wt-interactive-clean-") as temporary:
    base = Path(temporary).resolve()
    repo, bin_dir = base / "repo", base / "bin"
    repo.mkdir()
    bin_dir.mkdir()
    capture, metadata = base / "picker.json", base / "prs"
    metadata.write_text("")
    gh = bin_dir / "gh"
    gh.write_text('#!/bin/sh\ncat "$PICK_PRS"\n')
    gh.chmod(0o755)
    fake_fzf = bin_dir / "fzf"
    fake_fzf.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
from pathlib import Path
lines=sys.stdin.read().splitlines()
Path(os.environ['PICK_CAPTURE']).write_text(json.dumps(dict(args=sys.argv[1:],rows=lines)))
mode=os.environ.get('PICK_MODE','select')
if mode=='cancel': sys.exit(130)
if mode=='empty': sys.exit(0)
if mode=='invalid': print('clean-99999999'); sys.exit(0)
if mode=='root': print('_root'); sys.exit(0)
path=os.environ.get('PICK_CHANGE_PATH')
if mode=='dirty': Path(path,'changed-in-picker').write_text('keep me')
if mode=='commit': subprocess.check_call(['git','-C',path,'commit','-q','--allow-empty','-m','new work'])
if mode=='ahead': subprocess.check_call(['git','-C',path,'update-ref','refs/remotes/origin/'+os.environ.get('PICK_CHANGE_BRANCH','remote'),os.environ['PICK_INITIAL']])
names=json.loads(os.environ['PICK_NAMES'])
for line in lines:
    if line.split('\\t',1)[1].split()[1] in names:
        print(line)
        if mode=='duplicate': print(line)
''')
    fake_fzf.chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}:{ROOT}:{os.environ['PATH']}",
               PICK_CAPTURE=str(capture), PICK_PRS=str(metadata), WT_HYPERLINKS="never",
               PICK_NAMES=json.dumps(["eligible-one", "eligible-two"]),
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")

    def git(*args, cwd=None):
        return subprocess.check_output(["git", "-C", str(cwd or repo), *args], env=env,
                                       text=True, stderr=subprocess.DEVNULL).strip()

    def wt(*args, input=None, **extra):
        return subprocess.run([WT, *args], cwd=repo, env=dict(env, **extra), input=input,
                              text=True, capture_output=True, timeout=15)

    git("init", "-q", "-b", "main")
    git("config", "user.name", "wt test")
    git("config", "user.email", "wt@example.invalid")
    git("commit", "-q", "--allow-empty", "-m", "base")
    git("remote", "add", "origin", "https://github.com/example/repo.git")
    initial = git("rev-parse", "HEAD")
    env["PICK_INITIAL"] = initial
    paths = {}

    def create(name, merged=False, worked=True):
        result = wt("-b", name)
        assert result.returncode == 0, result.stderr
        path = paths[name] = repo / ".worktrees" / name
        if worked:
            git("commit", "-q", "--allow-empty", "-m", name, cwd=path)
        if merged:
            git("merge", "--no-ff", name, "-m", f"merge {name}")
        return path

    create("eligible-one", merged=True)
    create("eligible-two", merged=True)
    external = base / "external worktree"
    git("worktree", "move", str(paths["eligible-two"]), str(external))
    paths["eligible-two"] = external
    create("remote")
    remote_head = git("rev-parse", "HEAD", cwd=paths["remote"])
    git("update-ref", "refs/remotes/origin/remote", remote_head)
    git("config", "branch.remote.remote", "origin")
    git("config", "branch.remote.merge", "refs/heads/remote")
    metadata.write_text(f"456\tremote\tfalse\t\thttps://github.com/example/repo/pull/456\tMERGED\t{remote_head}\n")
    assert wt("__pr_refresh").returncode == 0
    create("unmerged")
    create("untouched", worked=False)
    create("dirty", merged=True)
    (paths["dirty"] / "untracked").write_text("keep me")
    git("branch", "branch-only")
    unrecorded = repo / ".worktrees/unrecorded"
    git("worktree", "add", "-q", "-b", "unrecorded", str(unrecorded))
    create("local-ahead", merged=True)
    git("update-ref", "refs/remotes/origin/local-ahead", initial)
    git("config", "branch.local-ahead.remote", "origin")
    git("config", "branch.local-ahead.merge", "refs/heads/local-ahead")

    for mode in ("cancel", "empty", "invalid", "root"):
        result = wt("-cif", PICK_MODE=mode)
        assert result.returncode != 0 and all(path.exists() for path in paths.values()), result.stdout
    result = wt("-ci", input="n\n")
    assert result.returncode == 130 and all(path.exists() for path in paths.values()), result.stdout
    assert "Remove 2 clean merged" in result.stdout
    assert ".worktrees/remote" not in result.stdout
    offered = json.loads(capture.read_text())
    assert "--multi" in offered["args"]
    labels = [row.split("\t", 1)[1] for row in offered["rows"]]
    assert len(labels) == 5, labels
    assert any("[merged upstream]" in row and "[PR #456]" in row for row in labels)
    assert any("../external worktree" in row for row in labels)
    assert all(row.startswith("clean-") for row in offered["rows"])
    assert any("untouched" in row and "[merged]" in row for row in labels)
    assert any("unrecorded" in row and "[merged]" in row for row in labels)
    assert not any("dirty" in row or "unmerged" in row or "branch-only" in row or "local-ahead" in row for row in labels)

    # Multiple selections preserve spaces and leave every unselected path alone.
    result = wt("--interactive", "--clean", "--force", PICK_MODE="duplicate")
    assert result.returncode == 0, result.stderr
    for name in ("eligible-one", "eligible-two"):
        assert not paths[name].exists()
        git("show-ref", "--verify", "refs/heads/" + name)
    assert paths["remote"].exists() and paths["unmerged"].exists()

    # Changes made while selecting must invalidate guarded cleanup, even with -f.
    for name, mode in (("changing-commit", "commit"), ("changing-dirty", "dirty")):
        create(name, merged=True)
        result = wt("-cif", name, PICK_MODE=mode, PICK_NAMES=json.dumps([name]), PICK_CHANGE_PATH=str(paths[name]))
        assert result.returncode == 0 and paths[name].exists(), (result.stdout, result.stderr)
        assert "no longer eligible" in result.stdout
    result = wt("-cif", "remote", PICK_MODE="ahead", PICK_NAMES='["remote"]', PICK_CHANGE_PATH=str(repo))
    assert result.returncode == 0 and paths["remote"].exists(), result.stdout
    assert "no longer eligible" in result.stdout
    # Local merge evidence must not bypass an ahead change while selecting.
    create("changing-local-ahead", merged=True)
    git("update-ref", "refs/remotes/origin/changing-local-ahead", git("rev-parse", "changing-local-ahead"))
    git("config", "branch.changing-local-ahead.remote", "origin")
    git("config", "branch.changing-local-ahead.merge", "refs/heads/changing-local-ahead")
    result = wt("-cif", "changing-local-ahead", PICK_MODE="ahead", PICK_NAMES='["changing-local-ahead"]',
                PICK_CHANGE_PATH=str(repo), PICK_CHANGE_BRANCH="changing-local-ahead")
    assert result.returncode == 0 and paths["changing-local-ahead"].exists(), result.stdout
    assert "no longer eligible" in result.stdout

    # --all broadens the picker, but still excludes root/dirty/branch-only rows.
    detached = repo / ".worktrees/detached with spaces"
    git("worktree", "add", "-q", "--detach", str(detached))
    result = wt("-ciaf", PICK_NAMES='["unmerged","untouched","unrecorded","local-ahead","(detached)"]')
    assert result.returncode == 0, result.stderr
    assert not paths["unmerged"].exists() and not paths["untouched"].exists()
    assert not unrecorded.exists() and not detached.exists()
    assert not paths["local-ahead"].exists()
    assert paths["dirty"].exists() and repo.exists() and paths["remote"].exists()

    # Missing fzf fails before considering worktrees; there is no mass cleanup fallback.
    minimal = base / "minimal-bin"
    minimal.mkdir()
    for name in ("bash", "dirname"):
        (minimal / name).symlink_to(shutil.which(name))
    result = wt("-ciaf", PATH=str(minimal))
    assert result.returncode != 0 and "requires fzf" in result.stderr
    assert paths["remote"].exists()

    # Exercise real fzf's Tab/Tab/Enter multi-select and output parsing in a PTY.
    if REAL_FZF:
        create("real-one", merged=True)
        create("real-two", merged=True)
        real_bin = base / "real-bin"
        real_bin.mkdir()
        (real_bin / "fzf").symlink_to(REAL_FZF)
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(repo)
            os.execve(WT, [WT, "-cif"], dict(env, PATH=f"{real_bin}:{env['PATH']}",
                                          TERM="xterm-256color", FZF_DEFAULT_OPTS="--style=minimal --no-clear --no-mouse"))
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 140, 0, 0))
        try:
            screen = b""
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and b"real-two" not in screen:
                if select.select([fd], [], [], 0.05)[0]:
                    chunk = os.read(fd, 65536)
                    screen += chunk
                    if b"\x1b[6n" in chunk:
                        os.write(fd, b"\x1b[1;1R")
            assert b"real-one" in screen and b"real-two" in screen, screen[-1500:]
            os.write(fd, b"'real-")
            time.sleep(0.15)
            os.write(fd, b"\t")
            time.sleep(0.1)
            os.write(fd, b"\t\r")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and (paths["real-one"].exists() or paths["real-two"].exists()):
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        screen += os.read(fd, 65536)
                    except OSError:
                        break
            assert not paths["real-one"].exists() and not paths["real-two"].exists(), screen[-6000:]
            # Let the shell finish reporting removals before closing its terminal.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if os.waitpid(pid, os.WNOHANG)[0]:
                    pid = None
                    break
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        screen += os.read(fd, 65536)
                    except OSError:
                        break
        finally:
            os.close(fd)
            if pid is not None:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
    print("Interactive cleanup eligibility, multi-select, cancellation and revalidation passed")
