# wt

Switch between Git worktrees stored under `.worktrees/<branch>` and pick them from Telescope.

`wt` follows the same standalone repo style as [`nvs`](../nvs), with one shell-specific difference: the interactive `wt` command is a zsh autoload function so it can change the current shell directory. The root executable provides shared data for completion and Neovim.

## Shell usage

```sh
wt              # cd to the repo root that owns .worktrees
wt <branch>     # cd to .worktrees/<branch>, creating it from a local branch if needed
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

Completion is installed from `zsh/completion/_wt` via `fpath`/`compinit`. It displays existing worktrees first, then normal branches, merged branches, and gone-upstream branches.

Example labels:

```text
feature-a  [worktree]
old-work   [worktree, gone]
merged     [merged]
gone       [gone]
```

Git terms:

- `[gone]`: the branch's upstream is gone, matching Git's `%(upstream:track)`/`git branch -vv` terminology.
- `[merged]`: the branch is merged into `origin/HEAD`, falling back to local `main` or `master`.

## Executable helper

```sh
command wt --help
command wt --zsh-completion
command wt __list
command wt __path <branch>
```

`__list` prints tab-separated rows for integrations. A label of `-` means no display label:

```text
branch<TAB>path<TAB>kind<TAB>label<TAB>sort
```

## Telescope picker

```lua
require("wt").setup({ key = "<Space>w" })
```

The picker lists existing worktrees and local branches. Selecting a branch without a worktree creates `.worktrees/<branch>` first.

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
