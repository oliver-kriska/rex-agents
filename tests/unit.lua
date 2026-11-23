-- Unit tests for the pure helpers. Expected values come from the original Python version.
--   rex --autostart=false do tests/unit.lua [templates=DIR out=DIR]
-- With templates=DIR, each DIR/*.json is decoded and re-encoded into out=DIR for a diff.

local here = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$") or "."
package.path = here .. "/../?.lua;" .. package.path
local A = require("rex-agents.core")

-- Rex can retain a stale scalar upvalue after a caught error; keep the shared counters in a table.
local results = { fails = 0, n = 0 }
local function eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  if #a ~= #b then return false end
  for i = 1, #a do if not eq(a[i], b[i]) then return false end end
  return true
end
local function check(name, got, want)
  results.n = results.n + 1
  if not eq(got, want) then
    results.fails = results.fails + 1
    print("FAIL " .. name .. "\n  got:  " .. rex.json.encode(got) .. "\n  want: " .. rex.json.encode(want))
  end
end

-- Reload from a private file; classification and subprocess env requests must follow it.
do
  local tmp = assert(A.exec({ "mktemp", "-d" })).stdout:gsub("%s+$", "")
  local path, snap, real_exec, real_print = A.paths.config, A.paths.snap, rex.exec, print
  A.paths.config, A.paths.snap = tmp .. "/config.lua", tmp .. "/panes.json"
  local logs, wanted = {}, {}
  _G.print = function(message)
    if tostring(message):find("keeping last good config", 1, true) then logs[#logs + 1] = message else real_print(message) end
  end
  rex.exec = function(argv, opts)
    if argv[1] ~= "osascript" then return real_exec(argv, opts) end
    wanted = {}
    for i, word in ipairs(argv) do if word == "--env" then wanted[#wanted + 1] = argv[i + 1] end end
    return { ok = true, stdout = '{"42":{"argv":["btop"],"env":{"HUB_NAME":"worker"}}}' }
  end
  local function reload(text)
    local f = assert(io.open(A.paths.config, "w")); f:write(text); f:close()
    return A.reload_config()
  end
  local first = 'return {hub=true, viewers={"btop"}, shells={"custom-shell"}, labelled={worker={cwd_suffix="/old",cmd={"worker"}}}}'
  reload(first)
  check("reload classifies original labelled cwd", A.classify({ label = "worker", cwd = "/old" }).kind, "labelled")
  local shell_set = A.SHELLS
  check("reload rebuilds shell classification", A.classify({ fg = "custom-shell", pid = 42 }), nil)
  check("reload rebuilds viewers", A.classify({ fg = "btop", pid = 42 }).kind, "btop")
  check("hub reload requests environment", wanted, { "CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS", "HUB_NAME" })
  check("unchanged config is not rebuilt", A.reload_config(), false)
  local second = first:gsub("hub=true", "hub=false"):gsub('"/old"', '"/new"')
  reload(second)
  reload(second .. "\n-- another edit")
  check("reload does not accumulate viewers or shells", { #A.config.viewers, #A.config.shells }, { 1, 8 })
  check("reload keeps exported shell set current", { A.SHELLS == shell_set, shell_set["custom-shell"] }, { true, true })
  check("old labelled cwd stops matching", A.classify({ label = "worker", cwd = "/old" }), nil)
  check("new labelled cwd matches", A.classify({ label = "worker", cwd = "/new" }).kind, "labelled")
  A.prefetch({ 42 }, true)
  check("hub opt-out removes env request", wanted, { "CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS" })
  for _, bad in ipairs({ 'return {', 'return {viewers={"other"}, resume_prompt=17}' }) do
    local changed, warning = reload(bad)
    check("invalid reload retains last good config", { changed, warning ~= nil, A.config.viewers[1] }, { false, true, "btop" })
    A.reload_config()
    reload(second)
    reload(bad)
  end
  check("warn once per distinct bad text", #logs, 2)
  local saved = {}
  for _, key in ipairs({ "snapshot", "labelled_processes", "watcher", "load_snap", "labelled_warnings" }) do saved[key] = A[key] end
  A.snapshot, A.labelled_processes, A.labelled_warnings = function() return {} end, function() return {}, {} end, function() return {} end
  A.watcher = function() end
  A.load_snap = function() return { panes = {} } end
  check("status exposes reload warning", A.status().warnings[1], A.config_warning)
  check("verify exposes reload warning", A.verify().warnings[1], A.config_warning)
  for key, value in pairs(saved) do A[key] = value end
  os.remove(A.paths.config)
  check("config deletion restores defaults", A.reload_config(), true)
  check("deletion clears additions and warning", { #A.config.viewers, #A.config.shells, A.config_warning == nil, shell_set["custom-shell"] == nil },
    { 0, 7, true, true })
  check("removed viewer no longer classifies", A.classify({ fg = "btop", pid = 42 }), nil)
  rex.exec, _G.print = real_exec, real_print
  A.paths.config, A.paths.snap = path, snap
  A.reload_config()
  A.exec({ "rm", "-rf", tmp })
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

do
  local hub, prompt = A.config.hub, A.config.resume_prompt
  local text = "Check the team's inbox; $(echo unsafe)"
  local id = "11111111-2222-3333-4444-555555555555"
  local entry = { kind = "claude", hub_name = "worker" }
  local argv = { "claude", "--model", "sonnet", "--resume", id }
  A.config.hub, A.config.resume_prompt = true, text
  check("resume prompt is one literal argument", A.split(A.join(A.resume_argv(entry, argv))),
    { "claude", "--model", "sonnet", "--resume", id, "--", text })
  check("saved launch flags drop the injected prompt", A.claude_flags({ "--model", "sonnet", "--resume", id, "--", text }),
    { "--model", "sonnet" })
  check("dash-prefixed prompt cannot become a saved flag", A.claude_flags({ "--resume", id, "--", "--version" }), {})
  check("fresh Claude gets no prompt", A.resume_argv(entry, { "claude", "--model", "sonnet" }), { "claude", "--model", "sonnet" })
  check("Amp gets no prompt", A.resume_argv({ kind = "amp", hub_name = "worker" }, argv), argv)
  check("invalid hub name gets no prompt", A.resume_argv({ kind = "claude", hub_name = "bad name" }, argv), argv)
  check("invalid conversation gets no prompt", A.resume_argv(entry, { "claude", "--resume", "--model" }), { "claude", "--resume", "--model" })
  A.config.hub = false
  check("hub disabled gets no prompt", A.resume_argv(entry, argv), argv)
  A.config.hub, A.config.resume_prompt = true, nil
  check("prompt defaults off", A.resume_argv(entry, argv), argv)
  A.config.hub, A.config.resume_prompt = hub, prompt
end

do
  local function entry(pids, at)
    return { kind = "claude", hub_name = "worker", pids = pids, published_at = at }
  end
  local scanned = { server = "s", blocks = { same = entry({ 10, 11 }), replaced = entry({ 20 }), old = entry({ 30 }) } }
  local current = { server = "s", blocks = {
    same = entry({ 10, 12 }, 100), replaced = entry({ 21 }, 101), old = entry({ 31 }, 99),
    unseen = entry({ 40 }, 102), closed = entry({ 50 }, 102),
  } }
  local merged = A.merge_names(scanned, current, 100, { same = true, replaced = true, old = true, unseen = true })
  check("same-second publication wins and unions same agent PIDs", merged.blocks.same.pids, { 10, 12, 11 })
  check("replacement never inherits old PID", merged.blocks.replaced.pids, { 21 })
  check("older publication loses to scan", merged.blocks.old.pids, { 30 })
  check("new unseen live block survives", merged.blocks.unseen.pids, { 40 })
  check("closed publication is dropped", merged.blocks.closed, nil)
  local next_scan = A.merge_names({ server = "s", blocks = { same = entry({ 10, 12 }) } }, merged, 103, { same = true })
  check("publication watermark survives intervening saves", next_scan.blocks.same.published_at, 100)
  local other = A.merge_names({ server = "other", blocks = {} }, current, 100, { unseen = true })
  check("other server publication is ignored", other.blocks.unseen, nil)
end

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
local configured_hub, configured_hub_env = A.config.hub, A.config.hub_env
A.config.hub = false
check("hub disabled prefix", A.hub_prefix({ kind = "claude", hub_name = "mgr" }), "")
check("hub disabled template", A.rex_layout({ block = { cmd = "claude", hub_name = "mgr" } }, true).block.options.initial_input, "claude\r")
-- Classify one-shot Amp invocations before considering runner mode.
local original_argv = A.argv
for _, arg in ipairs({ "-x", "--execute", "--execute=one shot", "--execute=" }) do
  A.argv = function() return { "amp", "--no-tui", arg, "prompt" } end
  check("skip Amp one-shot " .. arg, A.classify({ fg = "amp", pid = 1 }), nil)
end
A.argv = function() return { "amp", "--no-tui", "--execute-other=value" } end
check("unrelated flag does not exclude runner", A.classify({ fg = "amp", pid = 1 }).kind, "amp-runner")
A.argv = original_argv
A.config.hub = true
A.config.hub_env = false
check("hub prefix defaults off", A.hub_prefix({ kind = "claude", hub_name = "mgr" }), "")
check("template prefix defaults off", A.rex_layout({ block = { cmd = "amp", hub_name = "mgr" } }, true).block.options.initial_input, "amp\r")
A.config.hub_env = true
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
check("layout hub renamed", A.rex_layout(htpl, true, function(name) return "p-" .. name end).split.before.block.options.initial_input,
  "HUB_NAME=p-mgr claude\r")
A.config.hub, A.config.hub_env = configured_hub, configured_hub_env

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

-- Names without an environment prefix must survive launches and identify the live process.
do
  local saved = {}
  for k, v in pairs(A) do saved[k] = v end
  local tmp = assert(A.exec({ "mktemp", "-d" })).stdout:gsub("%s+$", "")
  A.paths = { state = tmp, snap = tmp .. "/panes.json", names = tmp .. "/names.json", prev = tmp .. "/prev.json",
    templates = tmp, last_template = tmp .. "/last.json" }
  A.config = { hub = true, hub_env = false, labelled = {}, services = { labels = {} }, keep_missing = 100 }
  local leaf = { block_id = "b", label = "worker", fg = "amp", pid = 42, cwd = "/tmp/project" }
  local view = { session_id = "s", label = "Project", windows = { { label = "Work", layout = leaf } } }
  local entry = { kind = "amp", revive = { "amp" }, hub_name = "saved-worker", session = "Project", window = "Work" }
  local function snapshot()
    A.write_json(A.paths.snap, { server = "instance", saved_at = os.time(), panes = { b = entry } }, "600")
  end
  snapshot()
  A.snapshot = function() return { view } end
  A.server_id = function() return "instance" end
  A.live_block_ids = function() return { b = true } end
  A.labelled_processes = function() return {}, {} end
  A.labelled_warnings = function() return {} end
  A.watcher = function() end
  A.prefetch_views = function() end
  local env
  A.classify = function()
    return { kind = "amp", revive = { "amp" }, _pids = { 42, 43 }, _env_hub = env }
  end
  A.pane_state = function() return "busy" end
  local function published(name, pids)
    A.write_json(A.paths.names, { version = 1, blocks = { b = { hub_name = name, pids = pids } } }, "600")
  end
  for _, case in ipairs({
    { "missing", nil, {}, "not published" },
    { "wrong pid", "saved-worker", { 99 }, "published for another process" },
    { "wrong name", "other", { 42 }, "published as other" },
    { "foreground", "saved-worker", { 42 }, "ok" },
    { "relaunched child", "saved-worker", { 43 }, "ok" },
  }) do
    if case[2] then published(case[2], case[3]) else os.remove(A.paths.names) end
    check("status publication " .. case[1], A.status().rows[1].state, case[4])
    local warnings = A.verify().warnings
    check("verify publication " .. case[1], case[4] == "ok" and #warnings == 0
      or case[4] ~= "ok" and (warnings[1] or ""):find(case[4], 1, true) ~= nil, true)
  end
  os.remove(A.paths.names)
  env = "saved-worker"
  check("legacy env still works without map", A.status().rows[1].state, "ok")
  env = "from-env"
  check("legacy env mismatch still reported", A.status().rows[1].state, "runs as from-env")
  A.save()
  check("rule zero keeps running env name", A.load_snap().panes.b.hub_name, "from-env")
  env = nil
  snapshot()
  A.pane_state = function() return "idle" end
  leaf.fg = "zsh"
  local typed = {}
  A.type_into = function(_, _, text) typed[#typed + 1] = text; return true end
  A.publish_started = function() end
  for _, enabled in ipairs({ false, true }) do
    A.config.hub_env = enabled
    typed = {}
    local plan = A.revive_plan()
    local prefix = enabled and "HUB_NAME=saved-worker " or ""
    check("revive line hub_env=" .. tostring(enabled), plan.todo[1].line, " " .. prefix .. "amp")
    A.revive(plan, { b = true }, function() end)
    check("start command text hub_env=" .. tostring(enabled), typed, { " " .. prefix .. "amp" })
  end
  A.pane_state = function() return "busy" end
  check("opt-in missing env stays pending", A.status().rows[1].state, "restart pending")
  local pending_warnings = {}
  for _, w in ipairs(A.verify().warnings) do
    if w:find("restart pending", 1, true) then pending_warnings[#pending_warnings + 1] = w end
  end
  check("opt-in pending is not a verify warning", pending_warnings, {})
  A.config.hub = false
  check("disabled hub ignores opt-in", A.hub_prefix(entry), "")
  A.exec({ "rm", "-rf", tmp })
  for k in pairs(A) do A[k] = nil end
  for k, v in pairs(saved) do A[k] = v end
end

-- save: skipped when the server changes during the scan; legacy alive_on ("PID@lstart") still
-- counts as the running server. Uses stubs, a scratch state dir, no Rex calls.
do
  local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/rex-agents-unit.XXXXXX"
  local made = assert(A.exec({ "mktemp", "-d", base }))
  assert(made.ok, "unit temp directory")
  local tmp = made.stdout:gsub("%s+$", "")
  local saved = { snap = A.paths.snap, prev = A.paths.prev, names = A.paths.names, snapshot = A.snapshot, server_id = A.server_id,
    legacy = A.legacy_server_id, watcher = A.watcher, state = A.paths.state }
  A.paths.state = tmp
  A.paths.snap, A.paths.prev = tmp .. "/panes.json", tmp .. "/panes.prev.json"
  A.paths.names = tmp .. "/names.json"
  A.watcher = function() return { label = "test", loaded = true, pid = 123 } end
  local first = A.verify()
  check("verify before first save is informational", { #first.errors, table.concat(first.info, "\n"):find("no save yet", 1, true) ~= nil }, { 0, true })
  check("verify against requires current snapshot", #A.verify(tmp .. "/previous.json").errors > 0, true)
  A.watcher = function() return { label = "test", loaded = false } end
  check("missing snapshot must not hide missing watcher", A.verify().errors[1], "watcher test is not loaded (run rex-agents setup)")
  A.watcher = function() return { label = "test", loaded = true } end
  check("missing snapshot must not hide stopped watcher", #A.verify().errors, 1)
  A.watcher = function() return nil end
  local broken = assert(io.open(A.paths.snap, "w")); broken:write("{broken"); broken:close()
  check("corrupt snapshot is still a problem", #A.verify().errors, 1)
  A.write_json(A.paths.snap, {})
  check("snapshot without panes is still a problem", #A.verify().errors, 1)
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
  A.paths.state = saved.state
  A.snapshot, A.server_id, A.legacy_server_id = saved.snapshot, saved.server_id, saved.legacy
  A.watcher = saved.watcher
  A.exec({ "rm", "-rf", tmp })
end

-- Selection is an allowlist, never an implicit "all"; order is independent of picker order.
do
  local plan = { todo = {
    { bid = "a", sid = "s", e = { session = "App", window = "Code", label = "worker", kind = "claude", cwd = os.getenv("HOME") .. "/app" },
      argv = { "claude" }, line = "claude" },
    { bid = "l", sid = "s", e = { session = "App", window = "Tools", kind = "labelled" },
      argv = { "db" }, line = "db", labelled = "db" },
    { bid = "b", sid = "s", e = { kind = "amp" }, argv = { "amp" }, line = "amp" },
  }, services = { "s", "other" }, service_entries = { s = { session = "App", cwd = "/tmp/app" } } }
  local items = A.revive_items(plan)
  check("native agent row", { items[1].id, items[1].title, items[1].subtitle, items[1].detail, items[1].selected },
    { "a", "App › worker", "~/app", "claude", true })
  check("native service group", { items[4].id, items[4].title, items[4].detail },
    { "services:s", "App › services (whole session)", "service" })
  local start, services, calls = A.start_command, A.run_services, {}
  A.start_command = function(_, bid) calls[#calls + 1] = bid; return true end
  A.run_services = function(sid) calls[#calls + 1] = "services:" .. sid; return "ok" end
  A.revive(plan, A.revive_selection(plan, "a,services:s,l,unknown"), function() end)
  check("only selected programs in dependency order", calls, { "l", "services:s", "a" })
  calls = {}
  A.revive(plan, A.revive_selection(plan, ""), function() end)
  check("empty only does nothing", calls, {})
  A.revive(plan, A.revive_selection(plan, "unknown"), function() end)
  check("unknown only does nothing", calls, {})
  A.start_command, A.run_services = start, services
  check("agent command with env", A.agent_command("HUB_NAME=worker /tmp/bin/claude --model sonnet"), true)
  check("viewer is not an agent command", A.agent_command("tail claude"), false)
  check("agent program by path", A.agent_program("/Users/x/.amp/bin/amp"), true)
  check("agent program by name", A.agent_program("claude"), true)
  check("other program is not an agent", A.agent_program("zsh"), false)
  check("missing program is not an agent", A.agent_program(nil), false)
end

-- Exercise the registered actions, not just a reason classifier. A cancelled prompt must
-- neither spawn a fallback terminal nor execute the confirmed action.
do
  local saved, original = {}, {}
  for k, v in pairs(A) do saved[k] = v end
  for k, v in pairs(rex) do original[k] = v end
  local actions, panes, writes, closed, asked, saves = {}, {}, {}, 0, {}, 0
  rex.action = function(action) actions[action.name] = action.run end
  rex.bind = function() end
  rex.session = { new_layer = function(spec) panes[#panes + 1] = spec.layout.block.options.command; return {} end }
  A.save = function() saves = saves + 1 end
  A.revive_plan = function() return { todo = { { bid = "b", e = { kind = "amp" } } }, services = {} } end
  A.template_names = function() return { "demo", "other" } end
  A.view = function() return { label = "Demo", windows = { { window_id = "w", label = "Work" } } } end
  A.template_save = function(_, name) writes[#writes + 1] = name or "Demo"; return { saved = "demo.json", windows = 1, name = name or "Demo" } end
  A.busy_claude = function() return {} end
  A.close_session = function() closed = closed + 1; return {} end
  require("rex-agents.actions"){ bin = "/test/rex-agents" }
  local ctx = { session_id = "s", window_id = "w" }
  for _, reason in ipairs({ "missing", "unsupported", "no_client", "busy", "failed", "cancelled", "timeout" }) do
    local function reject() return nil, reason, "test detail" end
    rex.ui = reason ~= "missing" and { pick = reject, input = reject } or nil
    panes, writes = {}, {}
    actions.revive_agents(ctx)
    actions.open_project(ctx)
    actions.park_session(ctx)
    actions.save_session_template(ctx, {})
    local cancelled = reason == "cancelled" or reason == "timeout"
    check("fallback terminal count: " .. reason, #panes, cancelled and 0 or 3)
    -- Without rex.ui, park goes straight to the floating CLI (which saves there), as in v0.1.
    local expected = (cancelled or reason == "missing") and 1 or 2
    check("cancelled park still saved; cancelled input did not: " .. reason, #writes, expected)
    check("fallback/cancel never closes", closed, 0)
  end
  local answers = { {} }
  local function answer(fields) asked[#asked + 1] = fields; return table.remove(answers, 1) end
  rex.ui = { pick = answer, input = answer }
  panes = {}
  actions.revive_agents(ctx)
  check("confirmed empty native selection", #panes, 0)
  answers = { { "b" } }
  actions.revive_agents(ctx)
  check("native selection runs noninteractive CLI", panes[1], { "/test/rex-agents", "revive", "--only", "b", "--linger" })
  check("native revive never waits for a full save", saves, 0)
  answers = { "demo", "fresh" }
  actions.open_project(ctx)
  check("fresh mode passed to CLI", panes[2], { "/test/rex-agents", "template-open", "demo", "--linger", "--fresh" })
  answers = { "close" }
  actions.park_session(ctx)
  check("confirmed park closes", closed, 1)
  answers, asked, writes = { "My tab" }, {}, {}
  actions.save_tab_template(ctx, {})
  check("input prefilled from tab", asked[1].value, "Work")
  check("input names template", writes, { "My tab" })
  actions.save_session_template(ctx, { name = "explicit" })
  check("explicit name bypasses prompt", #asked, 1)

  -- Keep the real template writer: assert the saved file, not just a call argument.
  local tmp = assert(A.exec({ "mktemp", "-d" })).stdout:gsub("%s+$", "")
  local templates = A.paths.templates
  A.paths.templates = tmp
  A.template_save = saved.template_save
  A.prefetch_views = function() end
  A.load_snap = function() return { panes = {} } end
  A.live_hub_names = function() return {} end
  local function view(label, cwd)
    return { label = "Demo", windows = { { window_id = "w", label = label,
      layout = { block_id = "b", cwd = cwd, fg = "zsh" } } } }
  end
  local current
  A.view = function() return current end
  for _, action in ipairs({ "save_session_template", "save_tab_template" }) do
    current = view("Before", "/before")
    rex.ui.input = function()
      current = view("After", "/after")
      return action
    end
    actions[action](ctx, {})
    local written = A.read_json(A.template_path(action))
    check(action .. " saves the post-prompt view", { written.windows[1].label, written.windows[1].layout.block.cwd }, { "After", "/after" })
  end
  for _, gone in ipairs({ "session", "tab" }) do
    current = view("Before", "/before")
    rex.ui.input = function()
      current = gone == "tab" and { label = "Demo", windows = {} } or nil
      return "gone-" .. gone
    end
    local ok, err = pcall(actions[gone == "tab" and "save_tab_template" or "save_session_template"], ctx, {})
    check("closed " .. gone .. " reports not found", { ok, tostring(err):find("not found", 1, true) ~= nil }, { false, true })
    check("closed " .. gone .. " writes no stale template", A.read_file(A.template_path("gone-" .. gone)), nil)
  end
  A.paths.templates = templates
  A.exec({ "rm", "-rf", tmp })
  for k in pairs(A) do A[k] = nil end
  for k, v in pairs(saved) do A[k] = v end
  for k in pairs(rex) do rex[k] = nil end
  for k, v in pairs(original) do rex[k] = v end
end

do
  local tmp = assert(A.exec({ "mktemp", "-d" })).stdout:gsub("%s+$", "")
  local templates, last = A.paths.templates, A.paths.last_template
  A.paths.templates, A.paths.last_template = tmp .. "/templates", tmp .. "/last.json"
  for _, name in ipairs({ "alpha", "beta", "gamma" }) do A.write_json(A.template_path(name), {}) end
  A.write_json(A.paths.last_template, { name = "beta" }, "600")
  check("last-used first, remainder alphabetical", A.template_names(), { "beta", "alpha", "gamma" })
  A.write_json(A.paths.last_template, { name = "deleted" }, "600")
  check("deleted last-used ignored", A.template_names(), { "alpha", "beta", "gamma" })
  A.paths.templates, A.paths.last_template = templates, last
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

print(string.format("%d/%d passed", results.n - results.fails, results.n))
if results.fails > 0 then rex.stop(1) end
