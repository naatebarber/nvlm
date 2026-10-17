local M = {}

local ns = vim.api.nvim_create_namespace("nvlm_selection")
local flash_ns = vim.api.nvim_create_namespace("nvlm_flash")

-- The active selection the model may edit: { buf, id, filename, filetype }.
-- Tracked with an extmark so it follows edits made while the chat goes on.
local target = nil

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

---@param sel table from nvlm.selection.get
function M.set_target(sel)
  M.clear_target()
  target = {
    buf = sel.bufnr,
    id = set_mark(sel.bufnr, sel.start_line - 1, sel.end_line - 1),
    filename = sel.filename,
    filetype = sel.filetype,
  }
end

function M.clear_target()
  if target and vim.api.nvim_buf_is_valid(target.buf) then
    vim.api.nvim_buf_del_extmark(target.buf, ns, target.id)
  end
  target = nil
end

function M.has_target()
  return range() ~= nil
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
  flash(target.buf, start_row, new_end)
  return {
    where = ("%s:%d-%d"):format(target.filename, start_row + 1, new_end + 1),
    lines = lines,
    filetype = target.filetype,
  }
end

return M
