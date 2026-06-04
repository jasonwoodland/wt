local repo_dir = vim.env.WT_REPO_UNDER_TEST or vim.fn.getcwd()
repo_dir = vim.fn.fnamemodify(repo_dir, ":p"):gsub("/+$", "")

vim.env.PATH = repo_dir .. ":" .. vim.env.PATH
package.path = repo_dir .. "/lua/?.lua;" .. repo_dir .. "/lua/?/init.lua;" .. package.path

local telescope_state = {}

package.preload["telescope.actions"] = function()
	local function replaceable()
		return {
			replace = function(self, fn)
				self.fn = fn
			end,
		}
	end

	return {
		close = function() end,
		select_default = replaceable(),
		select_horizontal = replaceable(),
		select_vertical = replaceable(),
		select_tab = replaceable(),
	}
end

package.preload["telescope.actions.state"] = function()
	return {
		get_selected_entry = function()
			return telescope_state.selection
		end,
	}
end

package.preload["telescope.config"] = function()
	return {
		values = {
			generic_sorter = function()
				return function() end
			end,
		},
	}
end

package.preload["telescope.finders"] = function()
	return {
		new_table = function(opts)
			return opts
		end,
	}
end

package.preload["telescope.previewers"] = function()
	return {
		new_buffer_previewer = function(opts)
			return opts
		end,
	}
end

package.preload["telescope.pickers.entry_display"] = function()
	return {
		create = function()
			return function(parts)
				return parts
			end
		end,
	}
end

package.preload["telescope.pickers"] = function()
	return {
		new = function(_, spec)
			return {
				find = function()
					local candidate
					for _, item in ipairs(spec.finder.results) do
						if item.branch == "feat/x" then
							candidate = item
							break
						end
					end
					assert(candidate, "expected feat/x candidate")
					telescope_state.selection = spec.finder.entry_maker(candidate)

					local mapped = {}
					local function map(mode, lhs, rhs)
						mapped[mode .. lhs] = rhs
					end

					assert(spec.attach_mappings(1, map), "attach_mappings failed")
					assert(mapped["i<C-s>"], "expected <C-s> mapping")
					mapped["i<C-s>"]()
				end,
			}
		end,
	}
end

local function normalize(path)
	local normalized = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
	local realpath = (vim.uv or vim.loop).fs_realpath(normalized)
	return realpath or normalized
end

local function esc(path)
	return vim.fn.fnameescape(path)
end

