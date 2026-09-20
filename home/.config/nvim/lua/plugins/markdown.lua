-- Markdown viewing, carried over from the old AstroNvim config on Pop!_OS.
--
-- There it came from two places: the astrocommunity pack
-- "markdown-and-latex.render-markdown-nvim" for in-buffer rendering, and a
-- hand-written spec in lua/plugins/user.lua for the browser preview. LazyVim
-- has no astrocommunity, so the pack is expanded into a plain spec here; the
-- preview keeps its original setup options and <Leader>m mappings verbatim.

return {
  -- In-buffer rendering: headings, tables, code blocks, list bullets and
  -- checkboxes drawn in the buffer itself. Renders the line you are not on
  -- and shows raw markdown on the cursor line, so editing still works.
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    cmd = "RenderMarkdown",
    -- LazyVim already loads mini.icons, which this uses for code-block and
    -- callout icons, so treesitter is the only dependency worth declaring.
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    opts = {},
  },

  -- Browser preview served by live-server, with mermaid diagram support.
  -- "takeover" reuses one browser tab instead of opening a new one per file.
  -- Port 0 lets the OS pick a free port.
  {
    "selimacerbas/markdown-preview.nvim",
    dependencies = { "selimacerbas/live-server.nvim" },
    ft = { "markdown" },
    keys = {
      {
        "<leader>mp",
        function() require("markdown_preview").start() end,
        desc = "Preview start",
      },
      {
        "<leader>ms",
        function() require("markdown_preview").stop() end,
        desc = "Preview stop",
      },
      {
        "<leader>mr",
        function() require("markdown_preview").refresh() end,
        desc = "Preview refresh",
      },
    },
    config = function()
      require("markdown_preview").setup({
        instance_mode = "takeover",
        port = 0,
        open_browser = true,
        debounce_ms = 300,
        mermaid_elk = true,
      })
    end,
  },

  -- Name the <Leader>m group so which-key labels it the way AstroNvim did.
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>m", group = "markdown" },
      },
    },
  },
}
