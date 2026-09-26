local Window = require("99.window")
local Consts = require("99.consts")
local Throbber = require("99.ops.throbber")

--- @alias _99.StatusWindow.State "init" | "running"

--- @class _99.StatusWindow.Opts
--- this is pure a class for testing.   helps controls timings
--- @docs include
--- @field throbber_opts _99.Throbber.Opts | nil
--- options for the throbber in the top left
--- @field in_flight_interval number | nil
--- frequency in which the in-flight interval checks to see if it should be
--- displayed / removed
--- @field enable boolean | nil
--- defaults to true

--- @param opts _99.StatusWindow.Opts | nil
--- @return _99.StatusWindow.Opts
local function default_opts(opts)
  opts = opts or {}
  opts.throbber_opts = opts.throbber_opts
    or {
      throb_time = Consts.throbber_throb_time,
      cooldown_time = Consts.throbber_cooldown_time,
      tick_time = Consts.throbber_tick_time,
    }
  opts.in_flight_interval = opts.in_flight_interval
    or Consts.show_in_flight_requests_loop_time
  opts.enable = opts.enable == nil and true or opts.enable
  return opts
end

--- @class _99.StatusWindow
--- @field opts _99.StatusWindow.Opts
--- @field state _99.StatusWindow.State
--- @field win _99.window.Window | nil
--- @field throbber _99.Throbber | nil
--- @field _99 _99.State
local StatusWindow = {}
StatusWindow.__index = StatusWindow

--- @param _99 _99.State
--- @param opts _99.StatusWindow.Opts | nil
function StatusWindow.new(_99, opts)
  return setmetatable({
    opts = default_opts(opts),
    state = "init",
    _99 = _99,
  }, StatusWindow)
end

function StatusWindow:_shutdown()
  if self.throbber then
    self.throbber:stop()
  end

  local win = self.win
  if win ~= nil then
    Window.close(win)
  end
  self.win = nil
  self.throbber = nil
end

--- single line: spinner, active request count, and the operation names.
--- e.g. `⠋ 2 · search visual`
---
--- @param icon string
function StatusWindow:_render(icon)
  local win = self.win
  if win == nil or not Window.valid(win) then
    self:_shutdown()
    return
  end

  local count = self._99.tracking:active_count()
  if count == 0 then
    self:_shutdown()
    return
  end

  local operations = {}
  for _, context in ipairs(self._99.tracking:active()) do
    if context.state == "requesting" then
      table.insert(operations, context.operation)
    end
  end
  table.sort(operations)

  local text = icon .. " " .. tostring(count)
  if #operations > 0 then
    text = text .. " · " .. table.concat(operations, " ")
  end
  Window.set_status_text(win, text)
end

function StatusWindow:_run_loop()
  if self.state ~= "running" then
    self:_shutdown()
    return
  end
  vim.defer_fn(function()
    self:_run_loop()
  end, self.opts.in_flight_interval)

  Window.refresh_active_windows()

  --- idle: take the strip away
  if self._99.tracking:active_count() == 0 then
    self:_shutdown()
    return
  end

  --- a capture prompt owns the screen; the strip comes back when it closes
  if self.win == nil and Window.has_capture_window() then
    return
  end

  if self.win == nil or not Window.valid(self.win) then
    local ok, win = pcall(Window.status_window)
    if not ok then
      --- TODO: There needs to be a way to display logs for "all active requests"
      --- this is its own activity and should not be added to any work set
      return
    end

    self.win = win
    self.throbber = Throbber.new(function(icon)
      self:_render(icon)
    end, self.opts.throbber_opts)
    self.throbber:start()
  end
end

function StatusWindow:start()
  if not self.opts.enable then
    return
  end

  assert(
    self.state == "init",
    "you cannot start an inflight request if we are not in init state: "
      .. self.state
  )

  self.state = "running"
  self:_run_loop()
end

function StatusWindow:stop()
  if not self.opts.enable then
    return
  end
  assert(
    self.state == "running",
    "you cannot stop a running status window if its not running"
  )
  self.state = "init"
end

return StatusWindow
