-- ~/.config/rex/rex-agents.local.lua: rex-agents settings for this machine.
-- Every key is optional; lists add to the defaults.
return {
  -- Programs restarted with the same arguments after a server restart
  -- (defaults: glow, btop, htop, lazygit).
  viewers = { "ngrok" },

  -- Panes recognised by their label and the end of their working directory, restarted with a
  -- fixed command whatever was running in them. Existing matching processes anywhere on the
  -- machine prevent another launch, even when running in an unlabelled pane.
  labelled = {
    -- api = { cwd_suffix = "/my-app", cmd = { "mix", "phx.server" } },
    -- hub = { cwd_suffix = "/my-hub", cmd = { "/usr/local/bin/my-hub", "start" },
    --   ready = { path = "~/Library/Application Support/my-hub/hub.sock", timeout = 30 } },
    -- Optional readiness: wait for the path before agents start. Timeout warns and continues;
    -- an already-running program is considered ready without waiting. Default timeout: 30 s.
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

  -- After a Rex server restart the watcher shows one macOS notification saying how many panes
  -- ⌘⇧B can bring back (default on). It never types into panes.
  -- notify = false,
}
