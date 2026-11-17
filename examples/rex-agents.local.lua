-- ~/.config/rex/rex-agents.local.lua: rex-agents settings for this machine.
-- Every key is optional; lists add to the defaults.
return {
  -- Optional agent names for a message hub (off by default).
  -- hub = true,

  -- Additional shell names (extends zsh, -zsh, bash, -bash, sh, fish, login).
  -- shells = { "my-shell" },

  -- Programs restarted with the same arguments after a server restart (empty by default).
  viewers = {
    -- "glow", "btop", "htop", "lazygit", "ngrok",
  },

  -- Panes recognised by their label and the end of their working directory, restarted with a
  -- fixed command whatever was running in them. Existing matching processes anywhere on the
  -- machine prevent another launch, even when running in an unlabelled pane.
  labelled = {
    -- api = { cwd_suffix = "/my-app", cmd = { "mix", "phx.server" } },
    -- hub = { cwd_suffix = "/my-hub", cmd = { "/usr/local/bin/my-hub", "start" },
    --   running = { socket = "~/Library/Application Support/my-hub/hub.sock" }, ready = true },
    -- running.socket overrides argv matching for wrappers that exec another runtime. The socket
    -- must accept a connection; a stale file is not running. No payload is sent.
    -- ready = true waits for the running check (30 s). Alternatively use
    -- ready = { path = "~/Library/Application Support/my-hub/hub.sock", timeout = 30 }:
    -- that same socket must answer; other paths only need to exist. Timeout warns and continues.
    -- An already-running program is considered ready without waiting.
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
