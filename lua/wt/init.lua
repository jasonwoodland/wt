local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local M = {}

local function wt_executable()
	local path = vim.fn.exepath("wt")
	if path ~= "" then
		return path
	end

	local source = debug.getinfo(1, "S").source:sub(2)
	local plugin_root = vim.fn.fnamemodify(source, ":p:h:h:h")
	local bundled = plugin_root .. "/wt"
	if vim.fn.executable(bundled) == 1 then
		return bundled
	end

	return nil, "'wt' is not executable"
end

local function command_output(args)
	local output = vim.fn.system(args)
	if vim.v.shell_error ~= 0 then
		return nil, vim.trim(output)
	end
	return output, nil
end

local function display_label(label)
	if label and label:find("root", 1, true) then
		return "[root]"
	end
	return ""
end

local function parse_rows(output)
	local rows = {}
	local root_path
	if not output or output == "" then
		return rows
	end

	for line in output:gmatch("[^\n]+") do
		local branch, path, kind, label, sort = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
		if branch and branch ~= "" then
			if label == "-" then
				label = ""
			end
			if kind == "root" and path ~= "" then
				root_path = path
			end
			table.insert(rows, {
				branch = branch,
				path = path,
				kind = kind,
				label = label,
				sort = tonumber(sort) or 1,
			})
		end
	end

	for _, row in ipairs(rows) do
		local root = root_path or row.path:match("^(.-)/%.worktrees/") or vim.fn.getcwd()
		row.root = root
		if row.path == "" then
			row.display_path = ""
		elseif row.path == root then
			row.display_path = "."
		elseif vim.startswith(row.path, root .. "/") then
			row.display_path = row.path:sub(#root + 2)
		else
			row.display_path = row.path
		end
	end

	return rows
end

local function get_candidates()
	local wt, wt_err = wt_executable()
	if not wt then
		return nil, wt_err
	end

	local output, err = command_output({ wt, "__list" })
	if not output then
		return nil, err
	end
	return parse_rows(output), nil
end

local function resolve_path(branch)
	local wt, wt_err = wt_executable()
	if not wt then
		return nil, wt_err
	end

	local output, err = command_output({ wt, "__path", branch })
	if not output then
		return nil, err
	end

	local path
	for line in output:gmatch("[^\r\n]+") do
		path = vim.trim(line)
	end

	if not path or path == "" then
		return nil, "Could not resolve worktree path"
	end

	return path, nil
end

local function edit_project_file(cwd, command)
	require("telescope.builtin").find_files({
		cwd = cwd,
		attach_mappings = function(prompt_bufnr)
			actions.select_default:replace(function()
				actions.close(prompt_bufnr)
				local entry = action_state.get_selected_entry()
				if not entry then
					return
				end
				vim.cmd.lcd(vim.fn.fnameescape(cwd))
				vim.cmd.edit(vim.fn.fnameescape(entry[1]))
			end)
			actions.select_horizontal:replace(function()
				actions.close(prompt_bufnr)
				local entry = action_state.get_selected_entry()
				if not entry then
					return
				end
				vim.cmd.lcd(vim.fn.fnameescape(cwd))
				vim.cmd.split(vim.fn.fnameescape(entry[1]))
			end)
			actions.select_vertical:replace(function()
				actions.close(prompt_bufnr)
				local entry = action_state.get_selected_entry()
				if not entry then
					return
				end
				vim.cmd.lcd(vim.fn.fnameescape(cwd))
				vim.cmd.vsplit(vim.fn.fnameescape(entry[1]))
			end)
			if command == "tab" then
				actions.select_tab:replace(function()
					actions.close(prompt_bufnr)
					local entry = action_state.get_selected_entry()
					if not entry then
						return
					end
					vim.cmd.tabnew()
					vim.cmd.lcd(vim.fn.fnameescape(cwd))
					vim.cmd.edit(vim.fn.fnameescape(entry[1]))
				end)
			end
			return true
		end,
	})
end

local function open_path(path, mode)
	local escaped = vim.fn.fnameescape(path)
	if mode == "horizontal" then
		vim.cmd.split(escaped)
		vim.cmd.lcd(escaped)
	elseif mode == "vertical" then
		vim.cmd.vsplit(escaped)
		vim.cmd.lcd(escaped)
	elseif mode == "tab" then
		vim.cmd.tabnew()
		vim.cmd.lcd(escaped)
		vim.cmd.edit(".")
	else
		vim.cmd.lcd(escaped)
		vim.cmd.edit(".")
	end
end

local function resolve_and_open(entry, mode)
	local path, err = resolve_path(entry.branch)
	if not path then
		vim.notify(err ~= "" and err or "Could not resolve worktree", vim.log.levels.ERROR)
		return
	end
	open_path(path, mode)
end

local function resolve_and_find_files(entry)
	local path, err = resolve_path(entry.branch)
	if not path then
		vim.notify(err ~= "" and err or "Could not resolve worktree", vim.log.levels.ERROR)
		return
	end
	edit_project_file(path)
end

local function normalize_path(path)
	if not path or path == "" then
		return nil
	end

	local normalized = vim.fn.fnamemodify(path, ":p")
	normalized = normalized:gsub("/+$", "")
	if normalized == "" then
		return "/"
	end
	return normalized
end

local function path_join(root, relative)
	if relative == "" then
		return root
	end
	return root .. "/" .. relative
end

local function path_in_root(path, root)
	if root == "/" then
		return path:sub(1, 1) == "/"
	end
	return path == root or vim.startswith(path, root .. "/")
end

local function buffer_belongs_to_root(path, root)
	if not path_in_root(path, root) then
		return false
	end

	-- Worktrees live under the root repo, but each is its own Git root.
	-- When switching from the root repo, do not treat nested worktree buffers
	-- as buffers that belong to the root worktree.
	return root == "/" or (path ~= root .. "/.worktrees" and not vim.startswith(path, root .. "/.worktrees/"))
end

local function relative_to_root(path, root)
	if path == root then
		return ""
	end
	return path:sub(#root + 2)
end

local function current_git_root()
	local output, err = command_output({ "git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" })
	if not output then
		return nil, err
	end

	return normalize_path(vim.trim(output)), nil
end

local function buffer_option(bufnr, option)
	local ok, value = pcall(vim.api.nvim_buf_get_option, bufnr, option)
	if not ok then
		return nil
	end
	return value
end

local function buffer_path(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	local buftype = buffer_option(bufnr, "buftype") or ""
	if buftype ~= "" and buftype ~= "nofile" then
		return nil
	end

	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return nil
	end

	local path = normalize_path(name)
	if buftype == "nofile" and vim.fn.isdirectory(path) ~= 1 then
		return nil
	end

	return path
end

local function buffers_in_root(root)
	local buffers = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local path = buffer_path(bufnr)
		if path and buffer_belongs_to_root(path, root) then
			table.insert(buffers, {
				bufnr = bufnr,
				path = path,
				relative = relative_to_root(path, root),
				listed = buffer_option(bufnr, "buflisted") == true,
			})
		end
	end
	return buffers
end

local function modified_buffer_paths(buffers)
	local modified = {}
	for _, buffer in ipairs(buffers) do
		if buffer_option(buffer.bufnr, "modified") then
			table.insert(modified, buffer.path)
		end
	end
	return modified
end

local function prepare_target_buffers(buffers, target_root)
	local by_bufnr = {}
	local failures = {}
	for _, buffer in ipairs(buffers) do
		buffer.target_path = path_join(target_root, buffer.relative)
		by_bufnr[buffer.bufnr] = buffer

		if buffer.path ~= buffer.target_path then
			local target_bufnr = vim.fn.bufadd(buffer.target_path)
			if target_bufnr ~= 0 then
				buffer.target_bufnr = target_bufnr
				local loaded, load_err = pcall(vim.fn.bufload, target_bufnr)
				if not loaded then
					table.insert(failures, load_err)
				end
				if buffer.listed then
					local listed, listed_err = pcall(vim.api.nvim_buf_set_option, target_bufnr, "buflisted", true)
					if not listed then
						table.insert(failures, listed_err)
					end
				end
			end
		end
	end
	return by_bufnr, failures
end

local function visible_buffers()
	local visible = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) then
			visible[vim.api.nvim_win_get_buf(win)] = true
		end
	end
	return visible
end

local function switch_windows_to_targets(buffers_by_bufnr, target_root)
	local switched = 0
	local failures = {}

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) then
			local buffer = buffers_by_bufnr[vim.api.nvim_win_get_buf(win)]
			if buffer and buffer.path ~= buffer.target_path then
				local ok, err = pcall(vim.api.nvim_win_call, win, function()
					local view = vim.fn.winsaveview()
					vim.cmd.lcd(vim.fn.fnameescape(target_root))
					vim.cmd.edit(vim.fn.fnameescape(buffer.target_path))
					pcall(vim.fn.winrestview, view)
				end)
				if ok then
					switched = switched + 1
				else
					table.insert(failures, err)
				end
			end
		end
	end

	return switched, failures
end

local function delete_old_buffers(buffers)
	local visible = visible_buffers()
	local deleted = 0
	local failures = {}

	for _, buffer in ipairs(buffers) do
		if buffer.path ~= buffer.target_path and vim.api.nvim_buf_is_valid(buffer.bufnr) and not visible[buffer.bufnr] then
			local ok, err = pcall(vim.api.nvim_buf_delete, buffer.bufnr, { force = false })
			if ok then
				deleted = deleted + 1
			else
				table.insert(failures, err)
			end
		end
	end

	return deleted, failures
end

local function switch_buffers_to_worktree(target_root)
	target_root = normalize_path(target_root)
	local source_root, err = current_git_root()
	if not source_root then
		vim.notify(err ~= "" and err or "Could not find current Git root", vim.log.levels.ERROR)
		return
	end

	if source_root == target_root then
		vim.notify("Already in " .. target_root, vim.log.levels.INFO)
		return
	end

	local buffers = buffers_in_root(source_root)
	if #buffers == 0 then
		vim.notify("No buffers under " .. source_root, vim.log.levels.INFO)
		return
	end

	local modified = modified_buffer_paths(buffers)
	if #modified > 0 then
		vim.notify("Unsaved buffers under " .. source_root .. ":\n" .. table.concat(modified, "\n"), vim.log.levels.ERROR)
		return
	end

	local buffers_by_bufnr, prepare_failures = prepare_target_buffers(buffers, target_root)
	if #prepare_failures > 0 then
		vim.notify("Could not open all target buffers:\n" .. table.concat(prepare_failures, "\n"), vim.log.levels.ERROR)
		return
	end

	local switched, switch_failures = switch_windows_to_targets(buffers_by_bufnr, target_root)
	if #switch_failures > 0 then
		vim.notify("Could not switch all windows:\n" .. table.concat(switch_failures, "\n"), vim.log.levels.ERROR)
		return
	end

	local deleted, delete_failures = delete_old_buffers(buffers)
	if #delete_failures > 0 then
		vim.notify("Switched windows, but could not close some old buffers:\n" .. table.concat(delete_failures, "\n"), vim.log.levels.WARN)
		return
	end

	vim.notify(
		"Switched " .. #buffers .. " buffer(s), " .. switched .. " window(s), closed " .. deleted .. " old buffer(s)",
		vim.log.levels.INFO
	)
end

local function resolve_and_switch_buffers(entry)
	local path, err = resolve_path(entry.branch)
	if not path then
		vim.notify(err ~= "" and err or "Could not resolve worktree", vim.log.levels.ERROR)
		return
	end
	switch_buffers_to_worktree(path)
end

local function remove_worktree(entry)
	if entry.kind ~= "worktree" then
		if entry.kind == "root" then
			vim.notify("Cannot remove the repo root worktree", vim.log.levels.WARN)
		else
			vim.notify("No worktree exists for branch '" .. entry.branch .. "'", vim.log.levels.WARN)
		end
		return false
	end

	local output, err = command_output({ "git", "-C", entry.root, "worktree", "remove", entry.path })
	if not output then
		vim.notify(err ~= "" and err or "Could not remove worktree", vim.log.levels.ERROR)
		return false
	end

	vim.notify("Removed worktree " .. entry.path, vim.log.levels.INFO)
	return true
end

function M.pick(opts)
	opts = opts or {}
	local candidates, err = get_candidates()
	if not candidates then
		vim.notify(err ~= "" and err or "Could not list worktrees", vim.log.levels.ERROR)
		return
	end
	if #candidates == 0 then
		vim.notify("No worktrees or local branches found", vim.log.levels.INFO)
		return
	end

	local max_branch_width = 0
	local max_path_width = 0
	for _, candidate in ipairs(candidates) do
		max_branch_width = math.max(max_branch_width, #candidate.branch)
		max_path_width = math.max(max_path_width, #candidate.display_path)
	end

	pickers
		.new(opts, {
			prompt_title = "Worktrees",
			previewer = previewers.new_termopen_previewer({
				title = "Git Log",
				get_command = function(entry)
					if not entry or not entry.value or not entry.value.branch then
						return nil
					end

					if vim.fn.executable("less") == 1 then
						return {
							"sh",
							"-c",
							'git -C "$1" --no-pager log --graph --color=always --decorate "$2" -- | less -R',
							"sh",
							entry.value.root,
							entry.value.branch,
						}
					end

					return {
						"git",
						"-C",
						entry.value.root,
						"--no-pager",
						"log",
						"--color=always",
						"--decorate",
						entry.value.branch,
						"--",
					}
				end,
			}),
			finder = finders.new_table({
				results = candidates,
				entry_maker = function(entry)
					local displayer = entry_display.create({
						separator = "  ",
						items = {
							{ width = max_branch_width },
							{ width = max_path_width },
							{ remaining = true },
						},
					})

					return {
						value = entry,
						branch = entry.branch,
						path = entry.path,
						display_path = entry.display_path,
						display = function()
							return displayer({
								entry.branch,
								{ entry.display_path, "TelescopeResultsComment" },
								{ display_label(entry.label), "TelescopeResultsComment" },
							})
						end,
						ordinal = entry.branch .. " " .. entry.path .. " " .. display_label(entry.label),
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						resolve_and_open(selection.value, "default")
					end
				end)
				actions.select_horizontal:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						resolve_and_open(selection.value, "horizontal")
					end
				end)
				actions.select_vertical:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						resolve_and_open(selection.value, "vertical")
					end
				end)
				actions.select_tab:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						resolve_and_open(selection.value, "tab")
					end
				end)
				map("i", "<tab>", function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						resolve_and_find_files(selection.value)
					end
				end)
				local switch_selection = function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						resolve_and_switch_buffers(selection.value)
					end
				end
				map("i", "<C-s>", switch_selection)
				map("n", "<C-s>", switch_selection)
				local delete_selection = function()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end

					local entry = selection.value
					if entry.kind == "worktree" then
						local choice = vim.fn.confirm(
							"Remove worktree '" .. entry.branch .. "'?\n" .. entry.path,
							"&Remove\n&Cancel",
							2,
							"Warning"
						)
						if choice ~= 1 then
							return
						end
					end

					if remove_worktree(entry) then
						actions.close(prompt_bufnr)
						M.pick(opts)
					end
				end
				map("i", "<C-d>", delete_selection)
				map("n", "<C-d>", delete_selection)
				return true
			end,
		})
		:find()
end

function M.setup(opts)
	opts = opts or {}
	local key = opts.key
	if key == nil then
		key = "<Leader>w"
	end
	if key then
		vim.keymap.set("n", key, function()
			M.pick({})
		end, { noremap = true, silent = true, desc = "Git Worktrees" })
	end
end

return M
