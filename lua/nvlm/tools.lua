local config = require("nvlm.config")
local edit = require("nvlm.edit")
local prompt = require("nvlm.prompt")
local ui = require("nvlm.ui")

-- Tools the model can call: edit or drop the active selection, read the
-- project (confined to the working directory), and ask the user a question.
local M = {}

local MAX_READ_LINES = 500
local MAX_LIST = 200
local MAX_MATCHES = 100
local MAX_FILE_BYTES = 2 * 1024 * 1024
local TIMEOUT = 10000 -- ms, for list_files / search

local function def(name, description, properties, required)
  return {
    type = "function",
    ["function"] = {
      name = name,
      description = table.concat(description, " "),
      -- An empty Lua table would encode as a JSON array.
      parameters = { type = "object", properties = properties or vim.empty_dict(), required = required },
    },
  }
end

local defs = {
  replace_selection = def("replace_selection", {
    "Replace the user's selected lines in their editor with new code.",
    "Provide the complete replacement for the whole selection (not a diff or a fragment),",
    "keeping the original indentation, without line-number prefixes or markdown fences.",
    "Only call this when the user asks for a change.",
  }, {
    code = { type = "string", description = "The full replacement text for the selected lines." },
  }, { "code" }),

  detach_selection = def("detach_selection", {
    "Stop tracking the user's selection, giving up the ability to edit it.",
    "Only call this when the conversation has clearly moved on to unrelated code",
    "and the selection is no longer useful context.",
  }),

  read_file = def("read_file", {
    "Read a file in the user's project (the editor's working directory), including unsaved changes.",
    "Returns lines prefixed with their line numbers, at most " .. MAX_READ_LINES .. " at a time;",
    "use start_line/end_line to page through large files.",
  }, {
    path = { type = "string", description = "File path, relative to the project root." },
    start_line = { type = "integer", description = "First line to read (1-based). Defaults to 1." },
    end_line = { type = "integer", description = "Last line to read, inclusive." },
  }, { "path" }),

  list_files = def("list_files", {
    "List the project's files recursively, skipping gitignored ones.",
    "Use it to find a file by name or to get an overview of the project.",
  }, {
    path = { type = "string", description = "Directory to list, relative to the project root. Defaults to the root." },
    glob = { type = "string", description = "Only list files matching this glob, e.g. '**/*.lua'." },
  }),

  search = def("search", {
    "Search the project's files for a regular expression, e.g. to find where a function",
    "is defined or called. Returns matching lines as path:line:text.",
  }, {
    pattern = { type = "string", description = "Regular expression to search for." },
    path = { type = "string", description = "File or directory to search, relative to the project root." },
    glob = { type = "string", description = "Only search files matching this glob, e.g. '**/*.lua'." },
  }, { "pattern" }),

  ask_user = def("ask_user", {
    "Ask the user a question when their request is ambiguous or you need information",
    "you can't find with the other tools. This ends your turn; their answer arrives as the next message.",
  }, {
    question = { type = "string", description = "The question to ask." },
  }, { "question" }),
}

--- Tool definitions to offer the model right now.
function M.defs()
  local list = {}
  if edit.has_target() then
    vim.list_extend(list, { defs.replace_selection, defs.detach_selection })
  end
  if config.options.tools.read then
    vim.list_extend(list, { defs.read_file, defs.list_files, defs.search })
  end
  table.insert(list, defs.ask_user)
  return list
end

