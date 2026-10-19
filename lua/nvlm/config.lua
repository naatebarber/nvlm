local M = {}

M.defaults = {
  provider = "ollama",
  providers = {
    ollama = {
      url = "http://localhost:11434",
      model = "qwen3.8:27b",
      timeout = 300, -- seconds
    },
    openai = {
      kind = "openai",
      url = "https://api.openai.com/v1",
      model = "gpt-6-luna",
      api_key_env = "OPENAI_API_KEY",
      timeout = 300,
    },
    openrouter = {
      kind = "openai",
      url = "https://openrouter.ai/api/v1",
      model = "anthropic/claude-haiku-5.5",
      api_key_env = "OPENROUTER_API_KEY",
      timeout = 300,
    },
  },
  system_prompt = table.concat({
    "You are a concise, expert code reviewer embedded in the user's editor.",
    "Messages may include a code selection (prefixed with its line numbers) and a question about it,",
    "and may include the file the user is in, around their cursor, as read-only context;",
    "messages without code are follow-ups to the conversation so far.",
    "Answer directly. Reference line numbers when pointing at specific code.",
    "Use markdown; put code in fenced blocks without line-number prefixes.",
    "When the user asks you to change the selected code, call replace_selection with the complete",
    "new code for the selection instead of only describing the change; otherwise just answer.",
    "When the selection alone isn't enough context (say, to see where a function is called or defined),",
    "use search, read_file and list_files to look at the rest of the project before answering.",
    "If the request is ambiguous, call ask_user rather than guessing.",
    "If the conversation has clearly moved on from the selected code, call detach_selection.",
  }, " "),
  -- Running :Lm without a range sends the current file as read-only context: the
  -- whole file up to max_lines, else that many lines around the cursor.
  context = {
    enabled = true,
    max_lines = 300,
  },
  tools = {
    read = true, -- read_file, list_files and search, confined to the working directory
    max_rounds = 10, -- model responses per message before it has to stop and wait
  },
  ui = {
    width = 0.3, -- fraction of the editor width
    input_height = 5, -- lines
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
