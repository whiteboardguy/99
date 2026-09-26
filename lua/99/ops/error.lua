local Window = require("99.window")
local utils = require("99.utils")

local M = {}

--- Report a request failure.  Default is a one-line vim.notify; with
--- `display_errors` set (or for fatal cases) a compact float carries the
--- message instead.
---
--- @param state _99.State | nil
--- @param message string
--- @param opts? { fatal?: boolean }
function M.report(state, message, opts)
  opts = opts or {}
  message = utils.one_line(tostring(message))

  if opts.fatal or (state ~= nil and state.display_errors) then
    Window.display_error(utils.truncate(message, 1000))
    return
  end

  vim.notify("[99] " .. utils.truncate(message, 300), vim.log.levels.ERROR)
end

return M
