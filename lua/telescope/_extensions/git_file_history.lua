local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
    error("This plugin requires nvim-telescope/telescope.nvim")
end

local has_plenary, pfiletype = pcall(require, "plenary.filetype")
if not has_plenary then
    error("This plugin requires nvim-lua/plenary.nvim")
end

if vim.fn.executable("git") == 0 then
    error("This plugin requires git to be installed")
end

local action_set = require("telescope.actions.set")
local action_state = require("telescope.actions.state")
local actions = require("telescope.actions")
local conf = require("telescope.config").values
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local previewers = require("telescope.previewers")
local preview_utils = require("telescope.previewers.utils")
local entry_display = require("telescope.pickers.entry_display")
local gfh_actions = require("telescope._extensions.git_file_history.actions")
local gfh_config = require("telescope._extensions.git_file_history.config")

local function is_git_directory()
    local result = vim.fn.system("git rev-parse --is-inside-work-tree")
    return result:sub(1, 4) == "true"
end

local function get_git_root(file_path)
    local directory = vim.fn.fnamemodify(file_path, ":h")
    local cmd = string.format(
        "git -C %s rev-parse --show-toplevel",
        vim.fn.shellescape(directory)
    )
    local root = vim.fn.system(cmd)

    if vim.v.shell_error ~= 0 then
        error("Failed to detect git root: " .. vim.trim(root))
    end

    return vim.trim(root)
end

