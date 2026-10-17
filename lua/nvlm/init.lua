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

--- Entry point for :Lm. With a range, sends the selection plus the comment;
--- without one, sends the comment alone as a follow-up in the conversation.
function M.run(opts)
  local sel = selection.get(opts)
  local comment = vim.trim(opts.args)
  if not sel and comment == "" then
    vim.notify("nvlm: select some text, or ask a question (:Lm <question>)", vim.log.levels.ERROR)
    return
  end
  M.send(sel, comment ~= "" and comment or config.options.default_prompt)
end

--- Prompt for a follow-up question (used by the chat window keymaps).
function M.ask()
  vim.ui.input({ prompt = "nvlm> " }, function(input)
    if input and vim.trim(input) ~= "" then
      M.send(nil, vim.trim(input))
    end
  end)
end

---@param sel table|nil selection from nvlm.selection.get, or nil for a plain follow-up
---@param comment string
function M.send(sel, comment)
  local cfg = config.options

  if job then
    vim.notify("nvlm: a request is already running (:LmStop to cancel)", vim.log.levels.WARN)
    return
  end

  local ok, provider = pcall(require, "nvlm.providers." .. cfg.provider)
  local provider_cfg = cfg.providers[cfg.provider]
  if not ok or not provider_cfg then
    vim.notify("nvlm: unknown or unconfigured provider '" .. cfg.provider .. "'", vim.log.levels.ERROR)
    return
  end

  local user_msg = { role = "user", content = sel and prompt.user_message(sel, comment) or comment }

  local messages = { { role = "system", content = cfg.system_prompt } }
  vim.list_extend(messages, history)
  table.insert(messages, user_msg)

  local header = { "## " .. comment }
  if sel then
    table.insert(header, ("`%s:%d-%d`"):format(sel.filename, sel.start_line, sel.end_line))
  end

  ui.open(cfg.ui)
  local entry = ui.begin_entry(header)

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
