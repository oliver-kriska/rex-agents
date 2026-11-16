-- rex-agents actions for init.lua:
--
--   require("rex-agents.actions"){}            -- default keys
--   require("rex-agents.actions"){ keys = { revive = "cmd+shift+b", open = false } }
--
-- Interactive commands (pickers, the close prompt) run the rex-agents CLI in a floating pane.
-- Saving a template runs right here, in the action. The core module is loaded on first use,
-- so a broken core can never stop init.lua from loading.

local here = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$") or "."

return function(opts)
  opts = opts or {}
  local home = os.getenv("HOME")
  local bin = opts.bin or (home .. "/.config/rex/bin/rex-agents")
  local keys = { revive = "cmd+shift+b", open = "cmd+shift+t" }
  for k, v in pairs(opts.keys or {}) do keys[k] = v end

  local core
  local function A()
    if not core then
      package.path = here .. "/../?.lua;" .. package.path
      core = require("rex-agents.core")
    end
    return core
  end

  local function floating(ctx, label, argv)
    local cmd = { bin }
    for _, a in ipairs(argv) do cmd[#cmd + 1] = a end
    local _, err = rex.session.new_layer{
      session_id = ctx.session_id,
      bounds = { 0.12, 0.12, 0.76, 0.7 }, focus = true,
      layout = { block = {
        flavor = "com.superlogical.terminal.shell", label = label,
        options = { cwd = home, command = cmd },
      } },
    }
    if err then error(tostring(err), 0) end
  end

  local function window_of(ctx)
    if ctx.window_id then return ctx.window_id end
    local v = rex.session.view{ session_id = ctx.session_id }
    for _, w in ipairs(v and v.windows or {}) do
      for _, l in ipairs(w.layers or {}) do
        for _, b in ipairs(l.blocks or {}) do
          if b.block_id == ctx.block_id then return w.window_id end
        end
      end
    end
  end

  local function save_template(ctx, args, whole_session)
    local wid
    if not whole_session then
      wid = window_of(ctx)
      if not wid then error("can't tell which tab this is", 0) end
    end
    local name = args and args.name ~= "" and args.name or nil
    local r = A().template_save(ctx.session_id, name, wid)
    return { saved = r.saved, windows = r.windows }
  end

  rex.action{
    name = "revive_agents", title = "Agents: Bring Back After Restart", category = "Agents",
    keywords = "restore resume revive restart reboot claude amp",
    description = "Lists the saved agents whose panes are now empty shells; enter retypes their commands",
    run = function(ctx) floating(ctx, "revive", { "revive", "--save-first", "--pick", "--pause" }) end,
  }
  rex.action{
    name = "open_project", title = "Agents: Open Project Template", category = "Agents",
    keywords = "template project session new start",
    description = "Pick a template from ~/.config/rex/templates and open it as a new session",
    run = function(ctx) floating(ctx, "projects", { "template-open", "--pick" }) end,
  }
  rex.action{
    name = "save_session_template", title = "Agents: Save Session as Template", category = "Agents",
    description = "Saves every tab of this session, with the commands running now, to ~/.config/rex/templates",
    args = { name = "string?" },
    run = function(ctx, args) return save_template(ctx, args, true) end,
  }
  rex.action{
    name = "save_tab_template", title = "Agents: Save Tab as Template", category = "Agents",
    description = "Saves this tab, with the commands running now, to ~/.config/rex/templates",
    args = { name = "string?" },
    run = function(ctx, args) return save_template(ctx, args, false) end,
  }
  rex.action{
    name = "park_session", title = "Agents: Park Session (close, reopen later)", category = "Agents",
    keywords = "park close template save later continue resume",
    description = "Saves this session as a template that continues its conversations, then asks to close it",
    run = function(ctx) floating(ctx, "park", { "park", ctx.session_id }) end,
  }

  if keys.revive then rex.bind(keys.revive, "revive_agents") end
  if keys.open then rex.bind(keys.open, "open_project") end
end
