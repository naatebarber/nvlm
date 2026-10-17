local config = require("nvlm.config")
local prompt = require("nvlm.prompt")
local selection = require("nvlm.selection")
local ui = require("nvlm.ui")

local M = {}

-- Chat history (user/assistant messages) for this Neovim session.
local history = {}
local job = nil

function M.setup(opts)
  config.setup(opts)
end

function M.run(opts)
  local cfg = config.options

  if job then
    vim.notify("nvlm: a request is already running (:LmStop to cancel)", vim.log.levels.WARN)
    return
  end

  local sel = selection.get(opts)
  if not sel then
    vim.notify("nvlm: select some text first (e.g. V then :Lm ...)", vim.log.levels.ERROR)
    return
  end

  local ok, provider = pcall(require, "nvlm.providers." .. cfg.provider)
  local provider_cfg = cfg.providers[cfg.provider]
  if not ok or not provider_cfg then
    vim.notify("nvlm: unknown or unconfigured provider '" .. cfg.provider .. "'", vim.log.levels.ERROR)
    return
  end

  local comment = vim.trim(opts.args) ~= "" and opts.args or cfg.default_prompt
  local user_msg = { role = "user", content = prompt.user_message(sel, comment) }

  local messages = { { role = "system", content = cfg.system_prompt } }
  vim.list_extend(messages, history)
  table.insert(messages, user_msg)

  ui.open(cfg.ui)
  local entry = ui.begin_entry({
    "## " .. comment,
    ("`%s:%d-%d`"):format(sel.filename, sel.start_line, sel.end_line),
  })

  local chunks = {}
  job = provider.request(messages, provider_cfg, function(text)
    table.insert(chunks, text)
    ui.append_entry(entry, text)
  end, function(err)
    job = nil
    ui.finish_entry(entry, err)
    -- Only completed exchanges become part of the conversation.
    if not err then
      table.insert(history, user_msg)
      table.insert(history, { role = "assistant", content = table.concat(chunks) })
    end
  end)
end

function M.stop()
  if job then
    job:kill("sigterm")
  end
end

function M.reset()
  M.stop()
  history = {}
  ui.clear()
end

return M
