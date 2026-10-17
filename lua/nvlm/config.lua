local M = {}

M.defaults = {
  provider = "ollama",
  providers = {
    ollama = {
      url = "http://localhost:11434",
      model = "qwen3.8:27b",
      timeout = 300, -- seconds
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
  -- Used when :Lm is called without a comment.
  default_prompt = "Review this code. Point out bugs or anything that looks wrong.",
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
