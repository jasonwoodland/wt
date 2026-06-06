local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local M = {}

local git_log_preview_ns = vim.api.nvim_create_namespace("wt_git_log_preview")

local ansi_groups = {
	["30"] = "WtAnsiBlack",
	["31"] = "WtAnsiRed",
	["32"] = "WtAnsiGreen",
	["33"] = "WtAnsiYellow",
	["34"] = "WtAnsiBlue",
	["35"] = "WtAnsiMagenta",
	["36"] = "WtAnsiCyan",
	["37"] = "WtAnsiWhite",
	["90"] = "WtAnsiBrightBlack",
	["91"] = "WtAnsiBrightRed",
	["92"] = "WtAnsiBrightGreen",
	["93"] = "WtAnsiBrightYellow",
	["94"] = "WtAnsiBrightBlue",
	["95"] = "WtAnsiBrightMagenta",
	["96"] = "WtAnsiBrightCyan",
	["97"] = "WtAnsiBrightWhite",
}

local ansi_colors = {
	WtAnsiBlack = { 0, "#000000" },
	WtAnsiRed = { 1, "#cc241d" },
	WtAnsiGreen = { 2, "#98971a" },
	WtAnsiYellow = { 3, "#d79921" },
	WtAnsiBlue = { 4, "#458588" },
	WtAnsiMagenta = { 5, "#b16286" },
	WtAnsiCyan = { 6, "#689d6a" },
	WtAnsiWhite = { 7, "#a89984" },
	WtAnsiBrightBlack = { 8, "#928374" },
	WtAnsiBrightRed = { 9, "#fb4934" },
	WtAnsiBrightGreen = { 10, "#b8bb26" },
	WtAnsiBrightYellow = { 11, "#fabd2f" },
	WtAnsiBrightBlue = { 12, "#83a598" },
	WtAnsiBrightMagenta = { 13, "#d3869b" },
	WtAnsiBrightCyan = { 14, "#8ec07c" },
	WtAnsiBrightWhite = { 15, "#ebdbb2" },
}

local function ensure_ansi_groups()
	for group, color in pairs(ansi_colors) do
		local terminal_color = vim.g["terminal_color_" .. color[1]]
		if type(terminal_color) ~= "string" or terminal_color == "" then
			terminal_color = color[2]
		end
		vim.api.nvim_set_hl(0, group, { fg = terminal_color })
	end
end

local function ansi_group_for_codes(codes, current)
	if codes == "" then
		return nil
	end

	local group = current
	for code in codes:gmatch("[^;]+") do
		if code == "0" or code == "00" or code == "39" then
			group = nil
		elseif ansi_groups[code] then
			group = ansi_groups[code]
		end
	end
	return group
end

