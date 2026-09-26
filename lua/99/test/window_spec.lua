-- luacheck: globals describe it assert before_each after_each
---@diagnostic disable: undefined-field, duplicate-set-field
local Window = require("99.window")
local eq = assert.are.same

describe("Window", function()
  local previous_list_uis

  before_each(function()
    previous_list_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function()
      return {
        { width = 120, height = 40 },
      }
    end
  end)

  after_each(function()
    vim.api.nvim_list_uis = previous_list_uis
    Window.clear_active_popups()
  end)

  it("shows keymap legend window and applies keyoffset", function()
    local win = Window.capture_input("Prompt", {
      cb = function() end,
      keymap = {
        q = "cancel",
        ["<CR>"] = "submit",
      },
    })
    eq(2, #Window.active_windows)
    eq(3, vim.wo[win.win_id].scrolloff)

    local legend = Window.active_windows[2]
    local lines = vim.api.nvim_buf_get_lines(legend.buf_id, 0, -1, false)
    eq({ " <CR>=submit q=cancel" }, lines)
  end)

  it("highlights keymap legend as warning=comment", function()
    Window.capture_input("Prompt", {
      cb = function() end,
      keymap = {
        q = "cancel",
        ["<CR>"] = "submit",
      },
    })

    local legend = Window.active_windows[2]
    local legend_nsid = vim.api.nvim_get_namespaces()["99.window.legend"]
    local extmarks = vim.api.nvim_buf_get_extmarks(
      legend.buf_id,
      legend_nsid,
      0,
      -1,
      { details = true }
    )

    local highlights = {}
    for _, extmark in ipairs(extmarks) do
      table.insert(highlights, {
        extmark[2],
        extmark[3],
        extmark[4].end_col,
        extmark[4].hl_group,
      })
    end

    eq({
      { 0, 1, 5, "WarningMsg" },
      { 0, 6, 12, "Comment" },
      { 0, 13, 14, "WarningMsg" },
      { 0, 15, 21, "Comment" },
    }, highlights)
  end)

  it("updates width even when the height is unchanged", function()
    local win = Window.capture_input("Prompt", {
      cb = function() end,
      keymap = {},
    })
    local before = vim.api.nvim_win_get_config(win.win_id)

    Window.resize(win, before.width + 5, before.height)

    local after = vim.api.nvim_win_get_config(win.win_id)
    eq(before.width + 5, after.width)
    eq(before.height, after.height)
  end)

  it("renders the status strip as a single borderless line", function()
    local win = Window.status_window()
    Window.set_status_text(win, "⠋ 2 · search visual")

    local lines = vim.api.nvim_buf_get_lines(win.buf_id, 0, -1, false)
    eq({ "⠋ 2 · search visual" }, lines)

    local config = vim.api.nvim_win_get_config(win.win_id)
    eq(1, config.height)
    assert.is_true(config.border == nil or config.border == "none")
    eq(false, config.focusable)
  end)
end)
