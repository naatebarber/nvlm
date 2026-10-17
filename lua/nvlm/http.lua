local M = {}

--- POST a JSON body with curl. `cb(decoded, err)` runs on the main loop.
---@return vim.SystemObj
function M.post_json(url, body, opts, cb)
  opts = opts or {}
  local cmd = {
    "curl", "-sS", "--fail-with-body",
    "-X", "POST", url,
    "-H", "Content-Type: application/json",
    "--data-binary", "@-",
  }
  if opts.timeout then
    vim.list_extend(cmd, { "-m", tostring(opts.timeout) })
  end
  for k, v in pairs(opts.headers or {}) do
    vim.list_extend(cmd, { "-H", k .. ": " .. v })
  end

  return vim.system(cmd, { stdin = vim.json.encode(body), text = true }, function(res)
    vim.schedule(function()
      if res.signal ~= 0 then
        return cb(nil, "cancelled")
      end
      if res.code ~= 0 then
        local msg = vim.trim(res.stdout ~= "" and res.stdout or res.stderr)
        return cb(nil, ("curl exited %d: %s"):format(res.code, msg))
      end
      local ok, decoded = pcall(vim.json.decode, res.stdout)
      if not ok then
        return cb(nil, "invalid JSON response: " .. res.stdout)
      end
      cb(decoded)
    end)
  end)
end

return M
