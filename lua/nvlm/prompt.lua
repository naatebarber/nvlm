local M = {}

-- The selection as a fenced block, each line prefixed with its line number.
function M.code_block(sel)
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
    M.code_block(sel),
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
    M.code_block(snap),
    "",
    comment,
  }, "\n")
end

--- Read-only context: the file the user ran :Lm from, around their cursor.
---@param ctx table from nvlm.selection.context
---@return string
function M.file_context(ctx)
  local span = (ctx.start_line == 1 and ctx.end_line == ctx.total) and "the whole file"
    or ("lines %d-%d of %d"):format(ctx.start_line, ctx.end_line, ctx.total)
  return table.concat({
    ("[Editor note: the user is in %s with the cursor on line %d. Here is %s for context (read-only; it is not the selection):]"):format(
      ctx.filename,
      ctx.cursor_line,
      span
    ),
    "",
    M.code_block(ctx),
  }, "\n")
end

--- The file context is unchanged since the model last saw it; only say where the cursor is.
---@param ctx table from nvlm.selection.context
---@return string
function M.cursor_note(ctx)
  return ("[Editor note: the user is in %s with the cursor on line %d.]"):format(ctx.filename, ctx.cursor_line)
end

M.selection_deleted = "[Editor note: the user deleted the selected code; it can no longer be edited.]"
M.selection_detached = "[Editor note: the user detached the selected code from this chat; it can no longer be edited.]"

return M
