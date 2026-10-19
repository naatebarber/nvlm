local config = require("nvlm.config")
local edit = require("nvlm.edit")
local prompt = require("nvlm.prompt")
local selection = require("nvlm.selection")
local tools = require("nvlm.tools")
local ui = require("nvlm.ui")

local M = {}

-- Chat history (user/assistant/tool messages) for this Neovim session.
local history = {}
local job = nil
-- Set by :LmDetach until the model has been told about it.
local detached = false
-- Where a rangeless :Lm was run, { bufnr, line }, until that file context is sent.
local cursor = nil
-- The file context the model last saw, so an unchanged file isn't resent.
local context_seen = nil

edit.on_status(ui.set_status)

function M.setup(opts)
  config.setup(opts)
end

--- Entry point for :Lm. With a range, the lines become the active selection the
--- model may edit, sent along with the comment, or just attached for the next
--- message if there's no comment. Without a range, the current file (around the
--- cursor) goes along as read-only context, with the comment or with the next
--- message typed into the chat.
function M.run(opts)
  local sel = selection.get(opts)
  local comment = vim.trim(opts.args)
  if sel then
    cursor = nil
  elseif config.options.context.enabled and vim.bo.buftype == "" then
    cursor = { bufnr = vim.api.nvim_get_current_buf(), line = vim.api.nvim_win_get_cursor(0)[1] }
  end
  if comment ~= "" then
    M.send(sel, comment)
    return
  end
  if sel then
    edit.set_target(sel)
    detached = false
  end
  ui.focus_input()
end

--- Run one round of the exchange: send the history (plus `ctx.user_msg` on the
--- first round), then run any tools the model called and go another round with
--- their results, until it answers without tools or a tool ends the turn.
---@param ctx table { provider, provider_cfg, user_msg, settle(err) }
---@param n integer round number, from 1
---@param entry table the log entry for this round's response
local function round(ctx, n, entry)
  local cfg = config.options
  local messages = { { role = "system", content = cfg.system_prompt } }
  vim.list_extend(messages, history)
  if n == 1 then
    table.insert(messages, ctx.user_msg)
  end

  local chunks, calls = {}, {}
  job = ctx.provider.request({ messages = messages, tools = tools.defs() }, ctx.provider_cfg, {
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
      if n == 1 then
        ctx.settle(err)
      end
      -- Only completed responses become part of the conversation.
      if err then
        return
      end
      if n == 1 then
        table.insert(history, ctx.user_msg)
      end
      local reply = { role = "assistant", content = table.concat(chunks) }
      if #calls > 0 then
        reply.tool_calls = calls
      end
      table.insert(history, reply)

      local wait = false
      for _, call in ipairs(calls) do
        local result, ends_turn = tools.run(call)
        table.insert(history, { role = "tool", tool_call_id = call.id, name = call.name, content = result })
        wait = wait or ends_turn
      end
      if #calls == 0 or wait then
        return
      end
      if n >= cfg.tools.max_rounds then
        ui.append_item("error", ("stopped after %d rounds of tool calls; send a message to continue"):format(n))
        return
      end
      round(ctx, n + 1, ui.begin_entry())
    end,
  })
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
  if not sel and edit.is_deleted() and edit.unseen() then
    edit.clear_target() -- deleted before the model ever saw it: nothing to tell
  end
  local deleted = not sel and edit.is_deleted()
  local was_detached = not sel and detached
  if sel then
    edit.set_target(sel, true)
    detached = false
    content = prompt.user_message(sel, comment)
    ref = ("%s:%d-%d"):format(sel.filename, sel.start_line, sel.end_line)
  elseif deleted then
    content = prompt.selection_deleted .. "\n\n" .. comment
    ref = "selection deleted"
  elseif was_detached then
    content = prompt.selection_detached .. "\n\n" .. comment
    ref = "selection detached"
  elseif edit.unseen() then
    -- Attached by a bare :'<,'>Lm; this is the model's first look at it.
    local snap = edit.snapshot()
    edit.sending(snap)
    content = prompt.user_message(snap, comment)
    ref = ("%s:%d-%d"):format(snap.filename, snap.start_line, snap.end_line)
  elseif edit.changed() then
    local snap = edit.snapshot()
    edit.sending(snap)
    content = prompt.selection_update(snap, comment)
    ref = ("%s:%d-%d (updated)"):format(snap.filename, snap.start_line, snap.end_line)
  else
    content = comment
  end

  -- Put the file the user is in first, unless the model already has it as is.
  local refs = { ref }
  local file = cursor and selection.context(cursor.bufnr, cursor.line, cfg.context.max_lines)
  local file_key = file and { bufnr = file.bufnr, tick = file.tick, start_line = file.start_line, end_line = file.end_line }
  if file then
    local where = ("%s:%d"):format(file.filename, file.cursor_line)
    if vim.deep_equal(file_key, context_seen) then
      content = prompt.cursor_note(file) .. "\n\n" .. content
    else
      content = prompt.file_context(file) .. "\n\n" .. content
      local whole = file.start_line == 1 and file.end_line == file.total
      where = where .. (whole and " (whole file)" or (" (lines %d-%d)"):format(file.start_line, file.end_line))
    end
    table.insert(refs, 1, where)
  end
  local user_msg = { role = "user", content = content }

  ui.open()
  local entry = ui.begin_entry(vim.split(comment, "\n", { plain = true }), refs)
  round({
    provider = provider,
    provider_cfg = provider_cfg,
    user_msg = user_msg,
    -- Settle what the model now knows about the selection once the first response ends.
    settle = function(err)
      if err then
        edit.abort() -- and `cursor` stays pending for the next message
        return
      end
      cursor = nil
      context_seen = file_key or context_seen
      if deleted then
        edit.clear_target()
      elseif was_detached then
        detached = false
      else
        edit.confirm()
      end
    end,
  }, 1, entry)
  return true
end

function M.stop()
  if job then
    job:kill("sigterm")
  end
end

function M.running()
  return job ~= nil
end

--- Stop tracking the active selection; the model is told on the next message.
---@return string|nil where the selection that was detached
---@return string|nil err
function M.detach()
  local status = edit.status()
  if not status then
    return nil, "no active selection"
  end
  -- Nothing to tell the model if it never saw the selection.
  detached = not edit.unseen()
  edit.clear_target()
  return status.where
end

function M.reset()
  M.stop()
  history = {}
  detached = false
  cursor = nil
  context_seen = nil
  edit.clear_target()
  ui.clear()
end

return M
