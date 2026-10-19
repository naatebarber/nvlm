local M = {}

-- buf: the read-only chat log; input_buf: the editable prompt below it;
-- status: the active selection's status, shown in the input pane's winbar.
local state = { buf = nil, input_buf = nil, status = nil }

local ns = vim.api.nvim_create_namespace("nvlm_log")

-- Log layout (Claude Code style): every line is indented two spaces, and an item's
-- first line gets a marker overlaid on that indent, so wrapped text lines up under it.
local markers = {
  prompt = { ">", "NvlmPrompt" },
  pending = { "⏺", "NvlmPending" },
  text = { "⏺", "NvlmBullet" },
  edit = { "⏺", "NvlmEdit" },
  tool = { "⏺", "NvlmTool" },
  question = { "?", "NvlmQuestion" },
  error = { "⏺", "NvlmError" },
}

local function define_highlights()
  for group, link in pairs({
    NvlmPrompt = "Comment",
    NvlmPending = "Comment",
    NvlmBullet = "Normal",
    NvlmEdit = "DiagnosticOk",
    NvlmTool = "Special",
    NvlmQuestion = "DiagnosticInfo",
    NvlmError = "DiagnosticError",
    NvlmSelection = "DiagnosticInfo",
    NvlmModified = "DiagnosticWarn",
  }) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end
define_highlights()

local function find_win(buf)
  if not buf then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

local function close()
  for _, buf in ipairs({ state.buf, state.input_buf }) do
    local win = find_win(buf)
    if win then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
end

local group = vim.api.nvim_create_augroup("nvlm_ui", { clear = true })

-- Closing either pane closes the other.
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local win = tonumber(args.match)
    local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
    if buf and (buf == state.buf or buf == state.input_buf) then
      vim.schedule(close)
    end
  end,
})

-- Colorschemes clear highlight groups; restore our default links.
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })

local function is_empty(buf)
  return vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

local function modify(buf, fn)
  vim.bo[buf].modifiable = true
  fn()
  vim.bo[buf].modifiable = false
end

local function indent(lines)
  return vim.tbl_map(function(line)
    return line == "" and "" or "  " .. line
  end, lines)
end

--- Append lines to the end of the log; returns the row of the first one.
local function append_lines(buf, lines)
  local start = is_empty(buf) and 0 or vim.api.nvim_buf_line_count(buf)
  modify(buf, function()
    vim.api.nvim_buf_set_lines(buf, start, -1, false, lines)
  end)
  return start
end

local function mark(buf, row, kind, id)
  return vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    id = id,
    virt_text = { markers[kind] },
    virt_text_pos = "overlay",
  })
end

local function highlight_line(buf, row, hl_group)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  return vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #line, hl_group = hl_group })
end

local function scroll_to_end(buf)
  local win = find_win(buf)
  if win then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

--- Run `fn` (which grows the buffer), keeping the view pinned to the bottom only
--- if it already was, so scrolling up to read isn't interrupted by new output.
local function follow(buf, fn)
  local win = find_win(buf)
  local at_end = win and vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf)
  fn()
  if at_end then
    scroll_to_end(buf)
  end
end

local placeholder_ns = vim.api.nvim_create_namespace("nvlm_placeholder")

local function update_placeholder(buf)
  vim.api.nvim_buf_clear_namespace(buf, placeholder_ns, 0, -1)
  if is_empty(buf) then
    vim.api.nvim_buf_set_extmark(buf, placeholder_ns, 0, 0, {
      virt_text = { { "Ask nvlm…", "Comment" } },
      virt_text_pos = "overlay",
    })
  end
end

local function submit()
  local buf = state.input_buf
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  if text == "" then
    return
  end
  local accepted
  if text:sub(1, 1) == "/" then
    accepted = require("nvlm.commands").run(text)
  else
    accepted = require("nvlm").send(nil, text)
  end
  if not accepted then
    return
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  update_placeholder(buf)
end

local function get_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  -- Scratch buffer: nofile, bufhidden=hide, so the log survives closing the window.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "nvlm://chat")
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "Close nvlm" })
  for _, lhs in ipairs({ "i", "a", "o", "<CR>" }) do
    vim.keymap.set("n", lhs, M.focus_input, { buffer = buf, nowait = true, desc = "Ask nvlm a follow-up" })
  end
  vim.keymap.set("n", "gs", function()
    require("nvlm.edit").jump()
  end, { buffer = buf, desc = "Go to the active selection" })
  state.buf = buf
  return buf
end

local function get_input_buf()
  if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
    return state.input_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "nvlm://input")
  vim.bo[buf].filetype = "markdown"
  vim.keymap.set({ "n", "i" }, "<CR>", submit, { buffer = buf, desc = "Send to nvlm" })
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "Close nvlm" })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      update_placeholder(buf)
    end,
  })
  update_placeholder(buf)
  state.input_buf = buf
  return buf
end

local function winbar()
  local bar = " nvlm"
  local status = state.status
  if status then
    local where = status.where:gsub("%%", "%%%%")
    if status.state == "deleted" then
      bar = bar .. " · %#NvlmError#selection deleted%*"
    elseif status.state == "modified" then
      bar = bar .. " · " .. where .. " %#NvlmModified#modified%*"
    else
      bar = bar .. " · " .. where
    end
  end
  return bar
end

---@param status table|nil from nvlm.edit.status
function M.set_status(status)
  state.status = status
  local win = find_win(state.input_buf)
  if win then
    vim.wo[win].winbar = winbar()
  end
end

