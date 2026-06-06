# wt

Shell utility and [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) picker to switch between Git worktrees.

## Shell usage

```sh
wt              # open the interactive picker when fzf is available
wt .            # cd to the repo root that owns .worktrees
wt -            # legacy alias for wt .
wt <branch>     # cd to the branch's existing worktree, or create .worktrees/<branch>
wt --latest     # cd to the local branch/worktree with the newest committer date
wt -l           # shorthand for wt --latest
wt --clean      # remove clean non-main worktrees after confirmation
wt -c --merged  # remove clean non-main worktrees merged into the root worktree HEAD
wt -cm          # shorthand for wt -c --merged
wt -cfm         # remove clean merged non-main worktrees without confirmation
wt -cf          # remove clean non-main worktrees without confirmation
```

## Installation

Add to your `.zshrc`:

```zsh
PATH="$HOME/Developer/github.com/jasonwoodland/wt:$PATH"
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/functions")
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/completion")
autoload -Uz wt
```

## Telescope picker

The worktree picker lists existing worktrees and local branches as `{sha}  {branch name}  {relative worktree path}`. The path is shown only for existing worktrees, including worktrees outside `.worktrees`; branch-only rows omit the path. Selecting a branch without a worktree creates `.worktrees/<branch>` first.

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

`<C-d>` and `wt --clean` only remove clean worktrees (no untracked files and no modification in tracked files). Add `--merged [<rev>]` or `-m` with `wt -c` to remove only clean worktrees whose `HEAD` is merged into `<rev>`; when `<rev>` is omitted, the root worktree `HEAD` is used. `wt -cf` and `wt -cfm` skip confirmation but still do not force dirty worktree removal.

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
