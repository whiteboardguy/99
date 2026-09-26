local BaseProvider = require("99.providers.base")

--- @class KiroProvider : _99.Providers.BaseProvider
local KiroProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function KiroProvider._build_command(_, query, context)
  return {
    "kiro-cli",
    "chat",
    "--no-interactive",
    "--model",
    context.model,
    "--trust-all-tools",
    query,
  }
end

--- @return string
function KiroProvider._get_provider_name()
  return "KiroProvider"
end

--- @return string
function KiroProvider._get_default_model()
  return "claude-sonnet-4.5"
end

return KiroProvider