local function style(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
end

--- Show the chat log in a full-height split on the far right with the input
--- pane below it (each reused if already open).
function M.open()
  local cfg = require("nvlm.config").options.ui
  local win = find_win(get_buf())
  if not win then
    win = vim.api.nvim_open_win(state.buf, false, {
      split = "right",
      win = -1,
      width = math.floor(vim.o.columns * cfg.width),
    })
    style(win)
    vim.wo[win].winfixwidth = true
  end
  if not find_win(get_input_buf()) then
    local input_win = vim.api.nvim_open_win(state.input_buf, false, {
      split = "below",
      win = win,
      height = cfg.input_height,
    })
    style(input_win)
    vim.wo[input_win].winfixheight = true
    vim.wo[input_win].winbar = winbar()
  end
end

function M.focus_input()
  M.open()
  vim.api.nvim_set_current_win(find_win(state.input_buf))
  vim.cmd("startinsert!")
end

--- Append the user's prompt (and the selection it refers to) with a placeholder
--- for the response. Without a prompt, only the placeholder: the model is
--- continuing after its tool calls.
---@param prompt_lines string[]|nil
---@param refs string[]|nil what it refers to, e.g. { "file.py:3-7" }
---@return table entry handle for append_entry / finish_entry
function M.begin_entry(prompt_lines, refs)
  local buf = get_buf()
  local lines = is_empty(buf) and {} or { "" }
  local first = #lines
  local header = prompt_lines and indent(prompt_lines) or {}
  for _, ref in ipairs(refs or {}) do
    table.insert(header, "  ⎿ " .. ref)
  end
  vim.list_extend(lines, header)
  if #header > 0 then
    table.insert(lines, "")
  end
  table.insert(lines, "  thinking…")

  local entry
  local function add()
    local start = append_lines(buf, lines)
    for row = start + first, start + first + #header - 1 do
      highlight_line(buf, row, "NvlmPrompt")
    end
    if #header > 0 then
      mark(buf, start + first, "prompt")
    end
    local row = start + #lines - 1
    entry = {
      row = row,
      started = false,
      mark = mark(buf, row, "pending"),
      placeholder_hl = highlight_line(buf, row, "NvlmPending"),
    }
  end
  if prompt_lines then
    add()
    scroll_to_end(buf)
  else
    follow(buf, add)
  end
  return entry
end

local function remove_placeholder(buf, entry)
  vim.api.nvim_buf_del_extmark(buf, ns, entry.placeholder_hl)
  vim.api.nvim_buf_del_extmark(buf, ns, entry.mark)
  modify(buf, function()
    vim.api.nvim_buf_set_lines(buf, entry.row, entry.row + 1, false, {})
  end)
end

--- Stream `text` onto the end of the response, replacing the placeholder on first output.
function M.append_entry(entry, text)
  local buf = get_buf()
  if not entry.started then
    -- Models often open with blank lines; don't drop the placeholder for those.
    text = text:gsub("^%s+", "")
    if text == "" then
      return
    end
    entry.started = true
    vim.api.nvim_buf_del_extmark(buf, ns, entry.placeholder_hl)
    modify(buf, function()
      vim.api.nvim_buf_set_lines(buf, entry.row, entry.row + 1, false, { "  " })
    end)
    mark(buf, entry.row, "text", entry.mark)
  end

  local parts = vim.split(text, "\n", { plain = true })
  for i = 2, #parts do
    parts[i] = "  " .. parts[i]
  end
  follow(buf, function()
    local row = vim.api.nvim_buf_line_count(buf) - 1
    local col = #vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    modify(buf, function()
      vim.api.nvim_buf_set_text(buf, row, col, row, col, parts)
    end)
  end)
end

--- Append a bulleted item to the log, e.g. an edit notice, a tool call, or an error.
---@param kind "text"|"edit"|"tool"|"question"|"error"
---@param text string the bulleted first line
---@param body string[]|nil lines shown indented under it
function M.append_item(kind, text, body)
  local buf = get_buf()
  follow(buf, function()
    local count = vim.api.nvim_buf_line_count(buf)
    local last = vim.api.nvim_buf_get_lines(buf, count - 1, count, false)[1]
    local lines = last == "" and {} or { "" }
    local first = #lines
    table.insert(lines, "  " .. text)
    vim.list_extend(lines, indent(body or {}))

    local row = append_lines(buf, lines) + first
    mark(buf, row, kind)
    if kind == "error" then
      highlight_line(buf, row, "NvlmError")
    end
  end)
end

--- Echo a slash command and its output, Claude Code style.
---@param line string the command as typed
---@param output string[]
---@param is_error boolean|nil
function M.append_command(line, output, is_error)
  local buf = get_buf()
  follow(buf, function()
    local lines = is_empty(buf) and {} or { "" }
    local first = #lines
    table.insert(lines, "  " .. line)
    for i, text in ipairs(output) do
      table.insert(lines, (i == 1 and "  ⎿ " or "    ") .. text)
    end

    local row = append_lines(buf, lines) + first
    highlight_line(buf, row, "NvlmPrompt")
    mark(buf, row, "prompt")
    for r = row + 1, row + #output do
      highlight_line(buf, r, is_error and "NvlmError" or "NvlmPrompt")
    end
  end)
end

--- Close out a response, noting `err` if the request failed or was cancelled.
function M.finish_entry(entry, err)
  local buf = get_buf()
  if not entry.started then
    -- No text arrived (an error, or a reply that was only a tool call).
    remove_placeholder(buf, entry)
  end
  if err then
    M.append_item("error", "error: " .. err)
  end
end

function M.clear()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
    modify(state.buf, function()
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
    end)
  end
end

return M
