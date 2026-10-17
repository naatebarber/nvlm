local config = require("nvlm.config")
local edit = require("nvlm.edit")
local prompt = require("nvlm.prompt")
local selection = require("nvlm.selection")
local ui = require("nvlm.ui")

local M = {}

-- Chat history (user/assistant/tool messages) for this Neovim session.
local history = {}
local job = nil

function M.setup(opts)
  config.setup(opts)
end

--- Entry point for :Lm. With a range, sends the selection plus the comment and
--- makes it the active selection the model may edit; without one, sends the
--- comment alone as a follow-up in the conversation.
function M.run(opts)
  local sel = selection.get(opts)
  local comment = vim.trim(opts.args)
  if not sel and comment == "" then
    vim.notify("nvlm: select some text, or ask a question (:Lm <question>)", vim.log.levels.ERROR)
    return
  end
  M.send(sel, comment ~= "" and comment or config.options.default_prompt)
end

--- Execute a tool call from the model, log it, and return the result for the model.
local function run_tool(call)
  local fn = call["function"]
  if fn.name ~= "replace_selection" then
    ui.append_item("error", "unknown tool: " .. fn.name)
    return "error: unknown tool " .. fn.name
  end

  local args = type(fn.arguments) == "string" and vim.json.decode(fn.arguments) or fn.arguments
  local applied, err = edit.replace_selection(args.code or "")
  if not applied then
    ui.append_item("error", "edit failed: " .. err)
    return "error: " .. err
  end

  local body = { "```" .. applied.filetype }
  vim.list_extend(body, applied.lines)
  table.insert(body, "```")
  ui.append_item("edit", ("Edited `%s` · `u` there to undo"):format(applied.where), body)
  return "Applied. The selection is now " .. applied.where .. " and contains exactly the code you provided."
end

---@param sel table|nil selection from nvlm.selection.get, or nil for a plain follow-up
---@param comment string
---@return boolean accepted false if the request couldn't be started
function M.send(sel, comment)
  local cfg = config.options

  if job then
    vim.notify("nvlm: a request is already running (:LmStop to cancel)", vim.log.levels.WARN)
    return false
  end

  local ok, provider = pcall(require, "nvlm.providers." .. cfg.provider)
  local provider_cfg = cfg.providers[cfg.provider]
  if not ok or not provider_cfg then
    vim.notify("nvlm: unknown or unconfigured provider '" .. cfg.provider .. "'", vim.log.levels.ERROR)
    return false
  end

  if sel then
    edit.set_target(sel)
  end

  local user_msg = { role = "user", content = sel and prompt.user_message(sel, comment) or comment }

  local messages = { { role = "system", content = cfg.system_prompt } }
  vim.list_extend(messages, history)
  table.insert(messages, user_msg)

  ui.open()
  local entry = ui.begin_entry(
    vim.split(comment, "\n", { plain = true }),
    sel and ("%s:%d-%d"):format(sel.filename, sel.start_line, sel.end_line)
  )

  local chunks, calls = {}, {}
  job = provider.request({
    messages = messages,
    tools = edit.has_target() and edit.tools or nil,
  }, provider_cfg, {
    on_delta = function(text)
      table.insert(chunks, text)
      ui.append_entry(entry, text)
    end,
    on_tool_call = function(call)
      table.insert(calls, call)
    end,
    on_done = function(err)
      job = nil
      ui.finish_entry(entry, err)
      -- Only completed exchanges become part of the conversation.
      if err then
        return
      end
      local reply = { role = "assistant", content = table.concat(chunks) }
      if #calls > 0 then
        reply.tool_calls = calls
      end
      table.insert(history, user_msg)
      table.insert(history, reply)
      for _, call in ipairs(calls) do
        table.insert(history, { role = "tool", tool_name = call["function"].name, content = run_tool(call) })
      end
    end,
  })
  return true
end

function M.stop()
  if job then
    job:kill("sigterm")
  end
end

function M.reset()
  M.stop()
  history = {}
  edit.clear_target()
  ui.clear()
end

return M
