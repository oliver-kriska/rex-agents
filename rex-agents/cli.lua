-- rex-agents command line. Run through the bin/rex-agents wrapper, which passes the
-- arguments in REX_AGENTS_ARGV (separated by \31) so they arrive exactly as typed:
--
--   rex-agents save                   record every pane's program (watch.lua does this continuously)
--   rex-agents revive [--pick|--dry-run] [--save-first] [--pause]
--                                     after a Rex server restart, retype each saved command into its pane
--   rex-agents template-save SESSION_ID [NAME] [--window WINDOW_ID]
--                                     save a session's tabs (or one tab) as ~/.config/rex/templates/NAME.json
--   rex-agents template-open [NAME|--pick] [--fresh]
--                                     open a template as a new session (continues saved conversations unless --fresh)
--   rex-agents park SESSION_ID [NAME] save as a template with conversations, then offer to close the session
--   rex-agents template-list
--   rex-agents tab-to-session SESSION_ID WINDOW_ID NAME
--                                     copy a tab into a new session NAME, resume commands typed but not run;
--                                     close the old tab, then: rex-agents start-pending NAME
--   rex-agents start-pending NAME
--   rex-agents status [--json]        each agent pane's hub name and whether its program already has it
--   rex-agents verify [--against FILE]
--                                     check panes.json and the watcher; with FILE (a copy of panes.json
--                                     taken before a change), list missing entries and changed commands

local here = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path
local A = require("rex-agents.core")

local USAGE = [[
rex-agents: remember what runs in each Rex pane and bring it back.

  rex-agents save
  rex-agents revive [--pick|--dry-run] [--save-first] [--pause]
  rex-agents template-save SESSION_ID [NAME] [--window WINDOW_ID]
  rex-agents template-open [NAME|--pick] [--fresh]
  rex-agents park SESSION_ID [NAME]
  rex-agents template-list
  rex-agents tab-to-session SESSION_ID WINDOW_ID NAME
  rex-agents start-pending NAME
  rex-agents status [--json]
  rex-agents verify [--against FILE]

Rex restores sessions, tabs, splits, pane labels and cwd itself, under the same block IDs,
but no programs. Only known programs are recorded: Claude Code (resumed by session ID, with
the flags it was started with), Amp (resumed by thread), and a few viewers.]]

