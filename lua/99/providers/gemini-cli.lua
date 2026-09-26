local BaseProvider = require("99.providers.base")

--- @class GeminiCLIProvider : _99.Providers.BaseProvider
local GeminiCLIProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function GeminiCLIProvider._build_command(_, query, context)
  return {
    "gemini",
    "--approval-mode",
    -- Allow writing to temp files by default. See:
    -- https://geminicli.com/docs/core/policy-engine/#default-policies
    "auto_edit",
    "--model",
    context.model,
    "--prompt",
    query,
  }
end

--- @return string
function GeminiCLIProvider._get_provider_name()
  return "GeminiCLIProvider"
end

--- @return string
function GeminiCLIProvider._get_default_model()
  -- Default to auto-routing between pro and flash. See:
  -- https://geminicli.com/docs/cli/model/
  return "auto"
end

return GeminiCLIProvider
