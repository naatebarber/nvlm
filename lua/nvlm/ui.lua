local M = {}

-- buf: the read-only chat log; input_buf: the editable prompt below it.
local state = { buf = nil, input_buf = nil }

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

-- Closing either pane closes the other.
vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("nvlm_ui", { clear = true }),
  callback = function(args)
    local win = tonumber(args.match)
    local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
    if buf and (buf == state.buf or buf == state.input_buf) then
      vim.schedule(close)
    end
  end,
})

local function is_empty(buf)
  return vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

local function set_lines(buf, start, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, -1, false, lines)
  vim.bo[buf].modifiable = false
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

local function submit()
  local buf = state.input_buf
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  if text ~= "" and require("nvlm").send(nil, text) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  end
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
  state.input_buf = buf
  return buf
end

local function style(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
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
    vim.wo[input_win].winbar = " nvlm  %#Comment#<CR> send · <C-j> newline"
  end
end

function M.focus_input()
  M.open()
  vim.api.nvim_set_current_win(find_win(state.input_buf))
  vim.cmd("startinsert!")
end

--- Append a new exchange header with a placeholder for the response.
---@return table entry handle for append_entry / finish_entry
function M.begin_entry(header_lines)
  local buf = get_buf()
  local lines = {}
  if not is_empty(buf) then
    vim.list_extend(lines, { "", "---", "" })
  end
  vim.list_extend(lines, header_lines)
  vim.list_extend(lines, { "" })

  local start = is_empty(buf) and 0 or vim.api.nvim_buf_line_count(buf)
  set_lines(buf, start, lines)
  local response_start = vim.api.nvim_buf_line_count(buf)
  set_lines(buf, response_start, { "_thinking…_" })
  scroll_to_end(buf)
  return { response_start = response_start, started = false }
end

--- Stream `text` onto the end of the response, replacing the placeholder on first output.
function M.append_entry(entry, text)
  if not entry.started then
    -- Models often open with blank lines; don't drop the placeholder for those.
    text = text:gsub("^%s+", "")
    if text == "" then
      return
    end
    entry.started = true
    set_lines(get_buf(), entry.response_start, { "" })
  end

  local buf = get_buf()
  follow(buf, function()
    local row = vim.api.nvim_buf_line_count(buf) - 1
    local col = #vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_text(buf, row, col, row, col, vim.split(text, "\n", { plain = true }))
    vim.bo[buf].modifiable = false
  end)
end

--- Close out a response, noting `err` if the request failed or was cancelled.
function M.finish_entry(entry, err)
  local buf = get_buf()
  follow(buf, function()
    if entry.started then
      if err then
        set_lines(buf, vim.api.nvim_buf_line_count(buf), { "", "**error:** " .. err })
      end
    else
      -- No text arrived (an error, or a reply that was only a tool call).
      set_lines(buf, entry.response_start, err and { "**error:** " .. err } or {})
    end
  end)
end

--- Append a block of lines to the log, separated from what's above by a blank line.
function M.append_block(lines)
  local buf = get_buf()
  follow(buf, function()
    local count = vim.api.nvim_buf_line_count(buf)
    local last = vim.api.nvim_buf_get_lines(buf, count - 1, count, false)[1]
    set_lines(buf, count, last == "" and lines or vim.list_extend({ "" }, lines))
  end)
end

function M.clear()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    set_lines(state.buf, 0, {})
  end
end

return M