local function parse_ansi_line(line)
	local chunks = {}
	local highlights = {}
	local group
	local col = 0
	local pos = 1

	while true do
		local esc_start, esc_end, codes = line:find("\27%[([0-9;]*)m", pos)
		local chunk = esc_start and line:sub(pos, esc_start - 1) or line:sub(pos)
		if chunk ~= "" then
			table.insert(chunks, chunk)
			if group then
				table.insert(highlights, { col, col + #chunk, group })
			end
			col = col + #chunk
		end
		if not esc_start then
			break
		end
		group = ansi_group_for_codes(codes, group)
		pos = esc_end + 1
	end

	return table.concat(chunks), highlights
end

local function parse_ansi_output(output)
	local lines = vim.split(output, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end

	local parsed_lines = {}
	local line_highlights = {}
	for _, line in ipairs(lines) do
		local parsed_line, highlights = parse_ansi_line(line)
		table.insert(parsed_lines, parsed_line)
		table.insert(line_highlights, highlights)
	end
	return parsed_lines, line_highlights
end

local function set_preview_lines(bufnr, lines, line_highlights)
	ensure_ansi_groups()
	vim.api.nvim_buf_clear_namespace(bufnr, git_log_preview_ns, 0, -1)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	for line_number, highlights in ipairs(line_highlights or {}) do
		for _, highlight in ipairs(highlights) do
			vim.api.nvim_buf_set_extmark(bufnr, git_log_preview_ns, line_number - 1, highlight[1], {
				end_col = highlight[2],
				hl_group = highlight[3],
				priority = 200,
			})
		end
	end
end

local function configure_preview_window(winid)
	local function apply()
		if winid and vim.api.nvim_win_is_valid(winid) then
			vim.wo[winid].number = false
			vim.wo[winid].relativenumber = false
			vim.wo[winid].cursorline = false
			vim.wo[winid].signcolumn = "no"
		end
	end

	apply()
	vim.schedule(apply)
	vim.schedule(function()
		vim.schedule(apply)
	end)
end

local function preview_is_current(bufnr, winid)
	return vim.api.nvim_buf_is_valid(bufnr)
	    and (not winid or not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) == bufnr)
end

local function lines_to_output(lines)
	if not lines then
		return ""
	end
	return table.concat(lines, "\n")
end

local function mark_preview_loaded(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.b[bufnr].wt_git_log_loading = false
		vim.b[bufnr].wt_git_log_loaded = true
	end
end

local function preview_git_log(bufnr, winid, root, branch)
	if vim.b[bufnr].wt_git_log_loaded or vim.b[bufnr].wt_git_log_loading then
		return
	end

	vim.b[bufnr].wt_git_log_loading = true
	vim.defer_fn(function()
		if not preview_is_current(bufnr, winid) then
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.b[bufnr].wt_git_log_loading = false
			end
			return
		end

		local stdout = {}
		local stderr = {}
		local job_id = vim.fn.jobstart({
			"git",
			"-C",
			root,
			"--no-pager",
			"log",
			"--graph",
			"--color=always",
			"--decorate",
			"--max-count=200",
			branch,
			"--",
		}, {
			stdout_buffered = true,
			stderr_buffered = true,
			on_stdout = function(_, data)
				stdout = data or {}
			end,
			on_stderr = function(_, data)
				stderr = data or {}
			end,
			on_exit = function(_, code)
				vim.schedule(function()
					if not vim.api.nvim_buf_is_valid(bufnr) then
						return
					end

					local output = lines_to_output(stdout)
					if code ~= 0 then
						local message = vim.trim(lines_to_output(stderr))
						if message == "" then
							message = vim.trim(output)
						end
						if message == "" then
							message = "Could not load git log for " .. branch
						end
						set_preview_lines(bufnr, vim.split(message, "\n", { plain = true }))
					elseif output == "" then
						set_preview_lines(bufnr, { "No commits found for " .. branch })
					else
						local lines, line_highlights = parse_ansi_output(output)
						set_preview_lines(bufnr, lines, line_highlights)
					end
					mark_preview_loaded(bufnr)
				end)
			end,
		})

		if job_id <= 0 then
			set_preview_lines(bufnr, { "Could not start git log for " .. branch })
			mark_preview_loaded(bufnr)
		end
	end, 75)
end

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

local function split_path(path)
	local parts = {}
	for part in path:gmatch("[^/]+") do
		table.insert(parts, part)
	end
	return parts
end

local function display_path_for_root(path, root)
	if path == "" then
		return ""
	end
	if root and root ~= "" then
		if path == root then
			return "."
		end
		if root == "/" and vim.startswith(path, "/") then
			return path:sub(2)
		end
		if root ~= "/" and vim.startswith(path, root .. "/") then
			return path:sub(#root + 2)
		end
		if path:sub(1, 1) == "/" and root:sub(1, 1) == "/" then
			local path_parts = split_path(path)
			local root_parts = split_path(root)
			local index = 1
			while index <= #path_parts and index <= #root_parts and path_parts[index] == root_parts[index] do
				index = index + 1
			end

			local relative = {}
			for _ = index, #root_parts do
				table.insert(relative, "..")
			end
			for i = index, #path_parts do
				table.insert(relative, path_parts[i])
			end
			if #relative == 0 then
				return "."
			end
			return table.concat(relative, "/")
		end
	end
	return path
end

local function parse_rows(output)
	local rows = {}
	local root_path
	if not output or output == "" then
		return rows
	end

	for line in output:gmatch("[^\n]+") do
		local branch, path, kind, label, sort, sha =
		    line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
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
				sha = sha,
				sort = tonumber(sort) or 1,
			})
		end
	end

	for _, row in ipairs(rows) do
		local root = root_path or row.path:match("^(.-)/%.worktrees/") or vim.fn.getcwd()
		row.root = root
		row.display_path = display_path_for_root(row.path, root)
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

local function latest_branch()
	local wt, wt_err = wt_executable()
	if not wt then
		return nil, wt_err
	end

	local output, err = command_output({ wt, "__latest_branch" })
	if not output then
		return nil, err
	end

	local branch = vim.trim(output)
	if branch == "" then
		return nil, "No local branches found"
	end

	return branch, nil
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

local function nearest_existing_dir(path, root)
	local current = normalize_path(path)
	local boundary = normalize_path(root)
	if not current or not boundary then
		return boundary
	end

	while path_in_root(current, boundary) do
		if vim.fn.isdirectory(current) == 1 then
			return current
		end
		if current == boundary then
			break
		end

		local parent = normalize_path(vim.fn.fnamemodify(current, ":h"))
		if not parent or parent == current then
			break
		end
		current = parent
	end

	return boundary
end

local function map_cwd_to_target(path, source_root, target_root)
	path = normalize_path(path)
	if not path or not buffer_belongs_to_root(path, source_root) then
		return nil
	end

	return nearest_existing_dir(path_join(target_root, relative_to_root(path, source_root)), target_root)
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
					local listed, listed_err = pcall(vim.api.nvim_buf_set_option, target_bufnr,
						"buflisted", true)
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

local function safe_haslocaldir(winnr, tabnr)
	local ok, value = pcall(vim.fn.haslocaldir, winnr, tabnr)
	return ok and value == 1
end

local function safe_getcwd(winnr, tabnr)
	local ok, value = pcall(vim.fn.getcwd, winnr, tabnr)
	if ok and value and value ~= "" then
		return normalize_path(value)
	end
	return nil
end

local function snapshot_cwd_scopes(source_root, target_root)
	local state = {
		tabs = {},
		tab_order = {},
		windows = {},
	}

	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		local tabnr = vim.api.nvim_tabpage_get_number(tab)
		local windows = vim.api.nvim_tabpage_list_wins(tab)
		local tab_scope = {
			tab = tab,
			tabnr = tabnr,
			windows = windows,
			has_local = false,
		}

		if safe_haslocaldir(-1, tabnr) then
			local cwd = safe_getcwd(-1, tabnr)
			if cwd then
				tab_scope.has_local = true
				tab_scope.cwd = cwd
				tab_scope.mapped = map_cwd_to_target(cwd, source_root, target_root)
			end
		end

		state.tabs[tab] = tab_scope
		table.insert(state.tab_order, tab_scope)

		for _, win in ipairs(windows) do
			local win_scope = {
				win = win,
				tab = tab,
				tabnr = tabnr,
				has_local = false,
			}

			if safe_haslocaldir(win, tabnr) then
				local cwd = safe_getcwd(win, tabnr)
				if cwd then
					win_scope.has_local = true
					win_scope.cwd = cwd
					win_scope.mapped = map_cwd_to_target(cwd, source_root, target_root)
				end
			end

			state.windows[win] = win_scope
		end
	end

	return state
end

local function restore_current_tab_window(tab, win)
	if tab and vim.api.nvim_tabpage_is_valid(tab) then
		pcall(vim.api.nvim_set_current_tabpage, tab)
	end
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_set_current_win, win)
	end
end

local function first_valid_window(windows)
	for _, win in ipairs(windows or {}) do
		if vim.api.nvim_win_is_valid(win) then
			return win
		end
	end
	return nil
end

local function apply_tab_cwds(cwd_state)
	local failures = {}
	local current_tab = vim.api.nvim_get_current_tabpage()
	local current_win = vim.api.nvim_get_current_win()

	for _, tab_scope in ipairs(cwd_state.tab_order) do
		if tab_scope.has_local and tab_scope.mapped then
			local win = first_valid_window(tab_scope.windows)
			if win then
				local ok, err = pcall(vim.api.nvim_win_call, win, function()
					vim.cmd.tcd(vim.fn.fnameescape(tab_scope.mapped))
				end)
				if not ok then
					table.insert(failures, err)
				end
			end
		end
	end

	restore_current_tab_window(current_tab, current_win)
	return failures
end

local function desired_window_lcd(win_scope, tab_scope, should_switch, target_root)
	if win_scope and win_scope.has_local then
		return win_scope.mapped or win_scope.cwd
	end
	if should_switch and not (tab_scope and tab_scope.has_local) then
		return target_root
	end
	return nil
end

local function switch_windows_to_targets(buffers_by_bufnr, target_root, cwd_state)
	local switched = 0
	local failures = {}
	local current_tab = vim.api.nvim_get_current_tabpage()
	local current_win = vim.api.nvim_get_current_win()

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) then
			local buffer = buffers_by_bufnr[vim.api.nvim_win_get_buf(win)]
			local should_switch = buffer and buffer.path ~= buffer.target_path
			local win_scope = cwd_state.windows[win]
			local tab_scope = win_scope and cwd_state.tabs[win_scope.tab]
			local lcd = desired_window_lcd(win_scope, tab_scope, should_switch, target_root)

			if should_switch or lcd then
				local ok, err = pcall(vim.api.nvim_win_call, win, function()
					local view = should_switch and vim.fn.winsaveview() or nil
					if lcd then
						vim.cmd.lcd(vim.fn.fnameescape(lcd))
					end
					if should_switch then
						vim.cmd.edit(vim.fn.fnameescape(buffer.target_path))
						pcall(vim.fn.winrestview, view)
					end
				end)
				if ok then
					if should_switch then
						switched = switched + 1
					end
				else
					table.insert(failures, err)
				end
			end
		end
	end

	restore_current_tab_window(current_tab, current_win)
	return switched, failures
