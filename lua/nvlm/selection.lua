local M = {}

--- Resolve the text targeted by a :Lm invocation.
--- Uses the exact visual region (charwise / linewise / blockwise) when the range
--- came from a visual selection, otherwise the plain line range.
---@param opts table user-command opts
---@return table|nil { lines, start_line, end_line, filetype, filename }
function M.get(opts)
  if opts.range == 0 then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local vstart, vend = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local lines

  if vstart[2] == opts.line1 and vend[2] == opts.line2 then
    lines = vim.fn.getregion(vstart, vend, { type = vim.fn.visualmode() })
  else
    lines = vim.api.nvim_buf_get_lines(bufnr, opts.line1 - 1, opts.line2, false)
  end

  local filename = vim.api.nvim_buf_get_name(bufnr)
  return {
    lines = lines,
    start_line = opts.line1,
    end_line = opts.line2,
    filetype = vim.bo[bufnr].filetype,
    filename = filename ~= "" and vim.fn.fnamemodify(filename, ":~:.") or "[No Name]",
  }
end

return M