local function assert_eq(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s\nexpected: %s\nactual:   %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
	end
end

local function run(cmd, cwd)
	local full = cmd
	if cwd then
		full = "cd " .. vim.fn.shellescape(cwd) .. " && " .. cmd
	end
	local output = vim.fn.system(full)
	if vim.v.shell_error ~= 0 then
		error("command failed: " .. full .. "\n" .. output, 2)
	end
	return output
end

local function write(path, lines)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	vim.fn.writefile(lines, path)
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = normalize(tmp)
local root = tmp .. "/repo"
local outside = tmp .. "/outside"
vim.fn.mkdir(root, "p")
vim.fn.mkdir(outside, "p")
root = normalize(root)
outside = normalize(outside)

run("git init -q", root)
run("git config user.email wt@example.invalid", root)
run("git config user.name 'wt smoke'", root)
write(root .. "/pkg/foo/a.txt", { "foo" })
write(root .. "/pkg/bar/b.txt", { "bar" })
write(root .. "/pkg/plain/d.txt", { "plain" })
vim.fn.mkdir(root .. "/source-only/deep", "p")
vim.fn.mkdir(root .. "/.worktrees/other/pkg", "p")
run("git add pkg && git commit -q -m initial", root)
run("git branch feat/x", root)

vim.cmd("cd " .. esc(root))
root = normalize(vim.fn.getcwd(-1, -1))
local target_root = normalize(root .. "/.worktrees/feat/x")
local target_foo = normalize(target_root .. "/pkg/foo")
local target_bar = normalize(target_root .. "/pkg/bar")

vim.cmd("edit " .. esc(root .. "/pkg/foo/a.txt"))
vim.cmd("tcd " .. esc(root .. "/pkg/foo"))
local tab_tcd = vim.api.nvim_get_current_tabpage()
local win_tcd_only = vim.api.nvim_get_current_win()
vim.cmd("split " .. esc(root .. "/pkg/bar/b.txt"))
local win_lcd = vim.api.nvim_get_current_win()
vim.cmd("lcd " .. esc(root .. "/pkg/bar"))

vim.cmd("tabnew " .. esc(root .. "/pkg/foo/a.txt"))
local tab_missing = vim.api.nvim_get_current_tabpage()
local missing_cwd = normalize(root .. "/source-only/deep")
vim.cmd("tcd " .. esc(missing_cwd))

vim.cmd("tabnew " .. esc(root .. "/pkg/bar/b.txt"))
local tab_outside = vim.api.nvim_get_current_tabpage()
local win_outside = vim.api.nvim_get_current_win()
vim.cmd("lcd " .. esc(outside))

vim.cmd("tabnew " .. esc(root .. "/pkg/foo/a.txt"))
local tab_nested = vim.api.nvim_get_current_tabpage()
local nested_cwd = normalize(root .. "/.worktrees/other/pkg")
vim.cmd("tcd " .. esc(nested_cwd))

vim.cmd("tabnew " .. esc(root .. "/pkg/plain/d.txt"))
local tab_plain = vim.api.nvim_get_current_tabpage()
local win_plain = vim.api.nvim_get_current_win()
vim.cmd("cd " .. esc(root))

local current_tab_before = vim.api.nvim_get_current_tabpage()
local current_win_before = vim.api.nvim_get_current_win()

require("wt").pick({})

assert_eq(vim.api.nvim_get_current_tabpage(), current_tab_before, "current tab should be restored after <C-s>")
assert_eq(vim.api.nvim_get_current_win(), current_win_before, "current window should be restored after <C-s>")

local tcd_tabnr = vim.api.nvim_tabpage_get_number(tab_tcd)
assert_eq(vim.fn.haslocaldir(-1, tcd_tabnr), 1, "tab with explicit :tcd should still have :tcd")
assert_eq(normalize(vim.fn.getcwd(-1, tcd_tabnr)), target_foo, "tab-local :tcd should map to target-relative directory")
assert_eq(vim.fn.haslocaldir(win_tcd_only, tcd_tabnr), 0, "window relying on mapped :tcd should not gain :lcd")

assert_eq(vim.fn.haslocaldir(win_lcd, tcd_tabnr), 1, "window with explicit :lcd should still have :lcd")
assert_eq(normalize(vim.fn.getcwd(win_lcd, tcd_tabnr)), target_bar, "window-local :lcd should map to target-relative directory")

local missing_tabnr = vim.api.nvim_tabpage_get_number(tab_missing)
assert_eq(normalize(vim.fn.getcwd(-1, missing_tabnr)), target_root, "missing mapped :tcd directory should fall back to target root")
assert_eq(vim.fn.haslocaldir(-1, missing_tabnr), 1, "missing mapped :tcd fallback should remain tab-local")

local outside_tabnr = vim.api.nvim_tabpage_get_number(tab_outside)
assert_eq(normalize(vim.fn.getcwd(win_outside, outside_tabnr)), outside, "explicit outside :lcd should be preserved")

local nested_tabnr = vim.api.nvim_tabpage_get_number(tab_nested)
assert_eq(normalize(vim.fn.getcwd(-1, nested_tabnr)), nested_cwd, "nested .worktrees :tcd should be preserved")
assert_eq(vim.fn.haslocaldir(-1, nested_tabnr), 1, "nested .worktrees cwd should remain tab-local")

local plain_tabnr = vim.api.nvim_tabpage_get_number(tab_plain)
assert_eq(vim.fn.haslocaldir(win_plain, plain_tabnr), 1, "switched window without local cwd should keep legacy :lcd fallback")
assert_eq(normalize(vim.fn.getcwd(win_plain, plain_tabnr)), target_root, "legacy :lcd fallback should use target root")

print("cwd remap smoke passed")
