# wt

Shell utility and [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) picker to switch between Git worktrees.

## Shell usage

```text
Usage: wt [options] [<branch> | <substring> | <path>]
       wt .
       wt -M [<oldbranch>] <newbranch>

Switch between Git worktrees. With no arguments, open an fzf picker, or list
worktrees and local branches when fzf is unavailable.

Arguments:
  <branch>                  Switch to the branch's worktree, creating it if needed.
  <substring>               Match a local branch or existing worktree directory name.
  <pr-number>               Switch to a PR's linked-issue worktree or local branch.
  <path>                    Switch to a registered worktree by absolute path.
  .                         Switch to the repo root that owns .worktrees.

Options:
  -a, --all                 With --clean, include all clean worktrees.
                            Skip merge and ahead safeguards.
  -b, --branch <branch>      Create a branch from the root HEAD and switch to it.
  -c, --clean [<target>]     Remove eligible merged worktrees after confirmation.
                            Optionally select one by branch, substring, or path.
  -d, --delete <branch>      Remove the clean worktree, then delete the branch
                            if Git considers it fully merged.
  -f, --force                With --clean, skip confirmation.
  -h, --help                 Show this help.
  -i, --interactive         With --clean, select worktrees using fzf multi-select.
  -l, --latest               Switch to the latest local branch by committer date.
  -M, --move [<old>] <new>    Rename a branch and move its worktree, if one exists.
                            <old> defaults to the current branch.
      --zsh-completion      Print the zsh completion definition.

Exact branches take priority. Otherwise, a literal, case-sensitive substring
must match exactly one branch or worktree; multiple matches are listed as an error.

Cleanup skips worktrees ahead of upstream and requires a merge into root HEAD
or a merged PR matching HEAD. --all skips these checks.
Dirty worktrees and root are always protected. Combine -c, -f, -a, and -i as needed.

Examples:
  wt feature/login          Switch to an existing branch's worktree.
  wt 123                    Switch to the worktree matching issue number 123.
  wt login                  Switch to the worktree matching login.
  wt -b feature/search      Create a branch and switch to its worktree.
  wt -M feature/find        Rename the current branch and move its worktree.
  wt -c                     Remove eligible merged worktrees after confirmation.
  wt -cf                    Do the same without confirmation.
  wt -cf 320                Clean matching worktree if it passes safeguards.
  wt -ca                    Remove all clean worktrees after confirmation.
  wt -cfa                   Remove all clean worktrees without confirmation.
  wt -ci                    Pick eligible worktrees to clean with fzf.
  wt -ciaf                  Pick from all clean worktrees; skip confirmation.
  wt -c --all login         Remove matching clean worktree after confirmation.

The zsh function changes the current shell directory. When called directly,
the executable prints the destination path for navigation commands.
```

If the argument is not an exact local branch, `wt` searches existing worktree branch names and directory names for that literal, case-sensitive substring. If none match, it searches local branches without worktrees. For example, `wt 123` can switch to `feature/123-login`, and `wt login` works too. A single match switches directly, creating a worktree if needed; multiple matches are listed as an error so you can choose a full branch name or path. Exact branches take priority, including branches whose worktrees need creating. Tab completion also supports fuzzy matching.

## Installation

Add to your `.zshrc`:

```zsh
PATH="$HOME/Developer/github.com/jasonwoodland/wt:$PATH"
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/functions")
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/completion")
autoload -Uz wt
source "$HOME/Developer/github.com/jasonwoodland/wt/zsh/init.zsh"
```

### GitHub pull requests

With `gh` installed and authenticated, listings show `[PR #456]` on the
corresponding local branch or worktree. `wt 456` first resolves an exact local
branch, then a cached PR alias, then the usual local branch or worktree substring match. When
none matches, it looks up PR #456 on GitHub. A PR prefers an
existing worktree whose branch or directory contains one of its linked issue
numbers as a complete numeric token (`123` matches `feature/123-login`, but not
`feature/1234-login`). Multiple matching worktrees are reported as ambiguous.
Only linked issues in the PR's repository are considered. Without an issue
worktree, the PR's exact local head branch is used, creating its worktree if
needed. Fork PRs require a matching linked-issue worktree; a fork head name alone
does not identify a local branch safely. Cleanup and deletion retain their local
targeting rules.

