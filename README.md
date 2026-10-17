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
- `curl`
- [Ollama](https://ollama.com) running locally, with a model that supports tool calling (needed for edits)

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
| Input pane | `<CR>` (normal & insert) | Send |
| Input pane | `<C-j>` (insert) | New line |
| Either | `q` | Close the chat pane and the input pane |

Set `vim.g.nvlm_no_abbrev = true` before the plugin loads to disable the `:lm` → `:Lm` abbreviation.

## How edits work

When you run `:Lm` on a selection, those lines become the active selection. An extmark (a position marker that Neovim moves as you edit) tracks them, so the right lines get edited even if you change other parts of the file while chatting.

While a selection is active, the model has a `replace_selection` tool. Calling it replaces the whole selection with new code as a single undo step, and the log records the edit along with the new code. After an edit, the selection covers the new code, so you can keep asking for changes.

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
  },
  system_prompt = "...", -- see lua/nvlm/config.lua
  default_prompt = "Review this code. Point out bugs or anything that looks wrong.",
  ui = {
    width = 0.3,      -- fraction of the editor width
    input_height = 5, -- lines
  },
})
```

### Highlights

These groups are linked by default and can be overridden:

| Group | Default link | Used for |
|---|---|---|
| `NvlmPrompt` | `Comment` | Your prompts |
| `NvlmPending` | `Comment` | The "thinking…" placeholder |
| `NvlmBullet` | `Normal` | Response bullets |
| `NvlmEdit` | `DiagnosticOk` | Edit bullets |
| `NvlmError` | `DiagnosticError` | Errors |

## Limitations

- Only Ollama is supported for now.
- Selections are always whole lines.
- The model doesn't see edits you make to the selection by hand until you run `:Lm` on it again.
- One request at a time.
