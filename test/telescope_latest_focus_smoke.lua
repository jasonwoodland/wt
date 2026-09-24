local repo_dir = vim.env.WT_REPO_UNDER_TEST or vim.fn.getcwd()
repo_dir = vim.fn.fnamemodify(repo_dir, ":p"):gsub("/+$", "")

vim.env.PATH = repo_dir .. ":" .. vim.env.PATH
package.path = repo_dir .. "/lua/?.lua;" .. repo_dir .. "/lua/?/init.lua;" .. package.path

local telescope_state = {
	close_count = 0,
	notifications = {},
}

local function assert_eq(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s\nexpected: %s\nactual:   %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
	end
end

local function assert_true(value, label)
	if not value then
		error(label, 2)
	end
end

local function normalize(path)
	local normalized = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
	local realpath = (vim.uv or vim.loop).fs_realpath(normalized)
	return realpath or normalized
end

local function esc(path)
	return vim.fn.fnameescape(path)
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

local function exists(path)
	return (vim.uv or vim.loop).fs_stat(path) ~= nil
end

local function make_repo()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	root = normalize(root)
	run("git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }", root)
	run("git config user.email wt@example.invalid", root)
	run("git config user.name 'wt telescope latest'", root)
	vim.fn.mkdir(root .. "/.worktrees", "p")
	write(root .. "/file.txt", { "base" })
	run("git add file.txt", root)
	run("GIT_AUTHOR_DATE='2000-01-01T00:00:00 +0000' GIT_COMMITTER_DATE='2000-01-01T00:00:00 +0000' git commit -q -m base", root)
	return root
end

local function commit_file(path, branch, date, message)
	local safe_branch = branch:gsub("/", "_")
	write(path .. "/" .. safe_branch .. ".txt", { message })
	run("git add " .. vim.fn.shellescape(safe_branch .. ".txt"), path)
	run("GIT_AUTHOR_DATE='" .. date .. "' GIT_COMMITTER_DATE='" .. date .. "' git commit -q -m " .. vim.fn.shellescape(message), path)
end

local function create_branch_worktree(root, branch, date)
	local path = root .. "/.worktrees/" .. branch
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	run("git branch " .. vim.fn.shellescape(branch) .. " main", root)
	run("git worktree add -q " .. vim.fn.shellescape(path) .. " " .. vim.fn.shellescape(branch), root)
	commit_file(path, branch, date, branch .. " commit")
	return normalize(path)
end

local function create_branch_only(root, branch, date)
	local path = root .. "/.worktrees/" .. branch .. ".tmp"
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	run("git branch " .. vim.fn.shellescape(branch) .. " main", root)
	run("git worktree add -q " .. vim.fn.shellescape(path) .. " " .. vim.fn.shellescape(branch), root)
	commit_file(path, branch, date, branch .. " commit")
	run("git worktree remove " .. vim.fn.shellescape(path), root)
end

local function update_root(root, date)
	write(root .. "/file.txt", { "base", "root latest" })
	run("git add file.txt", root)
	run("GIT_AUTHOR_DATE='" .. date .. "' GIT_COMMITTER_DATE='" .. date .. "' git commit -q -m 'root latest'", root)
end

local function replaceable()
	return {
		replace = function(self, fn)
			self.fn = fn
		end,
	}
end

package.preload["telescope.actions"] = function()
	return {
		close = function()
			telescope_state.close_count = telescope_state.close_count + 1
		end,
		select_default = replaceable(),
		select_horizontal = replaceable(),
		select_vertical = replaceable(),
		select_tab = replaceable(),
	}
end

package.preload["telescope.actions.state"] = function()
	return {
		get_current_picker = function()
			return telescope_state.current_picker
		end,
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

local function ordered_entries(entries, order)
	if not order then
		return entries
	end

	local by_branch = {}
	for _, entry in ipairs(entries) do
		by_branch[entry.value.branch] = entry
	end

	local sorted = {}
	local used = {}
	for _, branch in ipairs(order) do
		if by_branch[branch] then
			table.insert(sorted, by_branch[branch])
			used[branch] = true
		end
	end
	for _, entry in ipairs(entries) do
		if not used[entry.value.branch] then
			table.insert(sorted, entry)
		end
	end
	return sorted
end

package.preload["telescope.pickers"] = function()
	return {
		new = function(_, spec)
			return {
				find = function()
					local scenario = telescope_state.scenario
					local entries = {}
					for _, item in ipairs(spec.finder.results) do
						if not scenario.filtered_branch or item.branch ~= scenario.filtered_branch then
							table.insert(entries, spec.finder.entry_maker(item))
						end
					end
					entries = ordered_entries(entries, scenario.order)
					assert_true(#entries > 0, "expected visible entries")

					local manager = {
						num_results = function()
							return #entries
						end,
						get_entry = function(_, index)
							return entries[index]
						end,
					}

					local picker = {
						manager = manager,
						set_selection_count = 0,
						last_row = nil,
						get_row = function(_, index)
							return index - 1
						end,
						set_selection = function(self, row)
							self.set_selection_count = self.set_selection_count + 1
							self.last_row = row
							telescope_state.selection = entries[row + 1]
						end,
					}

					telescope_state.current_picker = picker
					telescope_state.selection = entries[1]

					local mapped = {}
					local function map(mode, lhs, rhs)
						mapped[mode .. lhs] = rhs
					end

					assert_true(spec.attach_mappings(1, map), "attach_mappings failed")
					assert_true(mapped["i<C-l>"], "expected insert-mode <C-l> mapping")
					assert_true(mapped["n<C-l>"], "expected normal-mode <C-l> mapping")

					mapped[(scenario.mode or "i") .. "<C-l>"]()
					scenario.after(entries, picker, spec)
				end,
			}
		end,
	}
end

vim.notify = function(message, level)
	table.insert(telescope_state.notifications, { message = message, level = level })
end

local function run_pick_scenario(scenario)
	telescope_state.scenario = scenario
	telescope_state.close_count = 0
	telescope_state.notifications = {}
	telescope_state.current_picker = nil
	telescope_state.selection = nil
	require("wt").pick({})
end

local function test_focuses_visible_latest_branch_without_switching()
	local root = make_repo()
	create_branch_worktree(root, "older", "2020-01-02T00:00:00 +0000")
	create_branch_only(root, "newest", "2020-01-04T00:00:00 +0000")
	vim.cmd("cd " .. esc(root))

	run_pick_scenario({
		order = { "main", "older", "newest" },
		after = function(_, picker)
			assert_eq(picker.set_selection_count, 1, "<C-l> should set selection once")
			assert_eq(picker.last_row, 2, "<C-l> should focus the non-first latest row")
			assert_eq(telescope_state.selection.value.branch, "newest", "<C-l> should focus latest branch")
			assert_eq(telescope_state.close_count, 0, "<C-l> should not close the picker")
			assert_true(not exists(root .. "/.worktrees/newest"), "<C-l> should not create branch-only worktrees")
		end,
	})
end

local function test_focuses_root_row_when_root_branch_is_latest()
	local root = make_repo()
	create_branch_worktree(root, "topic", "2020-01-02T00:00:00 +0000")
	update_root(root, "2020-01-05T00:00:00 +0000")
	vim.cmd("cd " .. esc(root .. "/.worktrees/topic"))

	run_pick_scenario({
		mode = "n",
		order = { "topic", "main" },
		after = function(_, picker)
			assert_eq(picker.set_selection_count, 1, "normal-mode <C-l> should set selection once")
			assert_eq(telescope_state.selection.value.branch, "main", "<C-l> should focus root branch")
			assert_eq(telescope_state.selection.value.kind, "root", "<C-l> should be able to focus root rows")
			assert_eq(telescope_state.close_count, 0, "<C-l> should not close the picker")
		end,
	})
end

local function test_filtered_out_latest_notifies_and_preserves_selection()
	local root = make_repo()
	create_branch_worktree(root, "older", "2020-01-02T00:00:00 +0000")
	create_branch_only(root, "newest", "2020-01-04T00:00:00 +0000")
	vim.cmd("cd " .. esc(root))

	run_pick_scenario({
		filtered_branch = "newest",
		order = { "older", "main" },
		after = function(_, picker)
			assert_eq(picker.set_selection_count, 0, "<C-l> should not change selection when latest is filtered out")
			assert_eq(telescope_state.selection.value.branch, "older", "<C-l> should preserve current selection when latest is filtered out")
			assert_eq(telescope_state.close_count, 0, "<C-l> should not close the picker when latest is filtered out")
			assert_true(#telescope_state.notifications > 0, "<C-l> should notify when latest is filtered out")
		end,
	})
end

local function test_detached_worktree_selection_and_preview()
	local root = make_repo()
	local path = root .. "/.worktrees/eval/121 baseline"
	run("git worktree add -q --detach " .. vim.fn.shellescape(path) .. " HEAD", root)
	commit_file(path, "detached", "2020-01-02T00:00:00 +0000", "detached preview commit")
	vim.cmd("cd " .. esc(root))

	run_pick_scenario({
		after = function(entries, _, spec)
			local detached
			for _, entry in ipairs(entries) do
				if entry.value.path == path then detached = entry end
			end
			assert_true(detached, "detached worktree should be listed")
			assert_eq(detached.value.branch_display, "(detached)", "detached display label")
			assert_eq(detached.value.display_path, ".worktrees/eval/121 baseline", "detached directory display")
			local buf = vim.api.nvim_create_buf(false, true)
			spec.previewer.define_preview({ state = { bufnr = buf } }, detached)
			assert_true(vim.wait(5000, function() return vim.b[buf].wt_git_log_loaded end), "preview should finish")
			local preview = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
			assert_true(preview:find("detached preview commit", 1, true), "preview should use detached HEAD")
			vim.api.nvim_buf_delete(buf, { force = true })
			telescope_state.selection = detached
			require("telescope.actions").select_default.fn()
			assert_eq(normalize(vim.fn.getcwd()), path, "selection should open detached directory")
			assert_eq(vim.trim(run("git branch --show-current", path)), "", "selection must leave HEAD detached")
		end,
	})
end

test_detached_worktree_selection_and_preview()
test_focuses_visible_latest_branch_without_switching()
test_focuses_root_row_when_root_branch_is_latest()
test_filtered_out_latest_notifies_and_preserves_selection()

print("telescope latest focus smoke passed")
