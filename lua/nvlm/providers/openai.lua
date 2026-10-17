local http = require("nvlm.http")

-- Any OpenAI-compatible /chat/completions endpoint (OpenAI, OpenRouter, LM Studio, llama.cpp, ...).
local M = {}

-- Convert nvlm's history format to OpenAI chat messages.
local function to_messages(messages)
  return vim.tbl_map(function(msg)
    if msg.role == "tool" then
      return { role = "tool", tool_call_id = msg.tool_call_id, content = msg.content }
    elseif msg.tool_calls then
      return {
        role = "assistant",
        content = msg.content,
        tool_calls = vim.tbl_map(function(call)
          return {
            id = call.id,
            type = "function",
            ["function"] = { name = call.name, arguments = vim.json.encode(call.arguments) },
          }
        end, msg.tool_calls),
      }
    end
    return msg
  end, messages)
end

local function error_message(e)
  return type(e) == "table" and (e.message or vim.inspect(e)) or tostring(e)
end

--- Stream a chat completion.
---@param req table { messages, tools? }
---@param cfg table provider config
---@param handlers table { on_delta(text), on_tool_call(call), on_done(err) }, all run on the main loop
---@return vim.SystemObj|nil
function M.request(req, cfg, handlers)
  local headers, env = {}, {}
  if cfg.api_key_env then
    if not os.getenv(cfg.api_key_env) then
      vim.schedule(function()
        handlers.on_done("$" .. cfg.api_key_env .. " is not set")
      end)
      return nil
    end
    -- curl reads the key from the environment itself, keeping it out of argv.
    headers.Authorization = "Bearer {{" .. cfg.api_key_env .. "}}"
    env = { cfg.api_key_env }
  end
  for k, v in pairs(cfg.headers or {}) do
    headers[k] = v
  end

  local body = { model = cfg.model, messages = to_messages(req.messages), tools = req.tools, stream = true }
  local calls = {} -- tool calls by index, assembled from streamed fragments
  local raw = {} -- non-SSE output, i.e. an HTTP error body
  local err

  local function on_line(line)
    if line:sub(1, 1) == ":" then
      return -- SSE comment / keep-alive
    end
    local data = line:match("^data: ?(.*)")
    if not data then
      table.insert(raw, line)
      return
    end
    if data == "[DONE]" then
      return
    end

    local ok, chunk = pcall(vim.json.decode, data)
    if not ok then
      err = "invalid JSON: " .. data
      return
    end
    if chunk.error then
      err = error_message(chunk.error)
      return
    end

    local choice = type(chunk.choices) == "table" and chunk.choices[1]
    local delta = choice and choice.delta
    if type(delta) ~= "table" then
      return
    end
    if type(delta.content) == "string" and delta.content ~= "" then
      handlers.on_delta(delta.content)
    end
    for _, part in ipairs(type(delta.tool_calls) == "table" and delta.tool_calls or {}) do
      local idx = (type(part.index) == "number" and part.index or 0) + 1
      calls[idx] = calls[idx] or { arguments = "" }
      local call = calls[idx]
      if type(part.id) == "string" then
        call.id = part.id
      end
      local fn = part["function"]
      if type(fn) == "table" then
        if type(fn.name) == "string" and fn.name ~= "" then
          call.name = fn.name
        end
        if type(fn.arguments) == "string" then
          call.arguments = call.arguments .. fn.arguments
        end
      end
    end
  end

  local opts = { timeout = cfg.timeout, headers = headers, env = env }
  return http.stream(cfg.url .. "/chat/completions", body, opts, on_line, function(exit_err)
    if not err and #raw > 0 then
      local ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
      if ok and type(decoded) == "table" and decoded.error then
        err = error_message(decoded.error)
      end
    end
    err = err or exit_err
    if not err then
      for _, call in ipairs(calls) do
        local ok, args = pcall(vim.json.decode, call.arguments ~= "" and call.arguments or "{}")
        handlers.on_tool_call({ id = call.id, name = call.name, arguments = ok and args or nil })
      end
    end
    handlers.on_done(err)
  end)
end

return M
