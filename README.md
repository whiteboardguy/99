# 99.nvim
Neovim-first AI workflow plugin for visual edits, search, vibe, and tutorial generation through local CLI providers.

## Features
- Visual-selection rewrite workflow (`_99.visual()`)
- Project search workflow with quickfix results (`_99.search()`)
- Vibe workflow with quickfix results (`_99.vibe()`)
- Tutorial generation workflow (`_99.tutorial()`)
- Provider abstraction (OpenCode, Claude Code, Cursor Agent, Kiro, Gemini CLI)
- Runtime model/provider switching APIs
- Prompt references with `#rules` and `@files` completion
- In-flight request status window and per-request logs

## Requirements
- **Neovim:** `0.10+` (uses `vim.system` and modern `vim.uv` APIs)
- **At least one provider CLI installed and authenticated:**
  - `opencode`
  - `claude`
  - `cursor-agent`
  - `kiro-cli`
  - `gemini`

## Installation
```lua
vim.pack.add({"https://github.com/ThePrimeagen/99"})

local _99 = require("99")

_99.setup({
  model = "opencode/claude-sonnet-4-5",
  provider_extra_args = {},
  tmp_dir = "./.tmp",
  md_files = { "AGENT.md" },
  logger = {
    level = _99.INFO,
    path = "/tmp/99.debug",
    print_on_error = true,
  },
  completion = {
    custom_rules = {},
  },
})

vim.keymap.set("v", "<leader>9v", function()
  _99.visual()
end, { desc = "99: replace selection via LLM" })

vim.keymap.set("n", "<leader>9s", function()
  _99.search()
end, { desc = "99: search project via LLM" })

vim.keymap.set("n", "<leader>9x", function()
  _99.stop_all_requests()
end, { desc = "99: stop all requests" })
```

## Configuration reference

| Option | Type | Default | Description |
|---|---|---|---|
| `model` | `string?` | provider default | Model ID used by current provider. |
| `provider` | `_99.Providers.BaseProvider?` | `OpenCodeProvider` | Active provider implementation. |
| `provider_extra_args` | `string[]?` | `{}` | Extra CLI flags appended to provider command (inserted before prompt positional arg). |
| `opencode_no_session_persistence` | `boolean?` | `true` | When provider is OpenCode, adds `--no-session-persistence` so 99.nvim runs do not appear in normal project session history. |
| `display_errors` | `boolean?` | `false` | Enables user-facing error display behavior used by plugin internals. |
| `auto_add_skills` | `boolean?` | `false` | Reserved/forward option in current codepath. |
| `tmp_dir` | `string?` | `"./tmp"` | Temp directory used for state and request temp files. |
| `md_files` | `string[]?` | `{}` | Markdown filenames auto-injected while walking from current file dir up to cwd. |
| `logger` | `_99.Logger.Options?` | internal defaults | Logger configuration (`level`, `type`, `path`, etc.). |
| `completion` | `_99.Completion?` | `{ source = "native", custom_rules = {}, files = {} }` | Prompt completion source and providers (`#rules`, `@files`). |
| `in_flight_options` | `_99.StatusWindow.Opts?` | internal defaults | In-flight status window and throbber timing/options. |

### `completion` shape
| Field | Type | Default | Notes |
|---|---|---|---|
| `source` | `"native" \| "cmp" \| "blink" \| nil` | `"native"` | Completion backend for prompt buffer. |
| `custom_rules` | `string[]` | `{}` | Directories scanned for rule files/skills. |
| `files` | `_99.Files.Config?` | enabled defaults | Controls file discovery for `@file` completion. |

## Providers

| Provider | CLI | Default model |
|---|---|---|
| `OpenCodeProvider` | `opencode` | `opencode/claude-sonnet-4-5` |
| `ClaudeCodeProvider` | `claude` | `claude-sonnet-4-5` |
| `CursorAgentProvider` | `cursor-agent` | `sonnet-4.5` |
| `KiroProvider` | `kiro-cli` | `claude-sonnet-4.5` |
| `GeminiCLIProvider` | `gemini` | `auto` |

## Usage

### Visual
Use a visual selection, then:
```lua
require("99").visual()
```

### Search
```lua
require("99").search()
```

### Vibe
```lua
require("99").vibe()
```

### Tutorial
```lua
require("99").tutorial({})
```

### Open (re-open previous successful request)
```lua
require("99").open()
```

### View logs
```lua
require("99").view_logs()
```

### Stop all active requests
```lua
require("99").stop_all_requests()
```

### Set model
```lua
require("99").set_model("opencode/claude-sonnet-4-5")
```

### Set provider
```lua
local _99 = require("99")
_99.set_provider(_99.Providers.ClaudeCodeProvider)
```

## Notes

### File completion (`@file`)
- In git repos, discovery uses `git ls-files` (plus configured excludes).
- Outside git repos, discovery falls back to filesystem scanning.
- Excludes apply in both modes.

### Model picker
If you use Telescope or fzf-lua:
```lua
require("99.extensions.telescope").select_model()
require("99.extensions.telescope").select_provider()
```
```lua
require("99.extensions.fzf_lua").select_model()
require("99.extensions.fzf_lua").select_provider()
```
OpenCode model picker entries come from `opencode models`.

### Logging
- Use `_99.view_logs()` to inspect request logs from inside Neovim.
- For file logging, set `logger = { type = "file", path = "/tmp/99.log", level = _99.DEBUG }`.
