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
│                              │ nvlm · stats.py:3-7          │
│                              │ Ask nvlm…                    │
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
| `:'<,'>Lm [question]` | Ask about the selected lines; they become the *active selection*. With no question, attaches them and opens the chat, and they're sent with your next message. |
| `:Lm` | Open the chat, ready to type. The current file goes along with your next message as context (see [File context](#file-context)). |
| `:Lm question` | Ask about the file you're in, with the cursor's surroundings as context. |
| `:LmStop` | Cancel the running request. Partial output is kept. |
| `:LmDetach` | Stop tracking the active selection, so the model can no longer edit it. |
| `:LmReset` | Clear the conversation, the log, and the active selection. |

### Chat commands

Type these into the input pane:

| Command | Description |
|---|---|
| `/stop` | Cancel the running request |
| `/detach` | Stop tracking the active selection |
| `/reset` (alias `/clear`) | Clear the conversation and the log |
| `/model [name]` | Show the model, or switch to another for this session |
| `/provider [name]` | List the configured providers, or switch to one |
| `/help` | List the commands |

While a response is streaming, only `/stop` runs. Other commands stay in the input until the response finishes.

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

`:LmDetach` drops the active selection when you're done with it. The sign-column bar and the status go away, and the model is told on your next message.

The model decides when to edit. Asking a question gets an answer, and asking for a change gets an edit. Saying "don't change anything" works as you'd expect.

## File context

Running `:Lm` without a range, from a line in some file, sends that file along as read-only context, with the cursor line marked. If the file is up to `context.max_lines` long (300 by default), the whole file goes. Otherwise the model gets that many lines centred on the cursor and can read the rest with `read_file`. The log shows what went:

```
> what does this do?
  ⎿ lua/nvlm/ui.lua:212 (lines 63-362)
```

The file is only sent again if it changed or you moved far enough for the window to shift. Otherwise the model is just told where the cursor is now. Messages typed into the chat pane are follow-ups and add no file context. The exception is the first message after a bare `:Lm`, which carries the file you opened the chat from.

This context can't be edited. To let the model change code, select it (`:'<,'>Lm`). Disable file context with `context = { enabled = false }`.

## Tools

One selection isn't always enough context, so the model can also look around on its own. It calls tools, sees the results, and keeps going until it has an answer. Each call shows up in the log:

```
> where else is this called?
  ⎿ edit.lua:271-297

⏺ Search `replace_selection`
  ⎿ 3 matches

⏺ Read `lua/nvlm/tools.lua:150-170`
  ⎿ 21 lines

⏺ It's only called by the replace_selection tool (tools.lua:165)…
```

| Tool | What it does |
|---|---|
| `replace_selection` | Rewrites the active selection (see above) |
| `detach_selection` | Drops the active selection once the conversation has moved on to other code |
| `read_file` | Reads a file, or a range of its lines. Open buffers are read with their unsaved changes. |
| `list_files` | Lists files, optionally under a directory or matching a glob, skipping gitignored files |
| `search` | Searches files for a regex, e.g. to find where a function is called |
| `ask_user` | Asks you a clarifying question (marked `?` in the log). It ends the model's turn, and your next message is the answer. |

So you can say "find the config loader and check it handles a missing file" or "how does this compare to the version in `utils/old.py`?"

The read tools only see files inside Neovim's working directory (`:pwd`); paths outside it, including through symlinks, are refused. `list_files` and `search` use [ripgrep](https://github.com/BurntSushi/ripgrep) if it's installed and fall back to `git`. Turn the read tools off with `tools = { read = false }`.

A message gets at most `tools.max_rounds` model responses (default 10). If the model is still calling tools after that, it stops, and your next message lets it continue. `:LmStop` cancels at any point. Tool calls that already ran stay in the conversation.

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
  context = {
    enabled = true,  -- send the current file with a rangeless :Lm
    max_lines = 300, -- whole file up to this, else this many lines around the cursor
  },
  tools = {
    read = true,     -- read_file, list_files and search, confined to the working directory
    max_rounds = 10, -- model responses per message before it has to stop and wait
  },
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
| `NvlmTool` | `Special` | Tool call bullets |
| `NvlmQuestion` | `DiagnosticInfo` | The `?` on the model's questions |
| `NvlmError` | `DiagnosticError` | Errors |
| `NvlmSelection` | `DiagnosticInfo` | Sign-column bar on the active selection |
| `NvlmModified` | `DiagnosticWarn` | `modified` in the input pane's top bar |

## Limitations

- Selections are always whole lines.
- One request at a time.
- Only the active selection can be edited. The model can read the rest of the project but can't change it.
- `list_files` and `search` run synchronously, so a search over a very large project can freeze the editor briefly (for up to 10 seconds).
