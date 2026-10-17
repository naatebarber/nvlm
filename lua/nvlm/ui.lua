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
---@return integer line index where the response starts
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
  return response_start
end

--- Replace the placeholder (everything from `response_start` on) with the response.
function M.finish_entry(response_start, lines)
  local buf = get_buf()
  set_lines(buf, response_start, lines)
  scroll_to_end(buf)
end

function M.clear()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    set_lines(state.buf, 0, {})
  end
end

return M