fzf and Telescope open immediately with local rows and the previous PR snapshot,
then fetch open PRs and merged PRs associated with current worktree tips and
refresh the picker. Tip lookups are deduplicated by commit and batched with the
open-PR request (up to 30 unique tips per batch), avoiding a scan of all merged
PR history. Plain listings and `wt __list`
read the snapshot without contacting GitHub. Successful snapshots are stored in
the shared Git directory, so linked worktrees share them; changing remotes or
`GH_REPO`/`GH_HOST` invalidates the snapshot. Failed refreshes preserve the previous
snapshot. PR lookup on a miss also supports closed and merged PRs. Each GitHub
request has an eight-second limit, and ordinary local navigation works without
`gh` or network access. Linked issues use GitHub's closing-issue relationships,
not arbitrary issue mentions in the PR text.

The `zsh/init.zsh` line above enables fetch-ahead: typing `wt` at the start of a
prompt launches one background refresh for that command line. Tab waits only for
any remaining fetch time, then builds the completion menu with PR labels; typing
a PR number filters to its associated branches. Without the hook, completion
fetches synchronously. There is no periodic daemon or refresh on every keystroke.
After updating `wt`, source `zsh/init.zsh` again (or open a new shell) to reload
any completion function that the current shell has already loaded.

PR labels are clickable hyperlinks in supported terminals. Zsh uses completion
rendering attributes so the URL takes no column width; fzf uses OSC 8 with
`--ansi` on fzf 0.55 or newer, and keeps plain labels on older versions.
fzf's `NO_COLOR`/`--no-color` mode also disables its hyperlink rendering.
Telescope uses Neovim URL extmarks when that API is available. Clicking uses the
terminal's usual link gesture; Enter still selects the branch or worktree.
Shell rendering detects common supporting terminals automatically. Set
`WT_HYPERLINKS=always` to enable links when detection misses your terminal, or
`WT_HYPERLINKS=never` to disable links in all three interfaces. Raw `wt __list`
rows and navigation output always stay plain. URLs come from the same PR
snapshot, with no additional GitHub requests; older snapshots gain links on
their next successful refresh.

## Telescope picker

The Telescope, fzf, and zsh completion pickers list existing worktrees and local branches as `{sha}  {branch name}  [dirty] [merged | merged upstream]  {relative worktree path}`. `[dirty]` means the worktree has tracked or untracked changes. `[merged]` means its current commit is contained in the local root worktree's `HEAD`, including worktrees at the same commit as root. Otherwise, `[merged upstream]` means GitHub reports a merged PR whose head exactly matches the worktree's current commit. This recognizes squash/rebase merges and remote merges before local root is updated. New local commits invalidate that evidence immediately. These labels describe committed work; dirty files still show `[dirty]`. `[merged]` takes priority when both checks pass; neither label appears without positive evidence. The root worktree shows `[root]` instead of a merge status, alongside `[dirty]` when applicable. Branch-only rows omit cleanliness and merge labels. The path is shown only for existing worktrees, including worktrees outside `.worktrees`; branch-only rows omit the path. Selecting a branch without a worktree creates `.worktrees/<branch>` first.

Branch rows also show upstream status: `[ahead N]` for local commits absent from the configured upstream, `[behind N]` for upstream commits absent locally, or both when histories diverge. `[no upstream]` means no tracking branch is configured; `[gone]` means the configured upstream ref is missing. Up-to-date branches show no upstream label. These labels apply to the root, linked worktrees, and branch-only rows, and compare locally cached refs without fetching or contacting the remote.

Detached worktrees appear as `{sha}  (detached)  [dirty] [merged]  {relative worktree path}` in both pickers and shell completion, with the same local merge check and no remote PR or tracking labels. Selecting one opens its existing directory without creating or attaching a branch. Completion inserts its absolute path; you can also use `wt /absolute/path/to/worktree` directly. With `branch.sort` configured, detached worktrees follow branch-attached worktrees and precede branch-only rows.

```lua
require("wt").setup({ key = "<Space>w" })
```

### Actions

