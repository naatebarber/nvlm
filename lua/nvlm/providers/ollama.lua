local http = require("nvlm.http")

local M = {}

-- Convert nvlm's history format to Ollama chat messages.
local function to_messages(messages)
  return vim.tbl_map(function(msg)
    if msg.role == "tool" then
      return { role = "tool", tool_name = msg.name, content = msg.content }
    elseif msg.tool_calls then
      return {
        role = "assistant",
        content = msg.content,
        tool_calls = vim.tbl_map(function(call)
          return { ["function"] = { name = call.name, arguments = call.arguments } }
        end, msg.tool_calls),
      }
    end
    return msg
  end, messages)
end

--- Stream a chat completion.
---@param req table { messages, tools? }
---@param cfg table provider config
---@param handlers table { on_delta(text), on_tool_call(call), on_done(err) }, all run on the main loop
---@return vim.SystemObj
function M.request(req, cfg, handlers)
  local body = { model = cfg.model, messages = to_messages(req.messages), tools = req.tools, stream = true }
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
        local fn = call["function"]
        local args = fn.arguments
        if type(args) == "string" then
          local decoded_ok, decoded = pcall(vim.json.decode, args)
          args = decoded_ok and decoded or nil
        end
        handlers.on_tool_call({ id = call.id, name = fn.name, arguments = args })
      end
    end
  end

  return http.stream(cfg.url .. "/api/chat", body, { timeout = cfg.timeout }, on_line, function(exit_err)
    -- Prefer ollama's own error message over curl's generic exit status.
    handlers.on_done(err or exit_err)
  end)
end

return M
