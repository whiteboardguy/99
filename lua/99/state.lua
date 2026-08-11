local utils = require("99.utils")
local Agents = require("99.extensions.agents")
local Extensions = require("99.extensions")
local Tracking = require("99.state.tracking")
local Window = require("99.window")

local _99_STATE_FILE = "state"
local function default_completion()
  return { source = nil, custom_rules = {} }
end

--- cached rules + the signature they were built from; rules only get
--- re-globbed when the signature changes (setup runs, request starts, etc.)
--- @type {rules: _99.Agents.Rules, sig: string} | nil
local cached_rules

--- Cheap fingerprint of every rule directory: the dir mtime (catches
--- add/remove) plus the mtime of each direct SKILL.md and <name>/SKILL.md
--- (catches content edits).  Uses uv stats, not globs.
---
--- @param dirs string[]
--- @return string
local function rules_signature(dirs)
  local parts = {}
  for _, dir in ipairs(dirs) do
    local expanded = vim.fn.expand(dir)
    local stat = vim.uv.fs_stat(expanded)
    if not stat then
      table.insert(parts, expanded .. "=missing")
    else
      local sig = expanded .. "=" .. stat.mtime.sec .. ":" .. stat.mtime.nsec

      local direct = vim.uv.fs_stat(vim.fs.joinpath(expanded, "SKILL.md"))
      if direct then
        sig = sig .. "|direct=" .. direct.mtime.sec .. ":" .. direct.mtime.nsec
      end

      local handle = vim.uv.fs_scandir(expanded)
      if handle then
        local skills = {}
        while true do
          local name = vim.uv.fs_scandir_next(handle)
          if not name then
            break
          end
          local fstat =
            vim.uv.fs_stat(vim.fs.joinpath(expanded, name, "SKILL.md"))
          if fstat then
            table.insert(
              skills,
              name .. ":" .. fstat.mtime.sec .. ":" .. fstat.mtime.nsec
            )
          end
        end
        table.sort(skills)
        sig = sig .. "{" .. table.concat(skills, ",") .. "}"
      end
      table.insert(parts, sig)
    end
  end
  return table.concat(parts, ";")
end

--- @class _99.StateProps
--- @field model string
--- @field md_files string[]
--- @field prompts _99.Prompts
--- @field ai_stdout_rows number
--- @field display_errors boolean
--- @field auto_add_skills boolean
--- @field provider_override _99.Providers.BaseProvider | nil
--- @field __view_log_idx number
--- @field __tmp_dir string | nil
--- @field opencode_no_session_persistence boolean

--- unanswered question -- will i need to queue messages one at a time or
--- just send them all...  So to prepare ill be sending around this state object
--- @class _99.State
--- @field completion _99.Completion
--- @field model string
--- @field md_files string[]
--- @field prompts _99.Prompts
--- @field ai_stdout_rows number
--- @field display_errors boolean
--- @field provider_override _99.Providers.BaseProvider?
--- @field provider_extra_args string[]
--- @field rules _99.Agents.Rules
--- @field tracking _99.State.Tracking
--- @field __tmp_dir string | nil
--- @field opencode_no_session_persistence boolean
local State = {}
State.__index = State

--- @return _99.StateProps
local function create()
  return {
    model = "opencode/claude-sonnet-4-5",
    md_files = {},
    ai_stdout_rows = 3,
    display_errors = false,
    provider_override = nil,
    tmp_dir = nil,
    opencode_no_session_persistence = true,
  }
end

--- @param oos _99.Options | _99.State
local function get_tmp_dir(oos)
  local tmp_dir = oos.tmp_dir and type(oos.tmp_dir) == "string" and oos.tmp_dir
    or oos.__tmp_dir and oos.__tmp_dir
    or "./tmp"
  if tmp_dir then
    tmp_dir = vim.fn.expand(tmp_dir)
  end
  return tmp_dir
end

--- @param opts _99.Options
--- @return _99.State.Tracking.Serialized | nil
local function read_state_from_tmp(opts)
  local state_file = utils.named_tmp_file(get_tmp_dir(opts), _99_STATE_FILE)
  return utils.read_file_json_safe(state_file) --[[@as _99.State.Tracking.Serialized]]
end

--- @param opts _99.Options
--- @return _99.State
function State.new(opts)
  local props = create()
  local _99_state = setmetatable(props, State) --[[@as _99.State]]

  if opts.opencode_no_session_persistence ~= nil then
    assert(
      type(opts.opencode_no_session_persistence) == "boolean",
      "opts.opencode_no_session_persistence must be a boolean"
    )
    _99_state.opencode_no_session_persistence =
      opts.opencode_no_session_persistence
  end

  _99_state.provider_override = opts.provider
  _99_state.provider_extra_args = opts.provider_extra_args or {}
  _99_state.completion = opts.completion or default_completion()
  _99_state.completion.custom_rules = _99_state.completion.custom_rules or {}
  _99_state.completion.files = _99_state.completion.files or {}

  --- TODO: Prompt overrides would be a great thing, we just have to get there
  --- for now, i am going to have this as just a hardcoded ... thing
  _99_state.prompts = require("99.prompt-settings")

  local previous = read_state_from_tmp(opts)
  _99_state.tracking = Tracking.new(_99_state, previous)

  return _99_state
end

function State:sync()
  local tracking = self.tracking:serialize()
  local tmp = self:tmp_dir()
  local file = utils.named_tmp_file(tmp, _99_STATE_FILE)
  utils.write_file_json_safe(tracking, file)
end

--- @return string
function State:tmp_dir()
  return get_tmp_dir(self)
end

--- @return boolean
function State:active()
  _ = self
  if Window.has_active_window() then
    return true
  end

  local qf = vim.fn.getqflist({ winid = 0 })
  return qf.winid ~= 0
end

--- TODO: This is something to understand.  I bet that this is going to need
--- a lot of performance tuning.  I am just reading every file, and this could
--- take a decent amount of time if there are lots of rules.
---
--- The rules themselves are now cached and only re-globbed when the rule
--- directories change (see rules_signature above); this runs on every prompt
--- creation but is now just a handful of uv.fs_stat calls.
function State:refresh_rules()
  local dirs = self.completion.custom_rules or {}
  local sig = rules_signature(dirs)
  if not cached_rules or cached_rules.sig ~= sig then
    local rules = Agents.rules(self)
    cached_rules = {
      rules = rules,
      sig = sig,
    }
  end
  self.rules = cached_rules.rules
  Extensions.refresh(self)
end

return State
