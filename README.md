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
  <substring>               Match an existing worktree branch or directory name.
  <path>                    Switch to a registered worktree by absolute path.
  .                         Switch to the repo root that owns .worktrees.

Options:
  -b, --branch <branch>      Create a branch from the root HEAD and switch to it.
  -c, --clean [<target>]     Remove clean non-main worktrees after confirmation.
                            Optionally select one by branch, substring, or path.
  -d, --delete <branch>      Remove the clean worktree, then delete the branch
                            if Git considers it fully merged.
  -f, --force                With --clean, skip confirmation.
  -h, --help                 Show this help.
  -l, --latest               Switch to the latest local branch by committer date.
  -m, --merged [<rev>]       With --clean, only remove worktrees merged into <rev>.
                            Requires commits since creation by wt.
                            Defaults to the root worktree HEAD.
  -M, --move [<old>] <new>    Rename a branch and move its worktree, if one exists.
                            <old> defaults to the current branch.
      --zsh-completion      Print the zsh completion definition.

Exact branches take priority. Otherwise, a literal, case-sensitive substring
must match exactly one existing worktree; multiple matches are listed as an error.

Cleanup never removes dirty worktrees, even with --force. The short cleanup
options -c, -f, and -m can be combined.

Examples:
  wt feature/login          Switch to an existing branch's worktree.
  wt 123                    Switch to the worktree matching issue number 123.
  wt login                  Switch to the worktree matching login.
  wt -b feature/search      Create a branch and switch to its worktree.
  wt -M feature/find        Rename the current branch and move its worktree.
  wt -cm                    Remove clean worktrees merged into the root HEAD.
  wt -cf 320                Remove the clean worktree matching 320.
  wt -cm main 320           Remove matching worktree if merged into main.
  wt -cm -- 320             Use root HEAD as the merge reference for matching 320.
  wt -cfm                   Do the same without confirmation.
  wt -c --merged main       Remove clean worktrees merged into main.

The zsh function changes the current shell directory. When called directly,
the executable prints the destination path for navigation commands.
```

If the argument is not an exact local branch, `wt` searches existing worktree branch names and directory names for that literal, case-sensitive substring. For example, `wt 123` can switch to `feature/123-login`, and `wt login` works too. A single match switches directly; multiple matches are listed as an error so you can choose a full branch name or path. Exact branches take priority, including branches whose worktrees need creating. Tab completion also supports fuzzy matching.

## Installation

Add to your `.zshrc`:

```zsh
PATH="$HOME/Developer/github.com/jasonwoodland/wt:$PATH"
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/functions")
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/completion")
autoload -Uz wt
```

## Telescope picker

The Telescope, fzf, and zsh completion pickers list existing worktrees and local branches as `{sha}  {branch name}  [dirty] [unmerged]  {relative worktree path}`. `[dirty]` means the worktree has tracked or untracked changes; `[unmerged]` means a linked worktree has commits that are not reachable from the root worktree's `HEAD`. Clean worktrees with no commits ahead of root show neither label, including branches at the same commit as root or already merged into it. The root worktree shows `[root]` instead of a merge status, alongside `[dirty]` when applicable. Status columns are blank for branch-only rows. The path is shown only for existing worktrees, including worktrees outside `.worktrees`; branch-only rows omit the path. Selecting a branch without a worktree creates `.worktrees/<branch>` first.

Detached worktrees appear as `{sha}  (detached)  [dirty] [unmerged]  {relative worktree path}` in both pickers and shell completion, with the same status rules. Selecting one opens its existing directory without creating or attaching a branch. Completion inserts its absolute path; you can also use `wt /absolute/path/to/worktree` directly. With `branch.sort` configured, detached worktrees follow branch-attached worktrees and precede branch-only rows.

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

`<C-d>` and `wt --clean` only remove clean worktrees (no untracked files and no modification in tracked files). Add `--merged [<rev>]` or `-m` with `wt -c` to remove only clean worktrees whose `HEAD` is merged into `<rev>` and which have commits since their creation by `wt`; when `<rev>` is omitted, the root worktree `HEAD` is used. `wt` records the initial commit in the worktree's private Git metadata when creating it. Untouched worktrees and existing worktrees without that record are preserved by merged cleanup, even if root has advanced past them. Moving a worktree preserves the record; recreating one starts a new record. Commits already present when `wt` creates a worktree do not count as work done in that worktree. If the recorded commit is no longer available, merged cleanup preserves the worktree. The `[unmerged]` listing label still describes commits missing from root independently of this creation record. `wt -cf` removes all clean linked worktrees regardless of the record. `wt -cf` and `wt -cfm` skip confirmation but still do not force dirty worktree removal.

Cleanup accepts one optional target using the same exact-branch and literal substring matching as navigation, or a registered absolute worktree path. For example, `wt -cf 320` removes only the clean worktree matching `320`; it leaves the branch intact. Ambiguous or missing matches fail without removing anything, branch-only targets never create a worktree, and root cannot be removed. Without a target, cleanup considers all linked worktrees. With merged cleanup, the argument immediately following `-m`, `--merged`, or a combined flag containing `m` is the merge reference: `wt -cm main 320` targets `320` against `main`, and `wt -cm main` considers all linked worktrees against `main`. Use `wt -cm -- 320` to target `320` against root HEAD, or `wt -cf --merged=main 320` to specify the reference explicitly. Targeted cleanup retains the same cleanliness and recorded-commit requirements.

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
