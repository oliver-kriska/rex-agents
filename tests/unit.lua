-- Unit tests for the pure helpers. Expected values come from the original Python version.
--   rex --autostart=false do tests/unit.lua [templates=DIR out=DIR]
-- With templates=DIR, each DIR/*.json is decoded and re-encoded into out=DIR for a diff.

local here = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$") or "."
package.path = here .. "/../?.lua;" .. package.path
local A = require("rex-agents.core")

local fails, n = 0, 0
local function eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  if #a ~= #b then return false end
  for i = 1, #a do if not eq(a[i], b[i]) then return false end end
  return true
end
local function check(name, got, want)
  n = n + 1
  if not eq(got, want) then
    fails = fails + 1
    print("FAIL " .. name .. "\n  got:  " .. rex.json.encode(got) .. "\n  want: " .. rex.json.encode(want))
  end
end

local flags = {
  { { "--dangerously-load-development-channels", "server:amp-bridge" }, { "--dangerously-load-development-channels", "server:amp-bridge" } },
  { { "--dangerously-load-development-channels", "server:amp-bridge", "--resume", "abc" }, { "--dangerously-load-development-channels", "server:amp-bridge" } },
  { { "--model", "opus", "-c", "fix the bug" }, { "--model", "opus" } },
  { { "--resume", "--model", "x" }, { "--model", "x" } },
  { { "--add-dir", "/a", "/b", "--model=sonnet", "hello there" }, { "--add-dir", "/a", "/b", "--model=sonnet" } },
  { { "-p", "--print", "--session-id", "S", "--allowed-tools", "Bash", "Edit", "-r" }, { "--allowed-tools", "Bash", "Edit" } },
  { { "--permission-mode", "plan", "--from-pr=12", "prompt" }, { "--permission-mode", "plan" } },
}
for i, c in ipairs(flags) do check("claude_flags " .. i, A.claude_flags(c[1]), c[2]) end

local quotes = {
  { "abc", "abc" }, { "a b", "'a b'" }, { "it's", "'it'\"'\"'s'" }, { "", "''" }, { "--x=y", "--x=y" },
  { "~/p", "'~/p'" }, { "a$b", "'a$b'" }, { "ü", "'ü'" }, { "/x/y-z_1.2@3%4+5=6:7,8", "/x/y-z_1.2@3%4+5=6:7,8" },
}
for _, c in ipairs(quotes) do check("quote " .. c[1], A.quote(c[1]), c[2]) end

check("split 1", A.split("--a 'b c' \"d\\\"e\" f\\ g"), { "--a", "b c", "d\"e", "f g" })
check("split 2", A.split(""), {})
check("split 3", A.split("x  y"), { "x", "y" })
check("split/join roundtrip", A.split(A.join({ "a b", "it's", "", "x" })), { "a b", "it's", "", "x" })

for _, c in ipairs({ { "My Project", "my-project" }, { "Shop - main", "shop-main" }, { "  ", "session" },
  { "sample_library", "sample-library" }, { "Čaj Ok", "aj-ok" } }) do
  check("slug " .. c[1], A.slug(c[1]), c[2])
end

check("window label default", A.is_default_window_label("Window 0a1b2c3d"), true)
check("window label custom", A.is_default_window_label("Review Board"), false)
check("window label upper hex", A.is_default_window_label("Window 0A1B2C3D"), false)

for _, r in ipairs({ 0.19999999999999996, 0.30000000000000004, 0.5, 0.75, 0.43000000000000005, 0.3 }) do
  check("ratio " .. r, tonumber(A.encode({ r }):match("%[%s*(.-)%s*%]")), r)
end
check("ratio text", A.encode({ 0.19999999999999996, 0.3, 0.5 }), "[\n  0.19999999999999996,\n  0.3,\n  0.5\n]")
check("int", A.encode({ seen = 1794817275 }), "{\n  \"seen\": 1794817275\n}")
check("empty array key", A.encode({ fresh = {} }), "{\n  \"fresh\": []\n}")
check("empty object", A.encode({ panes = {} }), "{\n  \"panes\": {}\n}")
check("escape", A.encode({ "a\"b\\c\nd\1" }), "[\n  \"a\\\"b\\\\c\\nd\\u0001\"\n]")
check("key order block", A.encode({ hold = true, resume = "r", cmd = "c", cwd = "~", label = "l" }),
  "{\n  \"label\": \"l\",\n  \"cwd\": \"~\",\n  \"cmd\": \"c\",\n  \"resume\": \"r\",\n  \"hold\": true\n}")
check("key order template", A.encode({ windows = { 1 }, saved_at = "s", name = "n" }),
  "{\n  \"name\": \"n\",\n  \"saved_at\": \"s\",\n  \"windows\": [\n    1\n  ]\n}")

-- template layouts translate into session.create layouts
local tpl = { split = { direction = "horizontal", ratio = 0.5,
  before = { block = { label = "mgr", cwd = "~/p", cmd = "claude", resume = "claude --resume X" } },
  after = { block = { label = "hub", cmd = "mix run", hold = true } } } }
local fresh, cont = A.rex_layout(tpl, true), A.rex_layout(tpl, false)
check("layout fresh cmd", fresh.split.before.block.options.initial_input, "claude\r")
check("layout continue cmd", cont.split.before.block.options.initial_input, "claude --resume X\r")
check("layout hold", cont.split.after.block.options.initial_input, "mix run")
check("layout cwd", fresh.split.before.block.options.cwd, os.getenv("HOME") .. "/p")
check("layout label", fresh.split.after.block.label, "hub")
check("has_resume", A.template_has_resume({ windows = { { layout = tpl } } }), true)

-- hub names
local configured_hub = A.config.hub
A.config.hub = false
check("hub disabled prefix", A.hub_prefix({ kind = "claude", hub_name = "mgr" }), "")
check("hub disabled template", A.rex_layout({ block = { cmd = "claude", hub_name = "mgr" } }, true).block.options.initial_input, "claude\r")
A.config.hub = true
check("hub valid", A.hub_valid("worker-demo-2"), true)
check("hub valid upper/dot", A.hub_valid("A.b_c-1"), true)
check("hub invalid start", A.hub_valid("-x"), false)
check("hub invalid char", A.hub_valid("a b"), false)
check("hub invalid long", A.hub_valid(string.rep("a", 65)), false)
check("hub slug", A.hub_slug("Worker Demo 2"), "worker-demo-2")
check("hub slug edges", A.hub_slug("  --Review Board: iOS!! "), "review-board-ios")
check("hub slug long", #A.hub_slug(string.rep("ab ", 40)), 64)
check("hub slug long, cut on a dash", #A.hub_slug(string.rep("abc ", 20)), 63)
local BID = "block:00000000-0000-0000-0000-000000b92a10"
check("hub rule 1 user name", A.hub_pick({ kind = "claude", session = "Demo", label = "shell",
  _name = "demo manager", _name_source = "user" }, BID, {}), "demo-manager")
check("hub rule 1 skips derived", A.hub_pick({ kind = "claude", session = "Demo", label = "shell",
  _name = "rex-agents-e5", _name_source = "derived" }, BID, {}), "demo-claude-b92a10")
check("hub rule 2 label", A.hub_pick({ kind = "amp", session = "Review Board", label = "Review Board iOS" }, BID, {}), "review-board-ios")
check("hub rule 3", A.hub_pick({ kind = "amp-runner", session = "Shop - main", label = "shell" }, BID, {}), "shop-main-amp-runner-b92a10")
check("hub collision → session prefix", A.hub_pick({ kind = "claude", session = "Shop - main", label = "server" }, BID,
  { server = true }), "shop-main-server")
check("hub collision, prefix taken too", A.hub_pick({ kind = "claude", session = "Proj", label = "mgr" }, BID,
  { mgr = true, ["proj-mgr"] = true }), "proj-claude-b92a10")
check("hub rule 3 long session", #A.hub_pick({ kind = "claude", session = string.rep("x", 80) }, BID, {}) <= 64, true)
check("hub prefix", A.hub_prefix({ kind = "claude", hub_name = "mgr" }), "HUB_NAME=mgr ")
check("hub prefix not an agent", A.hub_prefix({ kind = "btop", hub_name = "mgr" }), "")
check("key order hub_name", A.encode({ hub_name = "h", hold = true, cmd = "c", label = "l" }),
  "{\n  \"label\": \"l\",\n  \"cmd\": \"c\",\n  \"hold\": true,\n  \"hub_name\": \"h\"\n}")
local htpl = { split = { direction = "horizontal", ratio = 0.5,
  before = { block = { cmd = "claude", resume = "claude --resume X", hub_name = "mgr" } },
  after = { block = { cmd = "amp", hub_name = "Bad Name!", hold = true } } } }
local hl = A.rex_layout(htpl, false)
check("layout hub resume", hl.split.before.block.options.initial_input, "HUB_NAME=mgr claude --resume X\r")
check("layout hub slugged + hold", hl.split.after.block.options.initial_input, "HUB_NAME=bad-name amp")
check("layout hub renamed", A.rex_layout(htpl, true, function(n) return "p-" .. n end).split.before.block.options.initial_input,
  "HUB_NAME=p-mgr claude\r")
A.config.hub = configured_hub

-- repeated flag groups from Claude Code relaunches are dropped, order kept
check("dedupe flags", A.dedupe_flags({ "--model", "x", "--allowed-tools", "a", "--allowed-tools", "b",
  "--allowed-tools", "a", "--model", "x", "--verbose", "--verbose" }),
  { "--model", "x", "--allowed-tools", "a", "--allowed-tools", "b", "--verbose" })
check("dedupe keeps different values", A.dedupe_flags({ "--add-dir", "/a", "/b", "--add-dir", "/a" }),
  { "--add-dir", "/a", "/b", "--add-dir", "/a" })
check("claude flags dedupe", A.claude_flags({ "--resume", "id", "--model", "m", "--allowed-tools", "t",
  "--model", "m", "--allowed-tools", "t" }), { "--model", "m", "--allowed-tools", "t" })

-- sessions file with junk after the object
check("leading object", A.leading_json_object('{"a":"x}","b":{"c":1}}}\n'), '{"a":"x}","b":{"c":1}}')
check("leading object escaped quote", A.leading_json_object('{"a":"\\"}"}x'), '{"a":"\\"}"}')
check("leading object none", A.leading_json_object("nope"), nil)
local nested = [[{"outer":{"text":"{a} and \"}\\{\"","array":[{"s":"}"}]}}]]
check("leading object nested strings and braces", A.leading_json_object(nested .. "}junk"), nested)
check("labelled argv prefix", A.argv_prefix({ "/bin/hub", "start", "two words", "--debug" }, { "/bin/hub", "start", "two words" }), true)
check("labelled argv words stay whole", A.argv_prefix({ "/bin/hub", "start", "two", "words" }, { "/bin/hub", "start", "two words" }), false)
check("labelled argv argument prefix is not enough", A.argv_prefix({ "hub", "starter" }, { "hub", "start" }), false)
check("labelled bare executable", A.argv_prefix({ "/bin/hub", "start" }, { "hub", "start" }), true)
check("labelled absolute executable", A.argv_prefix({ "/other/hub", "start" }, { "/bin/hub", "start" }), false)
-- names.json: only running agents with a valid name, with their pids
local nd = A.names_doc({
  b1 = { kind = "claude", hub_name = "mgr", session = "S", session_id = "s1" },
  b2 = { kind = "labelled", hub_name = nil },
  b3 = { kind = "amp", hub_name = "amp-x", session = "S", session_id = "s1" },
  b4 = { kind = "claude", hub_name = "idle-one" },
}, { b1 = { 10, 11 }, b2 = { 12 }, b3 = { 13 } }, "inst", 99)
check("names version", nd.version, 1)
check("names b1", { nd.blocks.b1.hub_name, nd.blocks.b1.pids[1], nd.blocks.b1.pids[2] }, { "mgr", 10, 11 })
check("names skips non-agents and not running", { nd.blocks.b2 == nil, nd.blocks.b4 == nil, nd.blocks.b3 ~= nil }, { true, true, true })

-- save: skipped when the server changes during the scan; legacy alive_on ("PID@lstart") still
-- counts as the running server. Uses stubs, a scratch state dir, no Rex calls.
do
  local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/rex-agents-unit.XXXXXX"
  local made = assert(A.exec({ "mktemp", "-d", base }))
  assert(made.ok, "unit temp directory")
  local tmp = made.stdout:gsub("%s+$", "")
  local saved = { snap = A.paths.snap, prev = A.paths.prev, names = A.paths.names, snapshot = A.snapshot, server_id = A.server_id,
    legacy = A.legacy_server_id }
  A.paths.snap, A.paths.prev = tmp .. "/panes.json", tmp .. "/panes.prev.json"
  A.paths.names = tmp .. "/names.json"
  local function idle_view()
    return { { session_id = "s", label = "S", windows = { { label = "W", layout = { block_id = "b1", fg = "zsh" } } } } }
  end
  A.snapshot = idle_view
  A.legacy_server_id = function() return "123@Mon Nov 16" end
  local function setup(alive_on)
    A.write_json(A.paths.snap, { server = alive_on, saved_at = 1, panes = {
      b1 = { kind = "amp", revive = { "amp" }, alive_on = alive_on, seen = os.time() } } })
  end
  local ids
  A.server_id = function() return table.remove(ids, 1) end

  setup("inst-A"); ids = { "inst-A", nil }
  check("save skipped when the server goes away", A.save().skipped ~= nil, true)
  check("previous save kept", A.read_json(A.paths.snap).panes.b1 ~= nil, true)

  setup("inst-A"); ids = { "inst-A", "inst-B" }
  check("save skipped when the server restarts", A.save().skipped ~= nil, true)

  setup("inst-A"); ids = { "inst-A", "inst-A" }
  check("exited under this server is dropped", A.save().panes, 0)

  setup("123@Mon Nov 16"); ids = { "inst-A", "inst-A" }
  check("legacy alive_on of this server is dropped", A.save().panes, 0)

  setup("999@Sun Nov 15"); ids = { "inst-A", "inst-A" }
  check("legacy alive_on of an older server is kept", A.save().panes, 1)

  check("same_server plain", A.same_server("x", "x", {}), true)
  check("same_server other uuid", A.same_server("y", "x", {}), false)
  check("same_server nil", A.same_server(nil, "x", {}), false)

  local labelled = A.config.labelled
  A.config.labelled = { probe = { cmd = { "wrapper" }, running = { socket = tmp .. "/missing.sock" } } }
  check("socket override does not fall back to matching argv", A.labelled_running("probe", { probe = { 123 } }, {}, {}), nil)
  A.config.labelled.probe.running.socket = A.paths.snap
  check("existing regular file is not a running socket", A.labelled_running("probe"), nil)
  A.config.labelled = labelled

  A.paths.snap, A.paths.prev = saved.snap, saved.prev
  A.paths.names = saved.names
  A.snapshot, A.server_id, A.legacy_server_id = saved.snapshot, saved.server_id, saved.legacy
  A.exec({ "rm", "-rf", tmp })
end

-- restart notice: only after a real server change, once per server instance
check("notice after a restart", A.restart_notice_due("inst-A", "inst-B", nil), true)
check("notice: watcher restart only", A.restart_notice_due("inst-B", "inst-B", nil), false)
check("notice: already sent for this server", A.restart_notice_due("inst-A", "inst-B", { server = "inst-B" }), false)
check("notice: sent for an older server", A.restart_notice_due("inst-A", "inst-B", { server = "inst-A" }), true)
check("notice: no earlier save", A.restart_notice_due(nil, "inst-B", nil), false)
check("notice: server not answering", A.restart_notice_due("inst-A", nil, nil), false)
check("notice text", A.restart_message(3), "3 panes can be brought back — press ⌘⇧B")
check("notice text one", A.restart_message(1), "1 pane can be brought back — press ⌘⇧B")

-- re-encode real templates for a byte diff against the originals
if rex.args.templates then
  local r = A.exec({ "ls", "-1", rex.args.templates })
  for f in r.stdout:gmatch("[^\n]+") do
    if f:match("%.json$") then
      local t = A.read_json(rex.args.templates .. "/" .. f)
      local out = assert(io.open(rex.args.out .. "/" .. f, "w"))
      out:write(A.encode(t))
      out:close()
    end
  end
end

print(string.format("%d/%d passed", n - fails, n))
if fails > 0 then rex.stop(1) end
