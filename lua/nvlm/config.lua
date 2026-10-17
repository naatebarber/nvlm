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
    "Messages may include a code selection (prefixed with its line numbers) and a question about it;",
    "messages without code are follow-ups to the conversation so far.",
    "Answer directly. Reference line numbers when pointing at specific code.",
    "Use markdown; put code in fenced blocks without line-number prefixes.",
    "When the user asks you to change the selected code, call replace_selection with the complete",
    "new code for the selection instead of only describing the change; otherwise just answer.",
  }, " "),
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
