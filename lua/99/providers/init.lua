local BaseProvider = require("99.providers.base")

return {
  BaseProvider = BaseProvider,
  OpenCodeProvider = require("99.providers.opencode"),
  ClaudeCodeProvider = require("99.providers.claude-code"),
  CursorAgentProvider = require("99.providers.cursor-agent"),
  KiroProvider = require("99.providers.kiro"),
  GeminiCLIProvider = require("99.providers.gemini-cli"),
  PiProvider = require("99.providers.pi"),
}
