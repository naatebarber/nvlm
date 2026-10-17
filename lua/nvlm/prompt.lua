local M = {}

---@param sel table from nvlm.selection.get
---@param comment string
---@return string
function M.user_message(sel, comment)
  local numbered = {}
  for i, line in ipairs(sel.lines) do
    numbered[i] = ("%d: %s"):format(sel.start_line + i - 1, line)
  end

  return table.concat({
    ("File: %s (lines %d-%d)"):format(sel.filename, sel.start_line, sel.end_line),
    "",
    "```" .. sel.filetype,
    table.concat(numbered, "\n"),
    "```",
    "",
    comment,
  }, "\n")
end

return M
