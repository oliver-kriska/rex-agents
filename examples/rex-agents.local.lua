-- ~/.config/rex/rex-agents.local.lua: rex-agents settings for this machine.
-- Every key is optional; lists add to the defaults.
return {
  -- Programs restarted with the same arguments after a server restart
  -- (defaults: glow, btop, htop, lazygit).
  viewers = { "ngrok" },

  -- Panes recognised by their label and the end of their working directory, restarted with a
  -- fixed command whatever was running in them.
  labelled = {
    -- api = { cwd_suffix = "/my-app", cmd = { "mix", "phx.server" } },
  },

  -- Service panes recognised by label. When one of them is an idle shell after a restart,
  -- revive runs the init.lua action named here once for that session
  -- (`rex do -s SESSION <action>`). In templates, each label gets the command given, or the
  -- running program's own arguments when the value is `true`.
  services = {
    labels = {
      -- server = "mix phx.server",
      -- tunnel = true,
    },
    -- action = "start_services",
  },

  -- Seconds a saved pane whose block has disappeared is kept (default one week).
  -- keep_missing = 7 * 86400,
}
