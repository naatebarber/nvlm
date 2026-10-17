# nvlm

A lightweight LM assist for Neovim. Select some lines, ask a question, and get an answer in a chat pane on the right. When you ask for a change, the model rewrites the selection in place.

It assists your editing; it doesn't try to replace it. For workspace-wide changes, use a full agent like Claude Code.

```
┌──────────── code ────────────┬──── nvlm://chat ─────────────┐
│ def average(xs):             │ > is there a bug?            │
│     total = 0                │   ⎿ stats.py:3-7             │
│     for i in range(len(xs)): │                              │
│         total += xs[i]       │ ⏺ Yes — line 5 skips xs[0].  │
│     return total / len(xs)   │                              │
│                              │ > fix it                     │
│                              │                              │
│                              │ ⏺ Edited stats.py:3-7        │
│                              ├──────────────────────────────┤
│                              │ nvlm  <CR> send · <C-j> nl   │
│                              │ _                            │
└──────────────────────────────┴──────────────────────────────┘
```

## Requirements

- Neovim 0.10+
- `curl` (8.3+ for providers that use an API key)
- A model that supports tool calling (needed for edits), from either:
  - [Ollama](https://ollama.com) running locally (the default), or
  - any OpenAI-compatible API: OpenAI, OpenRouter, LM Studio, llama.cpp, …

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  dir = "~/Documents/projects/nvlm",
  opts = {
    providers = { ollama = { model = "qwen3.8:27b" } },
  },
}
```

`setup()` is optional. Without it, the defaults below apply.

## Usage

1. Select lines with `V` and run `:lm tell me if i messed up here`. Typing `:lm` expands to `:Lm`.
2. The answer streams into the chat pane on the right.
3. Ask follow-ups in the input pane at the bottom of the chat column. To get there from the log, press `i`.
4. Ask for a change ("fix it", "make this handle empty lists") and the model rewrites the selected lines. The changed lines flash briefly. Press `u` in that buffer to undo the edit.

The conversation is kept until Neovim exits or you run `:LmReset`.

### Commands

| Command | Description |
|---|---|
| `:'<,'>Lm [question]` | Ask about the selected lines; they become the *active selection*. With no question, asks for a general review. |
| `:Lm question` | Ask a follow-up without attaching code. |
| `:LmStop` | Cancel the running request. Partial output is kept. |
| `:LmReset` | Clear the conversation, the log, and the active selection. |

### Keymaps

| Where | Key | Action |
|---|---|---|
| Chat log | `i` `a` `o` `<CR>` | Focus the input pane |
| Chat log | `gs` | Go to the active selection |
| Input pane | `<CR>` (normal & insert) | Send |
| Input pane | `<C-j>` (insert) | New line |
| Either | `q` | Close the chat pane and the input pane |

Set `vim.g.nvlm_no_abbrev = true` before the plugin loads to disable the `:lm` → `:Lm` abbreviation.

## How edits work

When you run `:Lm` on a selection, those lines become the active selection. An extmark (a position marker that Neovim moves as you edit) tracks them, so the right lines get edited even if you change other parts of the file while chatting.

While a selection is active, the model has a `replace_selection` tool. Calling it replaces the whole selection with new code as a single undo step, and the log records the edit along with the new code. After an edit, the selection covers the new code, so you can keep asking for changes.

### Keeping the model in sync

The plugin follows the active selection live as you work:

- A `▎` in the sign column marks the selected lines in your code.
- The input pane's top bar shows where the selection is now (`file.py:7-11`). It adds `modified` if the contents differ from what the model last saw, or says `selection deleted` if the lines are gone.

Nothing is sent to the model until your next message. Then, if the selection changed or moved since the model last saw it (you edited it, undid its edit, or added lines above it), the current code goes along with your message. The log marks this as `⎿ file.py:7-11 (updated)`. If the selection was deleted, the model is told, and it can no longer edit. If a request fails or is cancelled, the pending update is kept for the next message.

The model decides when to edit. Asking a question gets an answer, and asking for a change gets an edit. Saying "don't change anything" works as you'd expect.

## Configuration

Defaults:

```lua
require("nvlm").setup({
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
  system_prompt = "...", -- see lua/nvlm/config.lua
  default_prompt = "Review this code. Point out bugs or anything that looks wrong.",
  ui = {
    width = 0.3,      -- fraction of the editor width
    input_height = 5, -- lines
  },
})
```

### Providers

`provider` picks an entry from `providers`. Each entry's `kind` picks the implementation: `"ollama"` or `"openai"` (any OpenAI-compatible `/chat/completions` API). If `kind` is left out, the entry's name is used.

Use OpenRouter, with your key in an environment variable of your choice:

```lua
require("nvlm").setup({
  provider = "openrouter",
  providers = { openrouter = { api_key_env = "OPENROUTER_KEY" } },
})
```

Add your own OpenAI-compatible server:

```lua
require("nvlm").setup({
  provider = "lmstudio",
  providers = {
    lmstudio = { kind = "openai", url = "http://localhost:1234/v1", model = "qwen3.8-27b" },
  },
})
```

`api_key_env` names the environment variable that holds the key. Leave it out for servers that need no key. curl reads the key directly from the environment, so it never appears in the process list. Extra request headers can go in `headers = { ... }`.

### Highlights

These groups are linked by default and can be overridden:

| Group | Default link | Used for |
|---|---|---|
| `NvlmPrompt` | `Comment` | Your prompts |
| `NvlmPending` | `Comment` | The "thinking…" placeholder |
| `NvlmBullet` | `Normal` | Response bullets |
| `NvlmEdit` | `DiagnosticOk` | Edit bullets |
| `NvlmError` | `DiagnosticError` | Errors |
| `NvlmSelection` | `DiagnosticInfo` | Sign-column bar on the active selection |
| `NvlmModified` | `DiagnosticWarn` | `modified` in the input pane's top bar |

## Limitations

- Selections are always whole lines.
- One request at a time.
