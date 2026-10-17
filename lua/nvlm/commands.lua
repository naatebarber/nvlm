local config = require("nvlm.config")

-- Slash commands typed into the chat input pane.
local M = {}

local commands
commands = {
  {
    name = "stop",
    desc = "Cancel the running request",
    run = function()
      return nil, "nothing is running"
    end,
  },
  {
    name = "detach",
    desc = "Stop tracking the active selection",
    run = function()
      local where, err = require("nvlm").detach()
      return where and { "Detached " .. where }, err
    end,
  },
  {
    name = "reset",
    aliases = { "clear" },
    desc = "Clear the conversation and the log",
    run = function()
      require("nvlm").reset()
    end,
  },
  {
    name = "model",
    args = "[name]",
    desc = "Show or set the model",
    run = function(arg)
      local opts = config.options
      local provider = opts.providers[opts.provider]
      if arg then
        provider.model = arg
      end
      return { ("%s · %s"):format(opts.provider, provider.model or "(no model set)") }
    end,
  },
  {
    name = "provider",
    args = "[name]",
    desc = "List providers or switch to one",
    run = function(arg)
      local opts = config.options
      if arg then
        if not opts.providers[arg] then
          return nil, "unknown provider: " .. arg
        end
        opts.provider = arg
        return { ("%s · %s"):format(arg, opts.providers[arg].model or "(no model set)") }
      end
      local names = vim.tbl_keys(opts.providers)
      table.sort(names)
      return vim.tbl_map(function(name)
        return (name == opts.provider and "● " or "  ") .. name .. " · " .. (opts.providers[name].model or "?")
      end, names)
    end,
  },
  {
    name = "help",
    desc = "List commands",
    run = function()
      return vim.tbl_map(function(cmd)
        local usage = "/" .. cmd.name .. (cmd.args and " " .. cmd.args or "")
        return ("%-18s %s"):format(usage, cmd.desc)
      end, commands)
    end,
  },
}

local function find(name)
  for _, cmd in ipairs(commands) do
    if cmd.name == name or vim.tbl_contains(cmd.aliases or {}, name) then
      return cmd
    end
  end
end

--- Run a slash command line such as "/model qwen3.8:27b".
---@param line string
---@return boolean accepted false if it was refused and should stay in the input
function M.run(line)
  local name, arg = line:match("^/(%S*)%s*(.-)%s*$")
  local nvlm, ui = require("nvlm"), require("nvlm.ui")

  -- Output goes at the end of the log, so don't interleave it with a streaming reply.
  if nvlm.running() then
    if name == "stop" then
      nvlm.stop() -- the reply's "cancelled" error marks it in the log
      return true
    end
    vim.notify("nvlm: wait for the response, or /stop it", vim.log.levels.WARN)
    return false
  end

  local cmd = find(name)
  if not cmd then
    ui.append_command(line, { "unknown command; try /help" }, true)
    return true
  end
  local lines, err = cmd.run(arg ~= "" and arg or nil)
  if err then
    ui.append_command(line, { err }, true)
  elseif lines then
    ui.append_command(line, lines)
  end
  return true
end

return M
