-- rex-agents watcher: keeps panes.json current. Run it with
--
--   rex --autostart=false do ~/.config/rex/rex-agents/watch.lua --all
--
-- (the LaunchAgent com.rex-agents.watch that `rex-agents setup` writes does that, and launchd restarts it
-- whenever the Rex server restarts).
-- It saves once at start, every INTERVAL seconds, and SOON seconds after a pane starts a
-- program, so a freshly started agent is on disk before the next server restart.
-- After a server restart, the first save under the new server is followed by one notification
-- ("N panes can be brought back — press ⌘⇧B"); it never types into panes.

local here = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path
local A = require("rex-agents.core")

local INTERVAL = tonumber(rex.args.interval) or 120
local SOON = tonumber(rex.args.soon) or 20

-- The server of the last save before this watcher's own: a different one means the Rex server
-- restarted (launchd starts the watcher again when its connection drops).
local prev_server = A.load_snap().server
local notice_done = false

local function restart_notice()
  local ok, r = pcall(A.restart_notice, prev_server)
  if ok and not r then return end -- no save under this server yet; try after the next one
  notice_done = true
  print(os.date("%Y-%m-%d %H:%M:%S") .. " restart notice: " .. (ok and r.why or ("failed: " .. tostring(r))))
end

local last
local function save(why)
  A.reload_config()
  local ok, r = pcall(A.save)
  local stamp = os.date("%Y-%m-%d %H:%M:%S")
  if not ok then
    print(stamp .. " save failed (" .. why .. "): " .. tostring(r))
  elseif r.skipped then
    print(stamp .. " " .. r.skipped)
  elseif r.panes ~= last or why == "start" then
    print(string.format("%s saved %d panes (%s)", stamp, r.panes, why))
  end
  if ok and r.panes then last = r.panes end
  if ok and r.panes and not notice_done then restart_notice() end
  io.flush()
end

local pending
local function soon()
  if pending and pending:active() then return end
  pending = rex.after(SOON, function() save("change") end)
end

-- An agent started by hand (typed in a pane, not launched by rex-agents) gets its pane's name
-- in names.json right away: chief's client waits only 12 s for it, less than SOON. rex-agents'
-- own launches publish the same way. Only the new agent's block is read, not every session.
local published = {} -- block id -> agent PID published from here
-- Servers preview.20/.21 pass the location (session_id, block_id) first and the event fields
-- (foreground, plus the location again) second, the reverse of the documented (ev, ctx); read both.
local function publish_hand_start(a, b)
  a, b = a or {}, b or {}
  local fg = b.foreground or a.foreground
  local sid, bid = a.session_id or b.session_id, a.block_id or b.block_id
  if not (fg and fg.pid and sid and bid) then return end
  if not (A.agent_program(fg.name) or A.agent_program(fg.argv0)) then return end
  if published[bid] == fg.pid then return end
  A.reload_config()
  if not A.config.hub then return end
  local ok, err = pcall(A.publish_started, sid, bid, nil, 3)
  if ok and not err then
    published[bid] = fg.pid
    print(os.date("%Y-%m-%d %H:%M:%S") .. " published " .. bid .. " (agent started)")
  else
    print(os.date("%Y-%m-%d %H:%M:%S") .. " publish " .. bid .. " skipped: " .. tostring(err))
  end
  io.flush()
end

-- A program starting or exiting in a pane changes its foreground process; new panes and
-- sessions also count. Bursts collapse into one save SOON seconds after the first event.
rex.on("terminal.process_changed", function(a, b)
  soon()
  publish_hand_start(a, b)
end)
rex.on("block_created", soon)
rex.on("session_created", soon)

save("start")
rex.every(INTERVAL, function() save("timer") end)
