local M = {}

local state = { buf = nil }

local function get_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  -- Scratch buffer: nofile, bufhidden=hide, so the log survives closing the window.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "nvlm://chat")
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, desc = "Close nvlm window" })
  for _, lhs in ipairs({ "i", "a", "o", "<CR>" }) do
    vim.keymap.set("n", lhs, function()
      require("nvlm").ask()
    end, { buffer = buf, nowait = true, desc = "Ask nvlm a follow-up" })
  end
  state.buf = buf
  return buf
end

local function find_win(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

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

--- Show the chat log in a full-height split on the far right (reused if already open).
function M.open(cfg)
  local buf = get_buf()
  if find_win(buf) then
    return
  end
  local win = vim.api.nvim_open_win(buf, false, {
    split = "right",
    win = -1,
    width = math.floor(vim.o.columns * cfg.width),
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixwidth = true
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
  if not err then
    return
  end
  local buf = get_buf()
  follow(buf, function()
    local msg = "**error:** " .. err
    if entry.started then
      set_lines(buf, vim.api.nvim_buf_line_count(buf), { "", msg })
    else
      set_lines(buf, entry.response_start, { msg })
    end
  end)
end

function M.clear()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    set_lines(state.buf, 0, {})
  end
end

return M