| Key     | Mode              | Action                                                                                 |
| ------- | ----------------- | -------------------------------------------------------------------------------------- |
| `<CR>`  | insert/normal     | Resolve or create the selected worktree, `lcd <path>`, and `edit .`                    |
| `<C-x>` | Telescope default | Resolve or create the selected worktree, `split <path>`, and `lcd <path>`              |
| `<C-v>` | Telescope default | Resolve or create the selected worktree, `vsplit <path>`, and `lcd <path>`             |
| `<C-t>` | Telescope default | Resolve or create the selected worktree, open a tab, `lcd <path>`, and `edit .`        |
| `<Tab>` | insert            | Drill into `find_files({ cwd = path })` for the selected worktree                      |
| `<C-l>` | insert/normal     | Focus the latest local branch by committer date without switching                     |
| `<C-s>` | insert/normal     | Switch buffers and windows from the current Git root/worktree to the selected worktree |
| `<C-d>` | insert/normal     | Confirm and remove the selected existing worktree                                      |

`<C-s>` refuses to switch if any matching source-root buffers are unsaved. When it succeeds, it opens corresponding buffers under the selected worktree, preserves window views, remaps explicit window-local `:lcd` and tab-local `:tcd` directories to the same relative paths in the selected worktree, and closes the old source-root buffers. Explicit directories outside the source root, including nested `.worktrees`, are preserved; missing mapped directories fall back to the nearest existing ancestor in the target worktree.

`wt --latest` and `wt -l` switch to the local branch/worktree with the newest committer date, equivalent to selecting the first branch from `git for-each-ref --sort=-committerdate --count=1 --format='%(refname:short)' refs/heads` and resolving it through `wt <branch>`.

`<C-d>` removes the selected clean worktree. CLI cleanup with `wt -c` removes eligible merged worktrees after confirmation; `wt -cf` applies the same safeguards without confirmation. Both require clean worktrees (no untracked files or modifications in tracked files).

Default cleanup accepts either `[merged]` or `[merged upstream]`, but skips every `[ahead N]` worktree, including locally merged and diverged branches. Upstream-only cleanup requires a merged PR whose head exactly matches the worktree's current commit. Tracking comparisons use cached refs; `git fetch` can resolve a stale ahead label. Worktrees without a tracking ref may qualify through local merge or exact merged-PR evidence. Cached evidence is reused; if missing, cleanup attempts one PR refresh and preserves upstream-only candidates when confirmation of the merge is unavailable. Git refs are never fetched automatically. Root is protected and branches are retained.

Use `-a` / `--all` to include every clean worktree: `wt -ca` confirms first, while `wt -cfa` skips confirmation. This bypasses merge and ahead checks, while still protecting dirty worktrees and root and retaining all branches. This is the behavior previously provided by `wt -cf`. `--all` requires `--clean` / `-c`; the flags can be combined in any order.

Add `-i` / `--interactive` to select which eligible worktrees to clean with fzf.
`wt -ci` offers worktrees passing the default safeguards; `wt -cia` offers all
clean non-root worktrees. Tab / Shift-Tab toggle selections, Enter accepts the
marked worktrees (or the focused one when nothing is marked), and Esc cancels.
Rows show branches, PRs, statuses, and relative paths. The final confirmation
lists only the selected worktrees; `wt -cif` or `wt -ciaf` skips that confirmation.
Eligibility is rechecked before removal, including changes made while the picker
is open. Interactive cleanup requires fzf and does not fall back to cleaning
everything when it is unavailable.

Guarded cleanup checks eligibility again immediately before removal, including after the confirmation prompt. `-f` only skips confirmation. There is no merge-filter flag or revision argument; safeguards apply by default.

Cleanup eligibility depends on current Git state, regardless of how the worktree was created. Clean merged worktrees qualify even if created manually, created by an older version of `wt`, or unchanged since creation. Old `wt-start-commit` metadata is ignored.

Cleanup accepts one optional target using the same exact-branch and literal substring matching as navigation, or a registered absolute worktree path. `wt -cf 320` removes the matching worktree only if it passes the default safeguards; `wt -cfa 320` removes it if clean regardless of merge status. Both leave the branch intact. Ambiguous or missing matches fail without removing anything, branch-only targets never create a worktree, and root cannot be removed. Without a target, cleanup considers all linked worktrees. Every positional argument is a cleanup target; extra targets are rejected.

## Appendix

### Branch sorting

`wt` honors Git's `branch.sort` setting when listing worktrees and local branches. To show recently updated branches first:

```sh
git config set branch.sort -committerdate
```

Use `git config set --global branch.sort -committerdate` to apply the same sorting to all repositories.

### Command helper

```sh
command wt --help
```