local function relpath_from_root(file_path, root)
    if root == "" or file_path == "" then
        return file_path
    end

    if file_path:sub(1, #root) == root then
        local rel = file_path:sub(#root + 1)

        if rel:sub(1, 1) == "/" or rel:sub(1, 1) == "\\" then
            rel = rel:sub(2)
        end

        return rel
    end

    return file_path
end

local function git_log()
    local file_path = vim.fn.expand("%:p")
    if file_path == "" then
        error("No file path available for git history")
    end

    local repo_root = get_git_root(file_path)
    local rel_path = relpath_from_root(file_path, repo_root)
    local escaped_root = vim.fn.shellescape(repo_root)

    local prefix =
        "git -C "
        .. escaped_root
        .. ' -c core.quotepath=false --no-pager log --follow --name-status --pretty=format:"hash: %H%ndate: %ad%nmessage: %s%n" --date=short '

    local cmd = prefix .. vim.fn.shellescape(rel_path)
    local content = vim.fn.system(cmd)

    local commits = {}
    local current_commit = {}

    for line in content:gmatch("[^\n]+") do
        if line:match("^hash:") then
            if next(current_commit) then
                table.insert(commits, current_commit)
            end

            current_commit = {
                hash = line:match("^hash: (.+)$"),
                repo_root = repo_root,
            }
        elseif line:match("^date:") then
            current_commit.date = line:match("^date: (.+)$")
        elseif line:match("^message:") then
            current_commit.message = line:match("^message: (.+)$")
        elseif line:match("^%S") then
            local type, remainder = line:match("^(%S+)%s+(.+)$")
            current_commit.type = type

            if remainder then
                local old_name, new_name = remainder:match("^(.-)\t(.*)$")

                if not old_name or old_name == "" then
                    old_name = remainder
                    new_name = ""
                end

                current_commit.old_name =
                    old_name and old_name:gsub("%s+$", "") or ""

                current_commit.new_name =
                    new_name and new_name:gsub("^%s+", "") or ""

                current_commit.path =
                    #current_commit.new_name > 0
                    and current_commit.new_name
                    or current_commit.old_name
            end
        elseif line == "" and next(current_commit) then
            table.insert(commits, current_commit)
            current_commit = {}
        end
    end

    if next(current_commit) then
        table.insert(commits, current_commit)
    end

    local stash_cmd = string.format(
        'git -C %s -c core.quotepath=false --no-pager log -g refs/stash --format="%%gd%%x09%%H%%x09%%cs%%x09%%s" -- %s',
        escaped_root,
        vim.fn.shellescape(rel_path)
    )

    local stash_content = vim.fn.system(stash_cmd)

    if vim.v.shell_error == 0 then
        local stashes = {}

        for line in stash_content:gmatch("[^\n]+") do
            local stash_ref, hash, date, message =
                line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")

            if stash_ref then
                table.insert(stashes, {
                    hash = hash,
                    date = date,
                    message = message,
                    repo_root = repo_root,
                    path = rel_path,
                    is_stash = true,
                    stash_ref = stash_ref,
                })
            end
        end

        for i = #stashes, 1, -1 do
            table.insert(commits, 1, stashes[i])
        end
    end

    local worktree_diff = vim.fn.system(string.format(
        "git -C %s -c core.quotepath=false --no-pager diff --name-only HEAD -- %s",
        escaped_root,
        vim.fn.shellescape(rel_path)
    ))

    local has_worktree_diff =
        worktree_diff and vim.trim(worktree_diff) ~= ""

    table.insert(commits, 1, {
        hash = "WORKTREE",
        date = os.date("%Y-%m-%d"),
        message = has_worktree_diff
            and "[Working tree vs HEAD]"
            or "[Working tree clean]",
        repo_root = repo_root,
        path = rel_path,
        is_worktree = true,
        worktree_clean = not has_worktree_diff,
    })

    return commits
end

local function git_diff(entry)
    local root = entry.repo_root or get_git_root(vim.fn.expand("%:p"))
    local escaped_root = vim.fn.shellescape(root)
    local cmd

    if entry.is_worktree then
        cmd = string.format(
            "git -C %s -c core.quotepath=false --no-pager diff HEAD -- %s",
            escaped_root,
            vim.fn.shellescape(entry.path)
        )
    elseif entry.is_stash then
        cmd = string.format(
            "git -C %s -c core.quotepath=false --no-pager diff %s^1 %s -- %s",
            escaped_root,
            entry.value,
            entry.value,
            vim.fn.shellescape(entry.path)
        )
    else
        cmd = string.format(
            "git -C %s -c core.quotepath=false --no-pager diff %s^! -- %s",
            escaped_root,
            entry.value,
            vim.fn.shellescape(entry.path)
        )
    end

    local result = vim.fn.system(cmd)

    if vim.v.shell_error ~= 0 then
        return nil, result
    end

    return result, nil
end

local function focus_first_hunk(bufnr)
    local target = nil
    local lines = vim.api.nvim_buf_get_lines(
        bufnr,
        0,
        -1,
        false
    )

    for idx, line in ipairs(lines) do
        if line:match("^@@")
            or line:match("^%+[^+]")
            or line:match("^%-[^-]")
        then
            target = idx
            break
        end
    end

    vim.api.nvim_buf_call(bufnr, function()
        if target then
            vim.api.nvim_win_set_cursor(0, { target, 0 })
        else
            vim.cmd("normal! gg")
        end
    end)
end

local function git_file_history(opts)
    opts = opts or {}

    if not is_git_directory() then
        error(vim.fn.getcwd() .. " is not a git directory")
    end

    pickers
        .new(opts, {
            results_title = "Commits for current file",

            finder = finders.new_table({
                results = git_log(),

                entry_maker = function(entry)
                    local displayer = entry_display.create({
                        separator = " ",
                        items = {
                            { width = 10 },
                            { width = 10 },
                            { remaining = true },
                        },
                    })

                    local short_hash

                    if entry.is_worktree then
                        short_hash = "WORK"
                    elseif entry.is_stash then
                        short_hash = entry.stash_ref
                    else
                        short_hash = string.sub(
                            entry.hash or "",
                            1,
                            7
                        )
                    end

                    local date = entry.date or ""
                    local message = entry.message or ""

                    return {
                        value = entry.hash,

                        display = function()
                            return displayer({
                                {
                                    date,
                                    "TelescopeResultsConstant",
                                },
                                {
                                    short_hash,
                                    "TelescopeResultsIdentifier",
                                },
                                message,
                            })
                        end,

                        ordinal =
                            (entry.stash_ref or entry.hash or "")
                            .. date
                            .. message,

                        path = entry.path,
                        repo_root = entry.repo_root,
                        is_worktree = entry.is_worktree,
                        worktree_clean = entry.worktree_clean,
                        is_stash = entry.is_stash,
                        stash_ref = entry.stash_ref,
                    }
                end,
            }),

            sorter = conf.file_sorter(opts),

            attach_mappings = function(prompt_bufnr, map)
                local function resume_picker()
                    local ok, builtin =
                        pcall(require, "telescope.builtin")

                    if ok then
                        pcall(builtin.resume)
                    end
                end

                local function open(cmd, after_open)
                    local selection =
                        action_state.get_selected_entry()

                    if selection.is_worktree then
                        actions.close(prompt_bufnr)

                        vim.notify(
                            "Working tree entry cannot be opened via fugitive command",
                            vim.log.levels.INFO
                        )

                        return
                    end

                    local hash = selection.value
                    local path = selection.path

                    actions.close(prompt_bufnr)

                    local command =
                        cmd
                        .. hash
                        .. ":"
                        .. (
                            path:find(" ")
                            and ('"' .. path .. '"')
                            or path
                        )

                    vim.cmd(command)

                    if after_open then
                        after_open()
                    end
                end

                action_set.select:replace(function()
                    open("Gedit ")
                end)

                actions.select_tab:replace(function()
                    open("Gtabedit ", function()
                        vim.cmd("tabprevious")
                        resume_picker()
                    end)
                end)

                actions.select_horizontal:replace(function()
                    open("Gsplit ")
                end)

                actions.select_vertical:replace(function()
                    open("Gvsplit ")
                end)

                for mode, tbl in pairs(
                    gfh_config.values.mappings
                ) do
                    for key, action in pairs(tbl) do
                        map(mode, key, action)
                    end
                end

                return true
            end,

            previewer =
                previewers.new_buffer_previewer({
                    title = "Diff for selected commit",

                    get_buffer_by_name = function(
                        _,
                        entry
                    )
                        return
                            (entry.value or "WORKTREE")
                            .. ":"
                            .. (entry.path or "")
                    end,

                    define_preview = function(
                        self,
                        entry,
                        _
                    )
                        if not entry or not entry.path then
                            vim.api.nvim_buf_set_lines(
                                self.state.bufnr,
                                0,
                                -1,
                                false,
                                {
                                    "No file selected.",
                                }
                            )

                            return
                        end

                        local bufname =
                            (entry.value or "WORKTREE")
                            .. ":"
                            .. entry.path

                        if self.state.bufname == bufname then
                            return
                        end

                        local content, err =
                            git_diff(entry)

                        local lines

                        if not content or content == "" then
                            if entry.is_worktree
                                and entry.worktree_clean
                            then
                                lines = {
                                    "Working tree is clean for this file.",
                                }
                            else
                                lines = {
                                    err
                                        and (
                                            "git diff failed: "
                                            .. vim.trim(err)
                                        )
                                        or "No changes in this commit for file.",
                                }
                            end
                        else
                            lines = vim.split(
                                content,
                                "\n",
                                {
                                    plain = true,
                                }
                            )
                        end

                        vim.api.nvim_buf_set_lines(
                            self.state.bufnr,
                            0,
                            -1,
                            false,
                            lines
                        )

                        preview_utils.highlighter(
                            self.state.bufnr,
                            "diff"
                        )

                        focus_first_hunk(
                            self.state.bufnr
                        )
                    end,
                }),
        })
        :find()
end

return telescope.register_extension({
    setup = gfh_config.setup,

    exports = {
        git_file_history = git_file_history,
        actions = gfh_actions,
    },
})
