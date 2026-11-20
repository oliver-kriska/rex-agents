-- rex-agents actions for init.lua:
--
--   require("rex-agents.actions"){}            -- default keys
--   require("rex-agents.actions"){ keys = { revive = "cmd+shift+b", open = false } }
--
-- Prompts run directly in actions (never under pcall or callbacks). Older servers/clients
-- use the existing floating CLI. Slow launches stay outside the action in that CLI.

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

  -- Servers before preview.21 have no rex.ui. Actions check this before any slow work, so
  -- those servers get exactly the floating-pane behaviour of v0.1.
  local function has_ui() return type(rex.ui) == "table" and rex.ui.pick ~= nil and rex.ui.input ~= nil end

  local function prompt(kind, fields, fallback)
    if not has_ui() then return nil, fallback() end
    local answer, reason, detail = rex.ui[kind](fields)
    if answer ~= nil then return answer end
    if reason == "cancelled" or reason == "timeout" then return nil end
    if reason == "failed" then print("rex-agents prompt failed: " .. tostring(detail or reason)) end
    return nil, fallback()
  end

  local function notice(text, fallback)
    return prompt("pick", { title = text, items = { { id = "ok", title = "OK", icon = "terminal" } } }, fallback)
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
    local v = A().view(ctx.session_id)
    if not v then error("session not found", 0) end
    if not name then
      local fallback
      name, fallback = prompt("input", { title = "Save " .. (whole_session and "session" or "tab") .. " as template",
        value = A().template_default_name(v, wid), confirm = "Save" }, function()
          local r = A().template_save(ctx.session_id, nil, wid, v)
          return { saved = r.saved, windows = r.windows }
        end)
      if name == nil then return fallback end
      if not name:match("%S") then return end
    end
    local r = A().template_save(ctx.session_id, name, wid, v)
    return { saved = r.saved, windows = r.windows }
  end

  rex.action{
    name = "revive_agents", title = "Agents: Bring Back After Restart", category = "Agents",
    keywords = "restore resume revive restart reboot claude amp",
    description = "Lists the saved agents whose panes are now empty shells; enter retypes their commands",
    run = function(ctx)
      local function fallback() floating(ctx, "revive", { "revive", "--save-first", "--pick", "--pause" }) end
      if not has_ui() then return fallback() end
      pcall(A().save) -- like --save-first: a failed or skipped save still revives from the last one
      local plan = A().revive_plan()
      local items = A().revive_items(plan)
      if #items == 0 then return notice("Nothing to bring back: every saved pane is running or gone.", fallback) end
      local ids = prompt("pick", { title = "Bring back saved programs", multiple = true, items = items,
        confirm = "Start selected" }, fallback)
      if not ids or #ids == 0 then return end
      floating(ctx, "revive", { "revive", "--only", table.concat(ids, ","), "--linger" })
    end,
  }
  rex.action{
    name = "open_project", title = "Agents: Open Project Template", category = "Agents",
    keywords = "template project session new start",
    description = "Pick a template from ~/.config/rex/templates and open it as a new session",
    run = function(ctx)
      local function fallback() floating(ctx, "projects", { "template-open", "--pick" }) end
      if not has_ui() then return fallback() end
      local items = {}
      for _, name in ipairs(A().template_names()) do
        items[#items + 1] = { id = name, title = name, icon = "folder" }
      end
      if #items == 0 then return notice("No templates yet. Save a session as a template first.", fallback) end
      local name = prompt("pick", { title = "Open project template", items = items }, fallback)
      if not name then return end
      local mode = prompt("pick", { title = "Open " .. name, items = {
        { id = "continue", title = "Continue conversations", icon = "terminal" },
        { id = "fresh", title = "Fresh agents", icon = "plus" },
      } }, fallback)
      if not mode then return end
      local argv = { "template-open", name, "--linger" }
      if mode == "fresh" then argv[#argv + 1] = "--fresh" end
      floating(ctx, "projects", argv)
    end,
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
    run = function(ctx)
      if not has_ui() then return floating(ctx, "park", { "park", ctx.session_id }) end
      local v = A().view(ctx.session_id)
      if not v then error("session not found", 0) end
      local saved = A().template_save(ctx.session_id, nil, nil, v)
      local busy = A().busy_claude(v)
      local choice = prompt("pick", { title = "Saved " .. saved.name .. ". Close session?", items = {
        { id = "keep", title = "Keep open", icon = "terminal" },
        { id = "close", title = "Close session", icon = "folder",
          detail = #busy > 0 and "Claude is still working. Closing cuts those turns off." or "Reopen later from the template." },
      } }, function() floating(ctx, "park", { "park", ctx.session_id }) end)
      if choice == "close" then
        local _, err = A().close_session(ctx.session_id)
        if err then error(tostring(err), 0) end
      end
    end,
  }

  if keys.revive then rex.bind(keys.revive, "revive_agents") end
  if keys.open then rex.bind(keys.open, "open_project") end
end
