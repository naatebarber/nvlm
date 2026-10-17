local M = {}

--- Resolve the lines targeted by a :Lm invocation (always whole lines).
---@param opts table user-command opts
---@return table|nil { bufnr, lines, start_line, end_line, filetype, filename }
function M.get(opts)
  if opts.range == 0 then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  return {
    bufnr = bufnr,
    lines = vim.api.nvim_buf_get_lines(bufnr, opts.line1 - 1, opts.line2, false),
    start_line = opts.line1,
    end_line = opts.line2,
    filetype = vim.bo[bufnr].filetype,
    filename = filename ~= "" and vim.fn.fnamemodify(filename, ":~:.") or "[No Name]",
  }
end

return M
