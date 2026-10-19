local M = {}

local function display_name(bufnr)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  return filename ~= "" and vim.fn.fnamemodify(filename, ":~:.") or "[No Name]"
end

--- Resolve the lines targeted by a :Lm invocation (always whole lines).
---@param opts table user-command opts
---@return table|nil { bufnr, lines, start_line, end_line, filetype, filename }
function M.get(opts)
  if opts.range == 0 then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  return {
    bufnr = bufnr,
    lines = vim.api.nvim_buf_get_lines(bufnr, opts.line1 - 1, opts.line2, false),
    start_line = opts.line1,
    end_line = opts.line2,
    filetype = vim.bo[bufnr].filetype,
    filename = display_name(bufnr),
  }
end

--- The file around the cursor, sent as read-only context when :Lm runs without a
--- range: the whole file if it fits in `max_lines`, else a window centered on the cursor.
---@param bufnr integer
---@param cursor_line integer
---@param max_lines integer
---@return table|nil like M.get, plus { total, cursor_line, tick }; nil for non-file or empty buffers
function M.context(bufnr, cursor_line, max_lines)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" or max_lines < 1 then
    return nil
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  if total == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" then
    return nil
  end

  cursor_line = math.min(cursor_line, total)
  local first, last = 1, total
  if total > max_lines then
    first = math.max(1, cursor_line - math.floor(max_lines / 2))
    last = math.min(total, first + max_lines - 1)
    first = math.max(1, last - max_lines + 1)
  end
  return {
    bufnr = bufnr,
    lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false),
    start_line = first,
    end_line = last,
    total = total,
    cursor_line = cursor_line,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    filetype = vim.bo[bufnr].filetype,
    filename = display_name(bufnr),
  }
end

return M
