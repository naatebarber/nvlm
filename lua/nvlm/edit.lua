local M = {}

local ns = vim.api.nvim_create_namespace("nvlm_selection")
local sign_ns = vim.api.nvim_create_namespace("nvlm_selection_signs")
local flash_ns = vim.api.nvim_create_namespace("nvlm_flash")

-- The active selection the model may edit:
--   buf, id: extmark tracking its lines, so it follows edits around it
--   filename, filetype
--   seen: what the model has confirmed seeing, { lines, start_line } (nil if never)
--   sent: what the request in flight includes, confirmed on success
local target = nil

-- Called with the selection's status whenever it may have changed.
local listener = function(_) end

-- Bumped per target so stale buffer watchers detach themselves.
local generation = 0

M.tools = {
  {
    type = "function",
    ["function"] = {
      name = "replace_selection",
      description = table.concat({
        "Replace the user's selected lines in their editor with new code.",
        "Provide the complete replacement for the whole selection (not a diff or a fragment),",
        "keeping the original indentation, without line-number prefixes or markdown fences.",
        "Only call this when the user asks for a change.",
      }, " "),
      parameters = {
        type = "object",
        properties = {
          code = { type = "string", description = "The full replacement text for the selected lines." },
        },
        required = { "code" },
      },
    },
  },
}

local function set_mark(buf, start_row, end_row, id)
  local last = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
  return vim.api.nvim_buf_set_extmark(buf, ns, start_row, 0, {
    id = id,
    end_row = end_row,
    end_col = #last,
    end_right_gravity = true,
    invalidate = true,
  })
end

--- Current 0-based, inclusive row range of the target, or nil if it's gone.
local function range()
  if not target or not vim.api.nvim_buf_is_valid(target.buf) then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(target.buf, ns, target.id, { details = true })
  if #mark == 0 or mark[3].invalid then
    return nil
  end
  return mark[1], mark[3].end_row
end

local function flash(buf, start_row, end_row)
  vim.api.nvim_buf_set_extmark(buf, flash_ns, start_row, 0, {
    end_row = end_row + 1,
    hl_group = "IncSearch",
    hl_eol = true,
    strict = false,
  })
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
    end
  end, 500)
end

-- Selections are sent to the model as "12: code"; undo it if the model echoes that back.
local function strip_line_numbers(lines)
  for _, line in ipairs(lines) do
    if not line:match("^%d+:") then
      return lines
    end
  end
  return vim.tbl_map(function(line)
    return (line:gsub("^%d+:%s?", ""))
  end, lines)
end

--- The target's current contents, in the same shape as nvlm.selection.get.
---@return table|nil
function M.snapshot()
  local start_row, end_row = range()
  if not start_row then
    return nil
  end
  return {
    bufnr = target.buf,
    lines = vim.api.nvim_buf_get_lines(target.buf, start_row, end_row + 1, false),
    start_line = start_row + 1,
    end_line = end_row + 1,
    filename = target.filename,
    filetype = target.filetype,
  }
end

local function view(snap)
  return { lines = snap.lines, start_line = snap.start_line }
end

--- Whether the target differs from what the model has seen or is being sent.
---@param contents_only boolean|nil ignore the selection merely moving (lines added above it)
function M.changed(contents_only)
  local snap = M.snapshot()
  local baseline = target and (target.sent or target.seen)
  if not snap then
    return false
  end
  if not baseline then
    return true
  end
  return not vim.deep_equal(snap.lines, baseline.lines)
    or (not contents_only and snap.start_line ~= baseline.start_line)
end

---@return table|nil { where, state = "ok"|"modified"|"deleted" }
function M.status()
  if not target then
    return nil
  end
  local snap = M.snapshot()
  if not snap then
    return { where = target.filename, state = "deleted" }
  end
  return {
    where = ("%s:%d-%d"):format(snap.filename, snap.start_line, snap.end_line),
    state = M.changed(true) and "modified" or "ok",
  }
end

