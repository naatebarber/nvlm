local http = require("nvlm.http")

local M = {}

--- `cb(text, err)` runs on the main loop.
---@return vim.SystemObj
function M.request(messages, cfg, cb)
  local body = { model = cfg.model, messages = messages, stream = false }
  return http.post_json(cfg.url .. "/api/chat", body, { timeout = cfg.timeout }, function(res, err)
    if err then
      return cb(nil, err)
    end
    if res.error then
      return cb(nil, res.error)
    end
    cb(res.message.content)
  end)
end

return M
