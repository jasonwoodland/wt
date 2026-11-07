#!/usr/bin/env python3
"""Exercise merge labels with real gh JSON projection against a local server."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
REAL_GH = shutil.which("gh")
if not REAL_GH:
    raise SystemExit("merge label integration test requires gh")

with tempfile.TemporaryDirectory(prefix="wt-merge-labels-") as temporary:
    base = Path(temporary).resolve()
    repo = base / "repo"
    repo.mkdir()
    fixture, trace = base / "response.json", base / "calls.jsonl"
    pr_fixture = base / "pr.json"

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = (pr_fixture if self.path == "/pr" else fixture).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    bin_dir = base / "bin"
    bin_dir.mkdir()
    gh = bin_dir / "gh"
    gh.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['MERGE_TRACE'],'a') as f: f.write(json.dumps(args)+'\\n')
projection=args[args.index('--jq')+1]
endpoint=os.environ['MERGE_ENDPOINT']+('/pr' if args[0]=='pr' else '/')
env=dict(os.environ,GH_TOKEN='test',GITHUB_TOKEN='',GH_HOST='github.com')
sys.exit(subprocess.call([os.environ['MERGE_REAL_GH'],'api',endpoint,'--jq',projection],env=env))
''')
    gh.chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}:{ROOT}:{os.environ['PATH']}",
               MERGE_TRACE=str(trace), MERGE_REAL_GH=REAL_GH,
               MERGE_ENDPOINT=f"http://127.0.0.1:{server.server_port}",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", WT_HYPERLINKS="never")

    def git(*args, input=None):
        return subprocess.check_output(["git", "-C", str(repo), *args], env=env,
                                       input=input, text=True, stderr=subprocess.DEVNULL).strip()

    def wt(*args):
        return subprocess.check_output([str(ROOT / "wt"), *args], env=env, cwd=repo, text=True)

    def rows():
        return {row[0]: row for row in (line.split("\t") for line in wt("__list").splitlines())}

    try:
        git("init", "-q", "-b", "main")
        git("config", "user.name", "wt test")
        git("config", "user.email", "wt@example.invalid")
        git("commit", "-q", "--allow-empty", "-m", "base")
        git("remote", "add", "origin", "https://github.com/example/repo.git")
        initial = git("rev-parse", "HEAD")
        tree = git("rev-parse", "HEAD^{tree}")
        heads = {"local-merged": initial}
        for branch in ("feature/123-topic", "feature/124-topic", "open-topic"):
            heads[branch] = git("commit-tree", tree, "-p", initial, input=branch)
        for branch, sha in heads.items():
            path = repo / ".worktrees" / branch
            path.parent.mkdir(parents=True, exist_ok=True)
            git("worktree", "add", "-q", "-b", branch, str(path), sha)

        def pr(number, head, state, branch="remote-head"):
            return dict(number=number, headRefOid=head, state=state, headRefName=branch,
                        isCrossRepository=False, url=f"https://github.com/example/repo/pull/{number}")

        merged = pr(456, heads["feature/123-topic"], "MERGED")
        rebased = pr(457, heads["feature/124-topic"], "MERGED")
        opened = pr(458, heads["open-topic"], "OPEN", "open-topic")
        opened["closingIssuesReferences"] = {"nodes": [], "pageInfo": {"hasNextPage": False}}
        response = {"pullRequests": {"nodes": [opened]}}
        for index, record in enumerate((merged, rebased, pr(459, heads["open-topic"], "CLOSED"))):
            response[f"tip{index}"] = dict(oid=record["headRefOid"],
                                           associatedPullRequests={"nodes": [record, record]})
        fixture.write_text(json.dumps({"data": {"repository": response}}))
        pr_fixture.write_text(json.dumps(dict(merged, closingIssuesReferences=[
            {"number": 123, "url": "https://github.com/example/repo/issues/123"}])))
        wt("__pr_refresh")
        calls = trace.read_text()
        request = json.loads(calls.splitlines()[0])
        query = next(arg[6:] for arg in request if arg.startswith("query="))
        assert query.count("associatedPullRequests(first: 100)") == len(set(heads.values()))
        assert all(sha in query for sha in heads.values())
        assert len(calls.splitlines()) == 1, "Tip lookups must be batched"
        cached = rows()
        assert cached["local-merged"][7] == "1"
        assert cached["feature/123-topic"][7] == "0"
        assert cached["feature/123-topic"][11] == "1"
        assert cached["feature/124-topic"][11] == "1"
        assert cached["open-topic"][11] == ""
        assert cached["feature/123-topic"][9] == "[PR #456]", "Duplicate associations must collapse"
        assert trace.read_text() == calls, "Listings must not call GitHub"

        # A merged tip record still navigates through the PR's linked issue.
        assert wt("456").strip() == str(repo / ".worktrees/feature/123-topic")

        capture = base / "fzf-rows"
        fzf = bin_dir / "fzf"
        fzf.write_text('#!/bin/sh\ncat > "$MERGE_CAPTURE"\nexit 130\n')
        fzf.chmod(0o755)
        subprocess.run([str(ROOT / "wt")], cwd=repo, env=dict(env, MERGE_CAPTURE=str(capture)),
                       capture_output=True)
        picker = dict(line.split("\t", 1) for line in capture.read_text().splitlines())
        script = '''
compdef() { :; }
compadd() { local i; for ((i=1; i<=${#values}; i++)); do
  print -r -- "${values[i]}"$'\\t'"${labels[i]}"
done; }
eval "$(command wt --zsh-completion)"
words=(wt ""); CURRENT=2; _wt
'''
        completed = subprocess.check_output(["zsh", "-f", "-c", script], cwd=repo, env=env, text=True)
        completion = dict(line.split("\t", 1) for line in completed.splitlines())
        for display in (picker, completion):
            assert "[merged]" in display["local-merged"]
            for branch in ("feature/123-topic", "feature/124-topic"):
                assert "[merged upstream]" in display[branch]
                assert "[merged]" not in display[branch]
            assert "[merged" not in display["open-topic"]
            assert "[root]" in display["main"] and "[merged" not in display["main"]
            assert "[unmerged]" not in " ".join(display.values())

        plugins = Path.home() / ".local/share/nvim/lazy"
        if shutil.which("nvim") and (plugins / "telescope.nvim").exists() and (plugins / "plenary.nvim").exists():
            lua = base / "merge-labels.lua"
            lua.write_text('''
vim.opt.rtp:append(vim.env.MERGE_SOURCE)
vim.opt.rtp:append(vim.env.MERGE_PLUGINS .. '/plenary.nvim')
vim.opt.rtp:append(vim.env.MERGE_PLUGINS .. '/telescope.nvim')
require('wt').pick({})
local state = require('telescope.actions.state')
local picker = state.get_current_picker(vim.api.nvim_get_current_buf())
picker:set_prompt('123-topic')
assert(vim.wait(3000, function()
  local entry = picker:get_selection()
  return entry and entry.value.branch == 'feature/123-topic' and entry.value.merged_upstream
end, 20), 'remote merge evidence missing')
assert(picker:get_selection():display():find('[merged upstream]', 1, true), 'remote label missing')
picker:set_prompt('local-merged')
assert(vim.wait(1000, function()
  local entry = picker:get_selection()
  return entry and entry.value.branch == 'local-merged'
end, 20), 'local selection missing')
assert(picker:get_selection():display():find('[merged]', 1, true), 'local label missing')
require('telescope.actions').close(picker.prompt_bufnr)
print('Telescope merge labels passed')
''')
            result = subprocess.run(["nvim", "--headless", "-u", "NONE", "-c", f"lua dofile('{lua}')", "-c", "qa!"],
                                    cwd=repo, env=dict(env, MERGE_SOURCE=str(ROOT), MERGE_PLUGINS=str(plugins)),
                                    text=True, capture_output=True, timeout=10)
            output = result.stdout + result.stderr
            assert "Telescope merge labels passed" in output and "Error" not in output, output

        # New local commits invalidate cached remote-merged evidence immediately.
        newer = git("commit-tree", tree, "-p", heads["feature/123-topic"], input="new work")
        git("update-ref", "refs/heads/feature/123-topic", newer)
        calls = trace.read_text()
        assert rows()["feature/123-topic"][11] == ""
        assert trace.read_text() == calls
        # Local containment takes priority over remote PR evidence.
        git("update-ref", "HEAD", heads["feature/124-topic"])
        subprocess.run([str(ROOT / "wt")], cwd=repo, env=dict(env, MERGE_CAPTURE=str(capture)),
                       capture_output=True)
        label = next(line for line in capture.read_text().splitlines() if line.startswith("feature/124-topic\t"))
        assert "[merged]" in label and "[merged upstream]" not in label

        # Many worktrees produce bounded batches, never one gh call per branch.
        for i in range(31):
            sha = git("commit-tree", tree, "-p", initial, input=f"batch {i}")
            path = repo / ".worktrees/batch" / str(i)
            path.parent.mkdir(parents=True, exist_ok=True)
            git("worktree", "add", "-q", "-b", f"batch/{i}", str(path), sha)
        previous = len(trace.read_text().splitlines())
        wt("__pr_refresh")
        requests = [json.loads(line) for line in trace.read_text().splitlines()[previous:]]
        assert len(requests) == 2
        for request in requests:
            query = next(arg[6:] for arg in request if arg.startswith("query="))
            assert query.count("associatedPullRequests(first: 100)") <= 30
        numbers = [line.split("\t")[0] for line in (repo / ".git/wt-prs").read_text().splitlines()[1:]]
        assert len(numbers) == len(set(numbers)), "Repeated open pages must not duplicate PRs"
        print("Positive merge labels, real gh projection, batched lookup and post-merge commits passed")
    finally:
        server.shutdown()
        server.server_close()
