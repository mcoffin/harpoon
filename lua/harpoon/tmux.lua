local harpoon = require("harpoon")
local log = require("harpoon.dev").log
local global_config = harpoon.get_global_settings()
local utils = require("harpoon.utils")

local M = {}
if global_config.tmux_autoclose_windows then
    local harpoon_tmux_group = vim.api.nvim_create_augroup(
        "HARPOON_TMUX",
        { clear = true }
    )

    vim.api.nvim_create_autocmd("VimLeave", {
        callback = function()
            require("harpoon.tmux").clear_all()
        end,
        group = harpoon_tmux_group,
    })
end

local default_options = {}
local tmux_options = default_options

local function create_terminal(args)
    log.trace("tmux: _create_terminal())")

    local window_id
    local real_window_id

    -- Create a new tmux window and store the window id
    local tmux_command = {
        "tmux",
        "new-window",
        "-P",
        "-F",
        "#{pane_id}:#{window_id}",
    }
    local window_name_opt = nil
    if tmux_options.window_name then
        if type(tmux_options.window_name) == 'string' then
            table.insert(tmux_command, '-n')
            table.insert(tmux_command, tmux_options.window_name)
        else
            window_name_opt = tmux_options.window_name
        end
    end
    local out, ret, _ = utils.get_os_command_output(
        tmux_command,
        vim.loop.cwd()
    )

    if ret == 0 then
        -- local full_id = string.gmatch(out[1], ':')
        local full_id = utils.split_string(out[1], ':')
        -- this is really the pane id
        window_id = full_id[1]:sub(2)
        real_window_id = full_id[2]
    end

    if window_id == nil then
        log.error("tmux: _create_terminal(): window_id is nil")
        return nil
    end

    if type(window_name_opt) == 'function' then
        local _, ret, stderr = utils.get_os_command_output({
            "tmux",
            "rename-window",
            "-t",
            real_window_id,
            window_name_opt(args, window_id, real_window_id),
        }, vim.loop.cwd())
    end

    return window_id
end

-- Tries to find the given pane, returning a switch-client target string if
-- found, returning nil if not
local function terminal_location(pane_id)
    log.trace("_terminal_location(): Window:", window_id)
    local locations, _, _ = utils.get_os_command_output({
        "tmux",
        "list-panes",
        "-s",
        "-f", "#{==:#{pane_id}," .. pane_id .. "}",
        "-F", "#{session_name}:#{window_id}.#{pane_id}"
    }, vim.loop.cwd())
    if #locations < 1 then
        return nil
    else
        return locations[1]
    end
end

local window_handle_base = {}
function window_handle_base:new(opts)
    opts = opts or {}
    setmetatable(opts, self)
    self.__index = self
    return opts
end
function window_handle_base:target_info()
    local locations, _, _ = utils.get_os_command_output({
        "tmux",
        "list-panes",
        "-s",
        "-f", "#{==:#{pane_id}," .. self.window_id .. "}",
        "-F", "#{session_name}:#{window_id}.#{pane_id}"
    }, vim.loop.cwd())
    if #locations < 1 then
        return nil
    else
        return locations[1]
    end
end
function window_handle_base:make_current()
    local _, ret, stderr = utils.get_os_command_output({
        "tmux",
        "switch-client",
        "-t", self:target_info()
    })
    if ret ~= 0 then
        error("Failed to go to terminal: " .. stderr[1])
    end
end
function window_handle_base:exists()
    local _, ret, _ = utils.get_os_command_output({
        "tmux",
        "has-session",
        "-t", self.window_id,
    }, vim.loop.cwd())
    return ret == 0
end
function window_handle_base:kill_window(opts)
    opts = opts or {}
    setmetatable(opts, {
        __index = {
            command = "kill-pane",
        }
    })
    local _, ret, stderr = utils.get_os_command_output({
        "tmux",
        opts.command,
        "-t",
        self.window_id
    }, vim.loop.cwd())
    if ret ~= 0 and self:exists() then
        error("Failed to kill running window: " .. stderr[1])
    end
end
function window_handle_base:send_keys(cmd, ...)
    local _, ret, stderr = utils.get_os_command_output({
        "tmux",
        "send-keys",
        "-t",
        self.window_id,
        string.format(cmd, ...)
    })
    if ret ~= 0 then
        error('error sending command to terminal at ' .. self.window_id .. ': ' .. stderr[1])
    end
end

local tmux_windows = setmetatable({}, {
    __index = function(table, key)
        if type(key) == 'string' and string.len(key) > 0 then
            return window_handle_base:new({
                window_id = key,
            })
        end
    end,
})

local function find_terminal(args)
    log.trace("tmux: _find_terminal(): Window:", args)

    local window_handle = tmux_windows[args]

    if type(args) == 'number' and (not window_handle or not window_handle:exists()) then
        local window_id = create_terminal(args)

        if window_id == nil then
            error("Failed to find and create tmux window.")
            return
        end

        window_handle = window_handle_base:new({
            window_id = "%" .. window_id,
        })

        tmux_windows[args] = window_handle
    end
    return window_handle
end

local function get_first_empty_slot()
    log.trace("_get_first_empty_slot()")
    for idx, cmd in pairs(harpoon.get_term_config().cmds) do
        if cmd == "" then
            return idx
        end
    end
    return M.get_length() + 1
end

function M.gotoTerminal(idx)
    log.trace("tmux: gotoTerminal(): Window:", idx)
    local window_handle = find_terminal(idx)
    window_handle:make_current()
end

function M.sendCommand(idx, cmd, ...)
    log.trace("tmux: sendCommand(): Window:", idx)
    local window_handle = find_terminal(idx)

    if type(cmd) == "number" then
        cmd = harpoon.get_term_config().cmds[cmd]
    end

    if global_config.enter_on_sendcmd then
        cmd = cmd .. "\n"
    end

    if cmd then
        log.debug("sendCommand:", cmd)
        window_handle:send_keys(cmd, ...)
    end
end

function M.clear_all()
    log.trace("tmux: clear_all(): Clearing all tmux windows.")

    for _, window in pairs(tmux_windows) do
        -- Delete the current tmux window
        window:kill_window()
    end

    tmux_windows = {}
end

function M.get_length()
    log.trace("_get_length()")
    return table.maxn(harpoon.get_term_config().cmds)
end

function M.valid_index(idx)
    if idx == nil or idx > M.get_length() or idx <= 0 then
        return false
    end
    return true
end

function M.emit_changed()
    log.trace("_emit_changed()")
    if harpoon.get_global_settings().save_on_change then
        harpoon.save()
    end
end

function M.add_cmd(cmd)
    log.trace("add_cmd()")
    local found_idx = get_first_empty_slot()
    harpoon.get_term_config().cmds[found_idx] = cmd
    M.emit_changed()
end

function M.rm_cmd(idx)
    log.trace("rm_cmd()")
    if not M.valid_index(idx) then
        log.debug("rm_cmd(): no cmd exists for index", idx)
        return
    end
    table.remove(harpoon.get_term_config().cmds, idx)
    M.emit_changed()
end

function M.set_cmd_list(new_list)
    log.trace("set_cmd_list(): New list:", new_list)
    for k in pairs(harpoon.get_term_config().cmds) do
        harpoon.get_term_config().cmds[k] = nil
    end
    for k, v in pairs(new_list) do
        harpoon.get_term_config().cmds[k] = v
    end
    M.emit_changed()
end

function M.setup(opts)
    tmux_options = setmetatable(opts, {
        __index = default_options,
    })
end

return M
