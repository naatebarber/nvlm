local config = require("nvlm.config")
local edit = require("nvlm.edit")
local prompt = require("nvlm.prompt")
local selection = require("nvlm.selection")
local ui = require("nvlm.ui")

local M = {}

-- Chat history (user/assistant/tool messages) for this Neovim session.
local history = {}
local job = nil
-- Set by :LmDetach until the model has been told about it.
local detached = false

edit.on_status(ui.set_status)

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
  if call.name ~= "replace_selection" then
    ui.append_item("error", "unknown tool: " .. tostring(call.name))
    return "error: unknown tool " .. tostring(call.name)
  end
  if type(call.arguments) ~= "table" or type(call.arguments.code) ~= "string" then
    ui.append_item("error", "edit failed: missing or malformed `code` argument")
    return "error: missing or malformed `code` argument"
  end

  local applied, err = edit.replace_selection(call.arguments.code)
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

  -- A provider entry's `kind` picks the implementation (defaults to its name).
  local provider_cfg = cfg.providers[cfg.provider]
  local ok, provider = pcall(require, "nvlm.providers." .. (provider_cfg and provider_cfg.kind or cfg.provider))
  if not ok or not provider_cfg then
    vim.notify("nvlm: unknown or unconfigured provider '" .. cfg.provider .. "'", vim.log.levels.ERROR)
    return false
  end
  if not provider_cfg.model then
    vim.notify("nvlm: set providers." .. cfg.provider .. ".model", vim.log.levels.ERROR)
    return false
  end

  -- Build the message, bringing the model up to date on the active selection if
  -- it changed (or was deleted) since the model last saw it.
  local content, ref
  local deleted = not sel and edit.is_deleted()
  local was_detached = not sel and detached
  if sel then
    edit.set_target(sel)
    detached = false
    content = prompt.user_message(sel, comment)
    ref = ("%s:%d-%d"):format(sel.filename, sel.start_line, sel.end_line)
  elseif deleted then
    content = prompt.selection_deleted .. "\n\n" .. comment
    ref = "selection deleted"
  elseif was_detached then
    content = prompt.selection_detached .. "\n\n" .. comment
    ref = "selection detached"
  elseif edit.changed() then
    local snap = edit.snapshot()
    edit.sending(snap)
    content = prompt.selection_update(snap, comment)
    ref = ("%s:%d-%d (updated)"):format(snap.filename, snap.start_line, snap.end_line)
  else
    content = comment
  end
  local user_msg = { role = "user", content = content }

  local messages = { { role = "system", content = cfg.system_prompt } }
  vim.list_extend(messages, history)
  table.insert(messages, user_msg)

  ui.open()
  local entry = ui.begin_entry(vim.split(comment, "\n", { plain = true }), ref)

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
        edit.abort()
        return
      end
      if deleted then
        edit.clear_target()
      elseif was_detached then
        detached = false
      else
        edit.confirm()
      end
      local reply = { role = "assistant", content = table.concat(chunks) }
      if #calls > 0 then
        reply.tool_calls = calls
      end
      table.insert(history, user_msg)
      table.insert(history, reply)
      for _, call in ipairs(calls) do
        table.insert(history, { role = "tool", tool_call_id = call.id, name = call.name, content = run_tool(call) })
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

--- Stop tracking the active selection; the model is told on the next message.
function M.detach()
  if not edit.has_target() and not edit.is_deleted() then
    vim.notify("nvlm: no active selection", vim.log.levels.WARN)
    return
  end
  edit.clear_target()
  -- Nothing to tell the model if it never had the selection in its history.
  detached = #history > 0
end

function M.reset()
  M.stop()
  history = {}
  detached = false
  edit.clear_target()
  ui.clear()
end

return M
