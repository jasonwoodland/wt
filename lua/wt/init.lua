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
							'git -C "$1" --no-pager log --color=always --decorate "$2" -- | less -R',
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
				local delete_selection = function()
					local selection = action_state.get_selected_entry()
					if selection and remove_worktree(selection.value) then
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
