local http = require("nvlm.http")

local M = {}

--- Stream a chat completion.
---@param req table { messages, tools? }
---@param cfg table provider config
---@param handlers table { on_delta(text), on_tool_call(call), on_done(err) }, all run on the main loop
---@return vim.SystemObj
function M.request(req, cfg, handlers)
  local body = { model = cfg.model, messages = req.messages, tools = req.tools, stream = true }
  local err

  local function on_line(line)
    local ok, chunk = pcall(vim.json.decode, line)
    if not ok then
      err = "invalid JSON from ollama: " .. line
    elseif chunk.error then
      err = chunk.error
    elseif chunk.message then
      local content = chunk.message.content
      if type(content) == "string" and content ~= "" then
        handlers.on_delta(content)
      end
      for _, call in ipairs(chunk.message.tool_calls or {}) do
        handlers.on_tool_call(call)
      end
    end
  end

  return http.stream(cfg.url .. "/api/chat", body, { timeout = cfg.timeout }, on_line, function(exit_err)
    -- Prefer ollama's own error message over curl's generic exit status.
    handlers.on_done(err or exit_err)
  end)
end

return M