local function args()
  local raw = os.getenv("REX_AGENTS_ARGV")
  local out = {}
  if raw and raw ~= "" then
    for a in (raw):gmatch("([^\31]*)\31") do out[#out + 1] = a end
  else -- `rex do cli.lua a1=save a2=--pick`
    local i = 1
    while rex.args and rex.args["a" .. i] ~= nil do
      out[#out + 1] = tostring(rex.args["a" .. i]); i = i + 1
    end
  end
  return out
end

local function flag(a, f)
  for _, x in ipairs(a) do if x == f then return true end end
  return false
end

-- positional arguments after the command, skipping --flags and the value of --window
local function positional(a)
  local out = {}
  for i = 2, #a do
    if not a[i]:match("^%-%-") and a[i - 1] ~= "--window" then out[#out + 1] = a[i] end
  end
  return out
end

local function pause_key()
  io.write("\npress any key"); io.flush()
  A.exec({ "sh", "-c", "stty -icanon -echo </dev/tty; dd bs=1 count=1 </dev/tty >/dev/null 2>&1; stty icanon echo </dev/tty" },
    { timeout = 86400 })
end

local function fzf(rows, opts)
  local argv = { "fzf" }
  for _, o in ipairs(opts) do argv[#argv + 1] = o end
  local r, err = A.exec(argv, { stdin = table.concat(rows, "\n") .. "\n", timeout = 86400 })
  if not r then error("fzf: " .. tostring(err), 0) end
  if r.code ~= 0 then return nil end
  local out = {}
  for l in r.stdout:gmatch("[^\n]+") do out[#out + 1] = l end
  return out
end

local function cmd_save()
  local r = A.save()
  print(r.skipped or string.format("saved %d panes", r.panes))
end

local function cmd_revive(a)
  local pick, dry = flag(a, "--pick"), flag(a, "--dry-run") or flag(a, "--dry")
  if flag(a, "--save-first") then pcall(A.save) end
  local plan = A.revive_plan()
  for _, s in ipairs(plan.skipped) do print("skipped: " .. tostring(s.label) .. ": " .. s.reason) end
  if #plan.todo == 0 and #plan.services == 0 then
    print("Nothing to bring back: every saved pane is running or gone.")
    return
  end
  if dry then
    for _, t in ipairs(plan.todo) do print(A.revive_row(t)) end
    for _, s in ipairs(plan.services) do print("services: rex do -s " .. s .. " " .. tostring(A.config.services.action)) end
    return
  end
  local chosen = {}
  for _, t in ipairs(plan.todo) do chosen[t.bid] = true end
  if pick and #plan.todo > 0 then
    local rows = {}
    for _, t in ipairs(plan.todo) do rows[#rows + 1] = t.bid .. "\t" .. A.revive_row(t) end
    local sel = fzf(rows, { "--multi", "--reverse", "--with-nth=2..", "--delimiter=\t", "--bind=load:select-all",
      "--prompt=revive> ", "--header=tab: toggle · enter: start the selected · esc: cancel" })
    if not sel then return end
    chosen = {}
    for _, l in ipairs(sel) do chosen[l:match("^([^\t]*)")] = true end
  end
  local function start(t)
    if chosen[t.bid] then
      local ok, err = A.start_command(t.sid, t.bid, t.line, t.labelled)
      if not ok then
        print("skipped: " .. (t.e.session or "") .. " / " .. (t.e.window or "") .. ": " .. tostring(err))
      else
        print("started: " .. (t.e.session or "") .. " / " .. (t.e.window or "") .. " → " .. A.join(t.argv):sub(1, 80))
        if err then print("warning: " .. err) end
      end
    end
  end
  for _, t in ipairs(plan.todo) do if t.labelled then start(t) end end
  for _, s in ipairs(plan.services) do
    local out, err = A.run_services(s)
    print("services: " .. tostring(out or err):sub(1, 200))
  end
  for _, t in ipairs(plan.todo) do if not t.labelled then start(t) end end
end

local function cmd_template_save(a)
  local p = positional(a)
  local win
  for i, x in ipairs(a) do if x == "--window" then win = a[i + 1] end end
  if not p[1] then error("usage: rex-agents template-save SESSION_ID [NAME] [--window WINDOW_ID]", 0) end
  local r = A.template_save(p[1], p[2], win)
  print(rex.json.encode({ saved = r.saved, windows = r.windows }))
end

local function cmd_template_open(a)
  local name = positional(a)[1]
  local fresh = flag(a, "--fresh")
  if flag(a, "--pick") or not name then
    local names = A.template_names()
    if #names == 0 then
      print('No templates yet. Run "Save Session as Template" in a session first.')
      rex.sleep(2)
      return
    end
    local rows = {}
    for _, n in ipairs(names) do
      local ok, t = pcall(A.load_template, n)
      if ok and A.template_has_resume(t) then
        rows[#rows + 1] = string.format("%s\tcontinue\t%-24s continue conversations  (parked %s)", n, n, t.saved_at or "")
      end
      if ok then rows[#rows + 1] = string.format("%s\tfresh\t%-24s fresh agents", n, n) end
    end
    local sel = fzf(rows, { "--reverse", "--prompt=open project> ", "--with-nth=3..", "--delimiter=\t",
      "--header=enter: open as a new session · esc: cancel" })
    if not sel or not sel[1] then return end
    local mode
    name, mode = sel[1]:match("^([^\t]*)\t([^\t]*)")
    fresh = mode == "fresh"
  end
  local r, msg = A.template_open(name, fresh)
  if not r then
    print(msg)
    rex.sleep(2.5)
    return
  end
  print(rex.json.encode(r))
end

local function cmd_park(a)
  local p = positional(a)
  local sid, name = p[1], p[2]
  if not sid then error("usage: rex-agents park SESSION_ID [NAME]", 0) end
  local v = A.view(sid)
  if not v then error("session " .. sid .. " not found", 0) end
  local r = A.template_save(sid, name, nil, v)
  print(rex.json.encode({ saved = r.saved, windows = r.windows }))
  local busy = A.busy_claude(v)
  if #busy > 0 then
    print("\nStill working: " .. table.concat(busy, ", ") .. "\nClosing now cuts those turns off.")
  end
  print("\nReopen later with ⌘⇧T → " .. A.slug(r.name) .. " → continue conversations.")
  io.write(string.format("Close the %q session now? [y/N] ", v.label or sid)); io.flush()
  local ans = (io.read("*l") or ""):lower():gsub("%s", "")
  if ans == "y" or ans == "yes" then
    local _, err = A.close_session(sid)
    if err then print("close failed: " .. tostring(err)); rex.sleep(3) end
  else
    print("left open")
    rex.sleep(1.5)
  end
end

local function cmd_tab_to_session(a)
  local p = positional(a)
  if not p[3] then error("usage: rex-agents tab-to-session SESSION_ID WINDOW_ID NAME", 0) end
  print(A.encode(A.tab_to_session(p[1], p[2], p[3])))
end

local function cmd_start_pending(a)
  local name = positional(a)[1]
  if not name then error("usage: rex-agents start-pending NAME", 0) end
  for _, o in ipairs(A.start_pending(name)) do
    if o.error then
      print("failed " .. tostring(o.label) .. ": " .. o.error)
    else
      print("started " .. tostring(o.label) .. " → " .. o.cmd:sub(1, 90))
      if o.warning then print("warning: " .. o.warning) end
    end
  end
end

local function ago(t)
  if not t then return "never" end
  local d = os.time() - t
  if d < 120 then return d .. " s ago" end
  if d < 7200 then return math.floor(d / 60) .. " min ago" end
  return math.floor(d / 3600) .. " h ago"
end

local function watcher_line(w)
  if not w then return nil end
  if not w.loaded then return "watcher: not loaded" end
  if not w.pid then return "watcher: loaded, not running" end
  return "watcher: running (pid " .. w.pid .. ")"
end

local function cmd_status(a)
  local st = A.status()
  if flag(a, "--json") then
    local rows = {}
    for _, r in ipairs(st.rows) do
      rows[#rows + 1] = { session = r.session, session_id = r.session_id, window = r.window, label = r.label,
        block_id = r.block_id, kind = r.kind, hub_name = r.hub_name, env_hub = r.env_hub, state = r.state,
        pending = r.state == "restart pending", reason = r.reason }
    end
    print(A.encode({ panes = rows, saved_at = st.saved_at, watcher = st.watcher, warnings = st.warnings }))
    return
  end
  local function cut(s, n) s = tostring(s or ""); return #s > n and (s:sub(1, n - 1) .. "…") or s end
  local fmt = "%-18s %-14s %-12s %-10s " .. (A.config.hub and "%-28s " or "") .. "%s"
  local function row(session, window, label, kind, hub, state)
    if A.config.hub then print(string.format(fmt, session, window, label, kind, hub, state))
    else print(string.format(fmt, session, window, label, kind, state)) end
  end
  row("SESSION", "TAB", "PANE", "KIND", "HUB NAME", "STATE")
  local pending, idle = 0, 0
  for _, r in ipairs(st.rows) do
    row(cut(r.session, 18), cut(r.window, 14), cut(r.label, 12), r.kind, r.hub_name or "-", r.state)
    if r.state == "restart pending" then pending = pending + 1 end
    if r.state == "not running" then idle = idle + 1 end
  end
  print("")
  local foot = { "last save " .. ago(st.saved_at) }
  local w = watcher_line(st.watcher)
  if w then table.insert(foot, 1, w) end
  print(table.concat(foot, " · "))
  if pending > 0 then
    print(pending .. " running agent(s) have no HUB_NAME yet; they get it the next time rex-agents starts them"
      .. " (⌘⇧B after a Rex restart, or park → reopen).")
  end
  if idle > 0 then print(idle .. " pane(s) are idle shells; ⌘⇧B brings them back.") end
  for _, warning in ipairs(st.warnings) do print("warning: " .. warning) end
end

local function cmd_verify(a)
  local against
  for i, x in ipairs(a) do if x == "--against" then against = a[i + 1] end end
  if against == nil and flag(a, "--against") then error("usage: rex-agents verify [--against FILE]", 0) end
  local r = A.verify(against)
  for _, l in ipairs(r.info) do print(l) end
  for _, l in ipairs(r.warnings) do print("warning: " .. l) end
  for _, l in ipairs(r.errors) do print("PROBLEM: " .. l) end
  if #r.errors > 0 then error(#r.errors .. " problem(s)", 0) end
  print("ok")
end

local a = args()
local c = a[1]
if not c or c == "-h" or c == "--help" or c == "help" then
  print(USAGE)
  return
end
local cmds = {
  save = cmd_save,
  revive = cmd_revive,
  ["template-save"] = cmd_template_save,
  ["template-open"] = cmd_template_open,
  park = cmd_park,
  ["template-list"] = function() for _, n in ipairs(A.template_names()) do print(n) end end,
  ["tab-to-session"] = cmd_tab_to_session,
  ["start-pending"] = cmd_start_pending,
  status = cmd_status,
  verify = cmd_verify,
}
local f = cmds[c]
if not f then error("unknown command: " .. c, 0) end
local ok, err = pcall(f, a)
if flag(a, "--pause") then pause_key() end
if not ok then error(err, 0) end
