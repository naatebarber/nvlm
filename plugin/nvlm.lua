if vim.g.loaded_nvlm then
  return
end
vim.g.loaded_nvlm = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("nvlm requires Neovim 0.10+", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Lm", function(opts)
  require("nvlm").run(opts)
end, { range = true, nargs = "*", desc = "Ask the LM about the selected text" })

vim.api.nvim_create_user_command("LmStop", function()
  require("nvlm").stop()
end, { desc = "Cancel the running LM request" })

vim.api.nvim_create_user_command("LmDetach", function()
  local _, err = require("nvlm").detach()
  if err then
    vim.notify("nvlm: " .. err, vim.log.levels.WARN)
  end
end, { desc = "Stop tracking the active LM selection" })

vim.api.nvim_create_user_command("LmReset", function()
  require("nvlm").reset()
end, { desc = "Clear the LM chat history and log" })

-- User commands must be capitalized; let `:lm` (with or without a range) expand to `:Lm`.
if not vim.g.nvlm_no_abbrev then
  vim.cmd([[cnoreabbrev <expr> lm getcmdtype() == ':' && getcmdline() =~# '^\(''<,''>\|[0-9,.$]*\)lm$' ? 'Lm' : 'lm']])
end