end

local function delete_old_buffers(buffers)
	local visible = visible_buffers()
	local deleted = 0
	local failures = {}

	for _, buffer in ipairs(buffers) do
		if
		    buffer.path ~= buffer.target_path
		    and vim.api.nvim_buf_is_valid(buffer.bufnr)
		    and not visible[buffer.bufnr]
		then
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
		vim.notify(
			"Unsaved buffers under " .. source_root .. ":\n" .. table.concat(modified, "\n"),
			vim.log.levels.ERROR
		)
		return
	end

	local buffers_by_bufnr, prepare_failures = prepare_target_buffers(buffers, target_root)
	if #prepare_failures > 0 then
		vim.notify("Could not open all target buffers:\n" .. table.concat(prepare_failures, "\n"),
			vim.log.levels.ERROR)
		return
	end

	local cwd_state = snapshot_cwd_scopes(source_root, target_root)
	local tab_cwd_failures = apply_tab_cwds(cwd_state)
	if #tab_cwd_failures > 0 then
		vim.notify("Could not update all tab directories:\n" .. table.concat(tab_cwd_failures, "\n"), vim.log.levels.ERROR)
		return
	end

	local switched, switch_failures = switch_windows_to_targets(buffers_by_bufnr, target_root, cwd_state)
	if #switch_failures > 0 then
		vim.notify("Could not switch all windows:\n" .. table.concat(switch_failures, "\n"), vim.log.levels
		.ERROR)
		return
	end

	local deleted, delete_failures = delete_old_buffers(buffers)
	if #delete_failures > 0 then
		vim.notify(
			"Switched windows, but could not close some old buffers:\n" ..
			table.concat(delete_failures, "\n"),
			vim.log.levels.WARN
		)
		return
	end

	vim.notify(
		"Switched " ..
		#buffers .. " buffer(s), " .. switched .. " window(s), closed " .. deleted .. " old buffer(s)",
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

	local max_sha_width = 0
	local max_branch_width = 0
	for _, candidate in ipairs(candidates) do
		max_sha_width = math.max(max_sha_width, #candidate.sha)
		max_branch_width = math.max(max_branch_width, #(candidate.branch_display or candidate.branch))
	end

	pickers
	    .new(opts, {
		    prompt_title = "Worktrees",
		    previewer = previewers.new_buffer_previewer({
			    title = "Git Log",
			    get_buffer_by_name = function(_, entry)
				    if not entry or not entry.value or not entry.value.branch then
					    return nil
				    end
				    return table.concat(
					    { "wt-git-log", entry.value.root, entry.value.branch, entry.value.sha or "" },
					    ":"
				    )
			    end,
			    define_preview = function(self, entry)
				    configure_preview_window(self.state.winid)
				    if self.state.bufname and vim.b[self.state.bufnr].wt_git_log_loaded then
					    return
				    end
				    if not entry or not entry.value or not entry.value.branch then
					    return
				    end

				    preview_git_log(self.state.bufnr, self.state.winid, entry.value.root,
					    entry.value.branch)
			    end,
		    }),
		    finder = finders.new_table({
			    results = candidates,
			    entry_maker = function(entry)
				    local displayer = entry_display.create({
					    separator = " ",
					    items = {
						    { width = max_sha_width },
						    { width = max_branch_width },
						    { remaining = true },
					    },
				    })

				    return {
					    value = entry,
					    branch = entry.branch,
					    path = entry.path,
					    display_path = entry.display_path,
					    display = function()
						    local branch_display = entry.branch_display or entry.branch
						    return displayer({
							    { entry.sha,          "Identifier" },
							    branch_display,
							    { entry.display_path, "diffFile" },
						    })
					    end,
					    ordinal = entry.sha .. " " .. entry.branch .. " " .. entry.display_path,
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
			    local focus_latest_selection = function()
				    local branch, latest_err = latest_branch()
				    if not branch then
					    vim.notify(latest_err ~= "" and latest_err or "Could not find latest branch", vim.log.levels.ERROR)
					    return
				    end

				    local picker = action_state.get_current_picker(prompt_bufnr)
				    if not picker or not picker.manager then
					    return
				    end

				    for index = 1, picker.manager:num_results() do
					    local entry = picker.manager:get_entry(index)
					    if entry and entry.value and entry.value.branch == branch then
						    picker:set_selection(picker:get_row(index))
						    return
					    end
				    end

				    vim.notify("Latest branch '" .. branch .. "' is not visible in the current picker results", vim.log.levels.INFO)
			    end
			    map("i", "<C-l>", focus_latest_selection)
			    map("n", "<C-l>", focus_latest_selection)
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
