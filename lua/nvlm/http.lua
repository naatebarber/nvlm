local M = {}

--- POST a JSON body with curl and stream the response line by line.
--- `on_line(line)` and `on_exit(err)` run on the main loop, in order.
---@return vim.SystemObj
function M.stream(url, body, opts, on_line, on_exit)
  opts = opts or {}
  local cmd = {
    "curl", "-sS", "-N", "--fail-with-body",
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

  -- stdout arrives in arbitrary chunks; only hand complete lines to on_line.
  local pending = ""
  local function on_stdout(_, chunk)
    if not chunk then
      return
    end
    pending = pending .. chunk
    local lines = vim.split(pending, "\n", { plain = true })
    pending = table.remove(lines)
    vim.schedule(function()
      for _, line in ipairs(lines) do
        if line ~= "" then
          on_line(line)
        end
      end
    end)
  end

  return vim.system(cmd, { stdin = vim.json.encode(body), stdout = on_stdout, text = true }, function(res)
    vim.schedule(function()
      if pending ~= "" then
        on_line(pending)
      end
      if res.signal ~= 0 then
        return on_exit("cancelled")
      end
      if res.code ~= 0 then
        return on_exit(("curl exited %d: %s"):format(res.code, vim.trim(res.stderr or "")))
      end
      on_exit()
    end)
  end)
end

return M
