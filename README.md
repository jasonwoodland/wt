# wt

Switch between Git worktrees stored under `.worktrees/<branch>` and pick them from Telescope. Repos without `.worktrees` are supported; the directory is created lazily when a worktree is added.

`wt` follows the same standalone repo style as [`nvs`](../nvs), with one shell-specific difference: the interactive `wt` command is a zsh autoload function so it can change the current shell directory. The root executable provides shared data for completion and Neovim.

## Shell usage

```sh
wt              # open the interactive picker when fzf is available
wt -            # cd to the repo root that owns .worktrees
wt <branch>     # cd to the branch's existing worktree, or create .worktrees/<branch>
```

## Installation

```zsh
PATH="$HOME/Developer/github.com/jasonwoodland/wt:$PATH"
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/functions")
fpath+=("$HOME/Developer/github.com/jasonwoodland/wt/zsh/completion")
autoload -Uz wt
```

The autoloaded function shadows the executable for normal shell use. Use `command wt ...` to call the executable directly.

## Completion

Completion is installed from `zsh/completion/_wt` via `fpath`/`compinit`. It displays existing worktrees first, then local branches.

Displayed rows use three columns: branch name, existing worktree path, and an optional marker such as `[root]`. Paths are displayed relative to the repo root; branches without an existing worktree leave the path column blank.

Example labels:

```text
main       .                    [root]
feature-a  .worktrees/feature-a
new-branch
```

Git terms:

- `[root]`: the repository root worktree, available directly with `wt -`.

## Executable helper

```sh
command wt --help
command wt -
command wt <branch>
command wt --zsh-completion
command wt __list
command wt __path <branch>
```

`__list` prints tab-separated rows for integrations. Empty fields are left blank:

```text
branch<TAB>path<TAB>kind<TAB>label<TAB>sort
```

`path` and `kind` are set only for existing worktrees/root rows; local branches without an existing worktree leave both fields empty.

## Telescope picker

```lua
require("wt").setup({ key = "<Space>w" })
```

The picker lists existing worktrees and local branches with the same three-column branch/path/marker format as the shell. Selecting a branch without a worktree creates `.worktrees/<branch>` first.

Actions mirror the dotfiles projects picker:

- `<CR>`: `lcd <path>` and `edit .`
- horizontal split: `split <path>` and `lcd <path>`
- vertical split: `vertical split <path>` and `lcd <path>`
- tab action: `tabnew`, `lcd <path>`, and `edit .`
- `<Tab>`: drill into `find_files({ cwd = path })`

## Requirements

- Git
- Bash for the executable helper; compatible with macOS `/bin/bash` 3.2
- zsh for shell integration/completion
- Neovim + Telescope for the picker
