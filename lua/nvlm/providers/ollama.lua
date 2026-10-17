local http = require("nvlm.http")

local M = {}

--- Stream a chat completion. `on_delta(text)` gets each content chunk;
--- `on_done(err)` runs once at the end. Both run on the main loop.
---@return vim.SystemObj
function M.request(messages, cfg, on_delta, on_done)
  local body = { model = cfg.model, messages = messages, stream = true }
  local err

  local function on_line(line)
    local ok, chunk = pcall(vim.json.decode, line)
    if not ok then
      err = "invalid JSON from ollama: " .. line
    elseif chunk.error then
      err = chunk.error
    elseif chunk.message and chunk.message.content ~= "" then
      on_delta(chunk.message.content)
    end
  end

  return http.stream(cfg.url .. "/api/chat", body, { timeout = cfg.timeout }, on_line, function(exit_err)
    -- Prefer ollama's own error message over curl's generic exit status.
    on_done(err or exit_err)
  end)
end

return M
