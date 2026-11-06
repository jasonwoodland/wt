#!/usr/bin/env python3
"""GitHub integration with deterministic responses; never contacts GitHub."""
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
import struct
import termios
import fcntl

ROOT = Path(__file__).resolve().parents[1]
WT = str(ROOT / "wt")
with tempfile.TemporaryDirectory(prefix="wt-github-") as temp:
    base = Path(temp).resolve()
    repo = base / "repo"
    repo.mkdir()
    bin_dir = base / "bin"
    bin_dir.mkdir()
    data = base / "prs"
    trace = base / "calls"
    data.write_text("456\tother-head\tfalse\t123\n")
    gh = bin_dir / "gh"
    gh.write_text('''#!/usr/bin/env python3
import os,sys,time
from pathlib import Path
with open(os.environ['PR_TRACE'],'a') as f: f.write(' '.join(sys.argv[1:])+'\\n')
time.sleep(float(os.environ.get('PR_DELAY','0')))
for line in Path(os.environ['PR_DATA']).read_text().splitlines():
    fields=line.split('\\t')
    if len(fields)==4:
        fields.append('https://github.com/example/repo/pull/'+fields[0])
    print('\\t'.join(fields))
sys.exit(int(os.environ.get('PR_FAIL','0')))
''')
    gh.chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}:{ROOT}:{os.environ['PATH']}",
               PR_DATA=str(data), PR_TRACE=str(trace), WT_HYPERLINKS="never",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")

    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args], env=env, stderr=subprocess.DEVNULL, text=True).strip()

    def wt(*args, **extra):
        return subprocess.run([WT, *args], cwd=repo, env=dict(env, **extra), capture_output=True, text=True, timeout=15)

    def resolved(number, path):
        result = wt(str(number))
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == str(path), result.stdout

    git("init", "-q", "-b", "main")
    git("config", "user.name", "wt test")
    git("config", "user.email", "wt@example.invalid")
    git("commit", "-q", "--allow-empty", "-m", "base")
    git("remote", "add", "origin", "https://github.com/example/repo.git")
    issue = repo / ".worktrees/feature/123-login"
    issue.parent.mkdir(parents=True)
    git("worktree", "add", "-q", "-b", "feature/123-login", str(issue))
    git("branch", "other-head")
    git("branch", "feature/1234-unrelated")
    # A normal snapshot listing stays entirely local.
    assert wt("__list").returncode == 0
    assert not trace.exists()
    # Cold lookup prefers the linked-issue worktree over a different local head.
    resolved(456, issue)
    assert "pr view 456" in trace.read_text()
    assert not (repo / ".worktrees/other-head").exists()
    assert wt("__pr_refresh").returncode == 0
    cache = repo / ".git/wt-prs"
    snapshot = cache.read_text()
    calls = trace.read_text()
    resolved(456, issue)
    listing = wt("__list").stdout
    assert "[PR #456]" in next(line for line in listing.splitlines() if line.startswith("feature/123-login\t"))
    assert trace.read_text() == calls
    assert wt("__pr_refresh", PR_FAIL="1").returncode != 0
    assert cache.read_text() == snapshot, "Partial failures must not replace a snapshot"

    # Exact numeric branches still win.
    git("branch", "456")
    resolved(456, repo / ".worktrees/456")
    git("worktree", "remove", str(repo / ".worktrees/456"))
    git("branch", "-D", "456")
    # Fork heads can still resolve through an issue worktree.
    data.write_text("457\tother-head\ttrue\t123\n")
    resolved(457, issue)
    data.write_text("458\tother-head\ttrue\t\n")
    assert wt("458").returncode != 0
    # No issue worktree: use a local head, without matching issue 1234.
    data.write_text("459\tother-head\tfalse\t12\n")
    resolved(459, repo / ".worktrees/other-head")
    # Multiple issue worktrees fail before creating or switching anything.
    other = repo / ".worktrees/feature/123-second"
    git("worktree", "add", "-q", "-b", "feature/123-second", str(other))
    data.write_text("460\tother-head\tfalse\t123\n")
    ambiguous = wt("460")
    assert ambiguous.returncode != 0 and "multiple linked-issue" in ambiguous.stderr
    # Deleted worktree registrations cannot hide the usable linked worktree.
    shutil.rmtree(other)
    resolved(460, issue)
    # Changing the repository invalidates the old snapshot.
    git("remote", "set-url", "origin", "https://github.com/example/another.git")
    assert "[PR #456]" not in wt("__list").stdout
    data.write_text("456\tother-head\tfalse\t123\n")

    # Completion can synchronously enrich rows and filter by PR number.
    script = '''
compdef() { :; }
compadd() { print -rl -- "${filtered_values[@]}"; }
eval "$(command wt --zsh-completion)"
words=(wt 456); CURRENT=2
_wt
'''
    completed = subprocess.check_output(["zsh", "-f", "-c", script], cwd=repo, env=env, text=True)
    assert completed.strip() == "feature/123-login", completed

    label_script = script.replace('print -rl -- "${filtered_values[@]}"',
                                  'print -rl -- "${labels[@]}"').replace('words=(wt 456)', 'words=(wt "")')
    labels = subprocess.check_output(["zsh", "-f", "-c", label_script], cwd=repo, env=env, text=True).splitlines()
    assert any("[PR #456]" in label for label in labels)
    path_columns = []
    for relative in (".", ".worktrees/feature/123-login", ".worktrees/other-head"):
        label = next(label for label in labels if label.endswith(" " + relative))
        path_columns.append(len(label) - len(relative))
    assert len(set(path_columns)) == 1, "Completion paths must align after long status and PR labels"
    linked_labels = subprocess.check_output(["zsh", "-f", "-c", label_script], cwd=repo,
                                            env=dict(env, WT_HYPERLINKS="always"), text=True)
    link_start = "\x1b]8;;https://github.com/example/repo/pull/456\x1b\\"
    link_end = "\x1b]8;;\x1b\\"
    assert linked_labels.splitlines() == labels, "Descriptions must stay plain for ZLE width calculations"
    assert "\x1b" not in wt("__list", WT_HYPERLINKS="always").stdout, "Raw rows must remain plain"

    # Actual ZLE hooks: type wt without Return, wait, then consume the same job.
    trace.write_text("")
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(repo)
        os.execvpe("zsh", ["zsh", "-f"], dict(env, TERM="xterm-256color", PR_DELAY="0.3", WT_HYPERLINKS="always"))

    def drain():
        result = b""
        while select.select([fd], [], [], 0.05)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                if result:
                    break
                raise
            if not chunk:
                if result:
                    break
                raise OSError("PTY closed")
            if b"\x1b[6n" in chunk:
                os.write(fd, b"\x1b[1;1R")
            result += chunk
        return result

    try:
        time.sleep(0.2)
        drain()
        # Simulate an already loaded completion from before the update. Sourcing
        # setup must replace it, and actual Tab completion must show PR labels.
        setup = (f"fpath=('{ROOT}/zsh/completion' $fpath); "
                 "autoload -Uz compinit; compinit -D; "
                 "_wt() { compadd obsolete-completion; }; compdef _wt wt; "
                 "zstyle ':completion:*' menu select; "
                 f"source '{ROOT}/zsh/init.zsh'\r")
        os.write(fd, setup.encode())
        time.sleep(0.5)
        drain()
        os.write(fd, b"wt ")
        deadline = time.monotonic() + 3
        while not trace.read_text() and time.monotonic() < deadline:
            time.sleep(0.05)
            drain()
        assert "api graphql" in trace.read_text(), "Typing wt must prefetch before Return"
        os.write(fd, b"\t\t")
        screen = b""
        deadline = time.monotonic() + 4
        while b"PR #456" not in screen and time.monotonic() < deadline:
            screen += drain()
        assert b"PR #456" in screen, screen[-2000:]
        assert link_start.encode() in screen, repr(screen[-4000:])
        assert b"obsolete-completion" not in screen
        # Both Tab invocations must reuse the prefetch on this command line.
        assert trace.read_text().count("api graphql") == 1
    finally:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        os.close(fd)

    # Exercise the installed fzf, not a mock: PRs appear after the picker opens.
    if os.environ.get("WT_TEST_FZF"):
        (bin_dir / "fzf").symlink_to(os.environ["WT_TEST_FZF"])
    if shutil.which("fzf", path=env["PATH"]):
        version = subprocess.check_output(["fzf", "--version"], env=env, text=True).split()[0]
        supports_links = tuple(map(int, version.split(".")[:2])) >= (0, 55)
        cache.unlink(missing_ok=True)
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(repo)
            fzf_env = dict(env, TERM="xterm-256color", PR_DELAY="0.3", WT_HYPERLINKS="always",
                           FZF_DEFAULT_OPTS="--no-height --no-clear --no-mouse")
            # fzf disables its ANSI rendering layer when NO_COLOR is set.
            fzf_env.pop("NO_COLOR", None)
            os.execve(WT, [WT], fzf_env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 140, 0, 0))
        try:
            screen = b""
            deadline = time.monotonic() + 5
            while b"PR #456" not in screen and time.monotonic() < deadline:
                screen += drain()
            assert b"PR #456" in screen, screen[-2000:]
            assert (link_start.encode() in screen) == supports_links, "fzf hyperlink version fallback failed"
            os.write(fd, b"456")
            time.sleep(0.2)
            drain()
            os.write(fd, b"\r")
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    screen += drain()
                except OSError:
                    break
            assert str(issue).encode() in screen, screen[-2000:]
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
            os.close(fd)

    # Real Telescope: async refresh preserves query and branch selection.
    plugins = Path.home() / ".local/share/nvim/lazy"
    if shutil.which("nvim") and (plugins / "telescope.nvim").exists() and (plugins / "plenary.nvim").exists():
        cache.unlink(missing_ok=True)
        lua = base / "telescope.lua"
        lua.write_text('''
vim.opt.rtp:append(vim.env.WT_SOURCE)
vim.opt.rtp:append(vim.env.WT_PLUGINS .. '/plenary.nvim')
vim.opt.rtp:append(vim.env.WT_PLUGINS .. '/telescope.nvim')
require('wt').pick({})
local state = require('telescope.actions.state')
local picker = state.get_current_picker(vim.api.nvim_get_current_buf())
picker:set_prompt('login')
assert(vim.wait(3000, function()
  local entry = picker:get_selection()
  return entry and entry.value.branch == 'feature/123-login'
end, 20), 'initial selection missing')
assert(vim.wait(5000, function()
  local entry = picker:get_selection()
  return entry and entry.value.prs:find('PR #456', 1, true) ~= nil
end, 20), 'PR metadata did not refresh')
assert(picker:_get_prompt() == 'login', 'refresh reset query')
assert(picker:get_selection().value.branch == 'feature/123-login', 'refresh changed branch')
local ns = vim.api.nvim_get_namespaces().wt_pr_links
local function link_marks()
  return vim.api.nvim_buf_get_extmarks(picker.results_bufnr, ns, 0, -1, { details = true })
end
assert(vim.wait(1000, function() return #link_marks() > 0 end, 20), 'URL extmark missing')
assert(link_marks()[1][4].url == 'https://github.com/example/repo/pull/456', 'wrong URL')
local rendered = table.concat(vim.api.nvim_buf_get_lines(picker.results_bufnr, 0, -1, false), '\\n')
assert(not rendered:find(string.char(27), 1, true), 'raw escape in results buffer')
picker:set_prompt('main')
assert(vim.wait(1000, function() return #link_marks() == 0 end, 20), 'stale URL after filtering')
require('telescope.actions').close(picker.prompt_bufnr)
-- Closing before the next request finishes must be safe too.
require('wt').pick({})
local next_picker = state.get_current_picker(vim.api.nvim_get_current_buf())
require('telescope.actions').close(next_picker.prompt_bufnr)
vim.wait(500, function() return false end, 20)
print('real Telescope async refresh passed')
''')
        result = subprocess.run(["nvim", "--headless", "-u", "NONE", "-c", f"lua dofile('{lua}')", "-c", "qa!"],
                                cwd=repo, env=dict(env, PR_DELAY="0.3", WT_SOURCE=str(ROOT), WT_PLUGINS=str(plugins), WT_HYPERLINKS="always"),
                                capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        assert "real Telescope async refresh passed" in output, (result.returncode, output)
        assert "Error" not in output, output

    # A failed GitHub lookup preserves existing numeric issue navigation.
    calls = trace.read_text()
    assert wt("123", PR_FAIL="1").stdout.strip() == str(issue)
    assert calls == trace.read_text(), "Local issue navigation must not start gh"
    snapshot = cache.read_text()
    start = time.monotonic()
    assert wt("__pr_refresh", PR_DELAY="12").returncode != 0
    assert time.monotonic() - start < 10, "A stalled gh must be bounded"
    assert cache.read_text() == snapshot
    assert not list(cache.parent.glob("wt-prs.*")), "Failed refresh left temporary files"

    # A row may link several PRs; disabling links preserves exactly the text
    # and column layout. Old snapshots still work until their next refresh.
    data.write_text("456\tother-head\tfalse\t123\n457\tother-head\tfalse\t123\n")
    linked = wt("__pr_fzf", "1").stdout
    plain = wt("__pr_fzf", "0").stdout
    for number in (456, 457):
        opening = f"\x1b]8;;https://github.com/example/repo/pull/{number}\x1b\\"
        assert opening + f"[PR #{number}]" + link_end in linked
        linked = linked.replace(opening, "")
    assert linked.replace(link_end, "") == plain
    raw = wt("__list").stdout
    assert "\x1b" not in raw
    assert wt("__pr_refresh").returncode == 0
    header = cache.read_text().splitlines()[0]
    cache.write_text(header + "\n456\tother-head\tfalse\t123\n")
    legacy = wt("__pr_fzf", "1", PR_FAIL="1").stdout
    assert "[PR #456]" in legacy and "\x1b" not in legacy
    resolved(456, issue)
    # Never render control characters from a malformed cached URL.
    data.write_text("456\tother-head\tfalse\t123\thttps://example.com/pull/456\x1bBAD\n")
    malformed = wt("__pr_fzf", "1").stdout
    assert "[PR #456]" in malformed and "\x1b" not in malformed
    print("PR aliases, cache failures/timeout, OSC 8 links, ZLE, real fzf and Telescope refresh passed")