--- Redraw the sign-column bar and notify the listener.
local function refresh()
  if target and vim.api.nvim_buf_is_valid(target.buf) then
    vim.api.nvim_buf_clear_namespace(target.buf, sign_ns, 0, -1)
    local start_row, end_row = range()
    for row = start_row or 0, end_row or -1 do
      vim.api.nvim_buf_set_extmark(target.buf, sign_ns, row, 0, { sign_text = "▎", sign_hl_group = "NvlmSelection" })
    end
  end
  listener(M.status())
end

-- Refresh as the target's buffer changes (typing, undo, ...), coalesced per tick.
local function watch(buf)
  generation = generation + 1
  local gen, scheduled = generation, false
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if gen ~= generation then
        return true -- detach: this buffer no longer holds the target
      end
      if not scheduled then
        scheduled = true
        vim.schedule(function()
          scheduled = false
          if gen == generation then
            refresh()
          end
        end)
      end
    end,
  })
end

---@param fn fun(status: table|nil)
function M.on_status(fn)
  listener = fn
end

---@param sel table from nvlm.selection.get; its lines are being sent to the model
function M.set_target(sel)
  M.clear_target()
  target = {
    buf = sel.bufnr,
    id = set_mark(sel.bufnr, sel.start_line - 1, sel.end_line - 1),
    filename = sel.filename,
    filetype = sel.filetype,
    sent = view(sel),
  }
  watch(sel.bufnr)
  refresh()
end

function M.clear_target()
  if target and vim.api.nvim_buf_is_valid(target.buf) then
    vim.api.nvim_buf_del_extmark(target.buf, ns, target.id)
    vim.api.nvim_buf_clear_namespace(target.buf, sign_ns, 0, -1)
  end
  target = nil
  generation = generation + 1
  listener(nil)
end

function M.has_target()
  return range() ~= nil
end

--- Whether there is a target whose lines have been deleted.
function M.is_deleted()
  return target ~= nil and range() == nil
end

--- Record that `snap` is being sent to the model in the request in flight.
function M.sending(snap)
  if target then
    target.sent = view(snap)
  end
end

--- The request in flight finished: whatever was sent has now been seen.
function M.confirm()
  if target then
    target.seen = target.sent or target.seen
    target.sent = nil
  end
  refresh()
end

--- The request in flight failed or was cancelled: the model never saw what was sent.
function M.abort()
  if target then
    target.sent = nil
  end
  refresh()
end

--- Move the cursor to the target, in a window already showing its buffer if possible.
function M.jump()
  local snap = M.snapshot()
  if not snap then
    vim.notify("nvlm: no active selection", vim.log.levels.WARN)
    return
  end
  local fallback
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if buf == snap.bufnr then
      fallback = win
      break
    end
    if not fallback and not vim.api.nvim_buf_get_name(buf):match("^nvlm://") then
      fallback = win
    end
  end
  if not fallback then
    return
  end
  vim.api.nvim_set_current_win(fallback)
  vim.api.nvim_win_set_buf(fallback, snap.bufnr)
  vim.api.nvim_win_set_cursor(fallback, { snap.start_line, 0 })
end

--- Replace the target's lines with `code` as a single undo step.
---@return table|nil { where, lines, filetype }
---@return string|nil err
function M.replace_selection(code)
  local start_row, end_row = range()
  if not start_row then
    return nil, "the selection no longer exists"
  end

  local lines = strip_line_numbers(vim.split((code:gsub("\n$", "")), "\n", { plain = true }))
  local ok, err = pcall(vim.api.nvim_buf_set_lines, target.buf, start_row, end_row + 1, false, lines)
  if not ok then
    return nil, err
  end

  local new_end = start_row + #lines - 1
  set_mark(target.buf, start_row, new_end, target.id)
  -- The model wrote these lines, so it has seen them.
  target.seen, target.sent = { lines = lines, start_line = start_row + 1 }, nil
  flash(target.buf, start_row, new_end)
  refresh()
  return {
    where = ("%s:%d-%d"):format(target.filename, start_row + 1, new_end + 1),
    lines = lines,
    filetype = target.filetype,
  }
end

return M