--- Resolve a model-supplied path to an absolute one inside the working directory.
---@return string|nil abs
---@return string rel_or_err path relative to the root ("." for the root itself), or the error
local function resolve(path)
  path = (type(path) == "string" and path ~= "") and path or "."
  local root = vim.uv.fs_realpath(vim.fn.getcwd())
  -- realpath also resolves `..` and symlinks, so neither can escape the root.
  local abs = vim.uv.fs_realpath(vim.fn.fnamemodify(path, ":p"))
  if not abs then
    return nil, "no such file or directory: " .. path
  end
  if abs == root then
    return abs, "."
  end
  if abs:sub(1, #root + 1) ~= root .. "/" then
    return nil, path .. " is outside the working directory"
  end
  return abs, abs:sub(#root + 2)
end

--- A file's lines, from its buffer if it's loaded (so unsaved changes show).
local function file_lines(abs)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name ~= "" and vim.uv.fs_realpath(name) == abs then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  local stat = vim.uv.fs_stat(abs)
  if stat.type == "directory" then
    return nil, "it's a directory; use list_files"
  end
  if stat.size > MAX_FILE_BYTES then
    return nil, "file is too large"
  end
  local f, err = io.open(abs, "rb")
  if not f then
    return nil, err
  end
  local data = f:read("*a")
  f:close()
  if data:find("\0", 1, true) then
    return nil, "binary file"
  end
  local lines = vim.split(data:gsub("\r\n", "\n"), "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Run a command in the working directory, waiting at most TIMEOUT.
local function exec(cmd)
  local ok, obj = pcall(vim.system, cmd, { text = true, cwd = vim.fn.getcwd() })
  if not ok then
    return nil, obj
  end
  local res = obj:wait(TIMEOUT)
  if res.signal ~= 0 then
    return nil, "timed out"
  end
  return res
end

--- Cap a list of output lines at `max`, noting how many were left out.
local function cap(lines, max)
  local total = #lines
  if total <= max then
    return lines
  end
  lines = vim.list_slice(lines, 1, max)
  table.insert(lines, ("… and %d more"):format(total - max))
  return lines
end

local function output_lines(stdout)
  return vim.split(vim.trim(stdout or ""), "\n", { plain = true, trimempty = true })
end

local function plural(n, word, words)
  return ("%d %s"):format(n, n == 1 and word or (words or word .. "s"))
end

-- Each handler takes the call's arguments and returns the result for the model,
-- or nil and an error. It logs its own success.
local handlers = {}

function handlers.replace_selection(args)
  if type(args.code) ~= "string" then
    return nil, "missing or malformed `code` argument"
  end
  local applied, err = edit.replace_selection(args.code)
  if not applied then
    return nil, err
  end
  local body = { "```" .. applied.filetype }
  vim.list_extend(body, applied.lines)
  table.insert(body, "```")
  ui.append_item("edit", ("Edited `%s` · `u` there to undo"):format(applied.where), body)
  return "Applied. The selection is now " .. applied.where .. " and contains exactly the code you provided."
end

function handlers.detach_selection()
  local status = edit.status()
  if not status then
    return nil, "there is no active selection"
  end
  edit.clear_target()
  ui.append_item("tool", ("Detached `%s`"):format(status.where))
  return "Detached. You can no longer edit it."
end

function handlers.read_file(args)
  local abs, rel = resolve(args.path)
  if not abs then
    return nil, rel
  end
  local lines, err = file_lines(abs)
  if not lines then
    return nil, err
  end
  if #lines == 0 then
    ui.append_item("tool", ("Read `%s`"):format(rel), { "⎿ empty file" })
    return rel .. " is empty."
  end

  local first = math.max(1, tonumber(args.start_line) or 1)
  if first > #lines then
    return nil, ("%s has only %d lines"):format(rel, #lines)
  end
  local last = math.min(#lines, tonumber(args.end_line) or #lines, first + MAX_READ_LINES - 1)
  if last < first then
    return nil, "end_line is before start_line"
  end

  ui.append_item("tool", ("Read `%s:%d-%d`"):format(rel, first, last), { "⎿ " .. plural(last - first + 1, "line") })
  local result = {
    ("%s (lines %d-%d of %d)"):format(rel, first, last, #lines),
    "",
    prompt.code_block({
      lines = vim.list_slice(lines, first, last),
      start_line = first,
      filetype = vim.filetype.match({ filename = abs }) or "",
    }),
  }
  if last < #lines then
    table.insert(result, ("[%d more lines; read from start_line %d to continue.]"):format(#lines - last, last + 1))
  end
  return table.concat(result, "\n")
end

function handlers.list_files(args)
  local abs, rel = resolve(args.path)
  if not abs then
    return nil, rel
  end
  local glob = type(args.glob) == "string" and args.glob ~= "" and args.glob or nil
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--files", "--color", "never" }
    if glob then
      vim.list_extend(cmd, { "--glob", glob })
    end
    if rel ~= "." then
      vim.list_extend(cmd, { "--", rel })
    end
  else
    local spec = glob and ":(glob)" .. (rel == "." and "" or rel .. "/") .. glob or rel
    cmd = { "git", "ls-files", "--cached", "--others", "--exclude-standard", "--", spec }
  end

  local res, err = exec(cmd)
  if not res then
    return nil, err
  end
  if res.code ~= 0 and not (cmd[1] == "rg" and res.code == 1) then
    return nil, vim.trim(res.stderr ~= "" and res.stderr or "listing failed")
  end
  local files = output_lines(res.stdout)
  table.sort(files)

  local label = glob and (rel == "." and glob or rel .. "/" .. glob) or rel
  ui.append_item("tool", ("List `%s`"):format(label), { "⎿ " .. plural(#files, "file") })
  if #files == 0 then
    return "No files found."
  end
  return table.concat(cap(files, MAX_LIST), "\n")
end

function handlers.search(args)
  if type(args.pattern) ~= "string" or args.pattern == "" then
    return nil, "missing `pattern` argument"
  end
  local abs, rel = resolve(args.path)
  if not abs then
    return nil, rel
  end
  local glob = type(args.glob) == "string" and args.glob ~= "" and args.glob or nil
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--line-number", "--no-heading", "--color", "never", "--max-columns", "300", "-e", args.pattern }
    if glob then
      vim.list_extend(cmd, { "--glob", glob })
    end
    if rel ~= "." then
      vim.list_extend(cmd, { "--", rel })
    end
  else
    local spec = glob and ":(glob)" .. (rel == "." and "" or rel .. "/") .. glob or rel
    cmd = { "git", "grep", "-n", "-I", "-E", "--untracked", "-e", args.pattern, "--", spec }
  end

  local res, err = exec(cmd)
  if not res then
    return nil, err
  end
  -- Both exit 1 for "no matches".
  if res.code ~= 0 and res.code ~= 1 then
    return nil, vim.trim(res.stderr ~= "" and res.stderr or "search failed")
  end
  local matches = vim.tbl_map(function(line)
    return #line > 300 and line:sub(1, 300) .. "…" or line
  end, output_lines(res.stdout))

  ui.append_item("tool", ("Search `%s`%s"):format(args.pattern, rel ~= "." and (" in `" .. rel .. "`") or ""), {
    "⎿ " .. plural(#matches, "match", "matches"),
  })
  if #matches == 0 then
    return "No matches."
  end
  return table.concat(cap(matches, MAX_MATCHES), "\n")
end

function handlers.ask_user(args)
  if type(args.question) ~= "string" or vim.trim(args.question) == "" then
    return nil, "missing `question` argument"
  end
  local lines = vim.split(vim.trim(args.question), "\n", { plain = true })
  ui.append_item("question", table.remove(lines, 1), lines)
  return "Asked. The user's answer will arrive as the next message."
end

-- Tools after which the model should wait for the user instead of continuing.
local ends_turn = { ask_user = true }

--- Execute a tool call from the model, log it, and return the result for the model.
---@return string result
---@return boolean ends_turn whether to wait for the user rather than send the result back now
function M.run(call)
  local handler = handlers[call.name]
  if not handler then
    ui.append_item("error", "unknown tool: " .. tostring(call.name))
    return "error: unknown tool " .. tostring(call.name), false
  end
  local args = call.arguments
  if args ~= nil and type(args) ~= "table" then
    args = nil
  end
  local ok, result, err = pcall(handler, args or {})
  if not ok then
    result, err = nil, result
  end
  if not result then
    ui.append_item("error", ("%s failed: %s"):format(call.name, err))
    return "error: " .. tostring(err), false
  end
  return result, ends_turn[call.name] or false
end

return M
