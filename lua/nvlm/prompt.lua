local M = {}

-- The selection as a fenced block, each line prefixed with its line number.
local function code_block(sel)
  local numbered = {}
  for i, line in ipairs(sel.lines) do
    numbered[i] = ("%d: %s"):format(sel.start_line + i - 1, line)
  end
  return table.concat({ "```" .. sel.filetype, table.concat(numbered, "\n"), "```" }, "\n")
end

---@param sel table from nvlm.selection.get
---@param comment string
---@return string
function M.user_message(sel, comment)
  return table.concat({
    ("File: %s (lines %d-%d)"):format(sel.filename, sel.start_line, sel.end_line),
    "",
    code_block(sel),
    "",
    comment,
  }, "\n")
end

--- A follow-up carrying the selection's current contents, because it changed
--- or moved since the model last saw it (user edits, an undone edit, lines added above).
---@param snap table from nvlm.edit.snapshot
---@param comment string
---@return string
function M.selection_update(snap, comment)
  return table.concat({
    ("[Editor note: the selection has changed or moved since you last saw it (the user edited it, undid your edit, or added lines above it). It is now %s lines %d-%d:]"):format(
      snap.filename,
      snap.start_line,
      snap.end_line
    ),
    "",
    code_block(snap),
    "",
    comment,
  }, "\n")
end

M.selection_deleted = "[Editor note: the user deleted the selected code; it can no longer be edited.]"

return M
