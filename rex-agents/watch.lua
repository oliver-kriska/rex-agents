-- rex-agents watcher: keeps panes.json current. Run it with
--
--   rex --autostart=false do ~/.config/rex/rex-agents/watch.lua --all
--
-- (the LaunchAgent com.rex-agents.watch that install.sh writes does that, and launchd restarts it
-- whenever the Rex server restarts).
-- It saves once at start, every INTERVAL seconds, and SOON seconds after a pane starts a
-- program, so a freshly started agent is on disk before the next server restart.

local here = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path
local A = require("rex-agents.core")

local INTERVAL = tonumber(rex.args.interval) or 120
local SOON = tonumber(rex.args.soon) or 20

local last
local function save(why)
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
  io.flush()
end

local pending
local function soon()
  if pending and pending:active() then return end
  pending = rex.after(SOON, function() save("change") end)
end

-- A program starting or exiting in a pane changes its foreground process; new panes and
-- sessions also count. Bursts collapse into one save SOON seconds after the first event.
rex.on("terminal.process_changed", soon)
rex.on("block_created", soon)
rex.on("session_created", soon)

save("start")
rex.every(INTERVAL, function() save("timer") end)
