# wt

Shell utility and [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) picker to switch between Git worktrees.

## Shell usage

```sh
wt              # open the interactive picker when fzf is available
wt -            # cd to the repo root that owns .worktrees
wt <branch>     # cd to the branch's existing worktree, or create .worktrees/<branch>
wt --clean      # remove clean non-main worktrees after confirmation
wt -cf          # remove clean non-main worktrees without confirmation
```

## Installation

Add to your `zshrc`:

```zsh
PATH="$HOME/Developer/github.com/jasonwoodland/wt:$PATH"
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/functions")
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/completion")
autoload -Uz wt
```

## Command helper

```sh
command wt --help
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
| `<C-s>` | insert/normal     | Switch buffers and windows from the current Git root/worktree to the selected worktree |
| `<C-d>` | insert/normal     | Confirm and remove the selected existing worktree                                      |

`<C-s>` refuses to switch if any matching source-root buffers are unsaved. When it succeeds, it opens corresponding buffers under the selected worktree, preserves window views, remaps explicit window-local `:lcd` and tab-local `:tcd` directories to the same relative paths in the selected worktree, and closes the old source-root buffers. Explicit directories outside the source root, including nested `.worktrees`, are preserved; missing mapped directories fall back to the nearest existing ancestor in the target worktree.

`<C-d>` and `wt --clean` only remove clean worktrees (no untracked files and no modification in tracked files). `wt -cf` skips confirmation but still does not force dirty worktree removal.
