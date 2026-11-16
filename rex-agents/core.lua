-- rex-agents core: remember what runs in each Rex pane and bring it back.
--
-- Works both from `rex do` scripts (cli.lua, watch.lua) and from init.lua actions.
-- Uses only rex.* calls, io and os: no io.popen / os.execute (Rex forbids them), no
-- rex.sleep / rex.args (missing in init.lua).

local M = {}

local T = "com.superlogical.terminal"
local SHELL_FLAVOR = "com.superlogical.terminal.shell"
local HOME = os.getenv("HOME") or ""

-- ---- paths and settings ----------------------------------------------------------------------

local function env(name, default)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  return v
end

M.paths = {
  state = env("REX_AGENTS_STATE", env("XDG_STATE_HOME", HOME .. "/.local/state") .. "/rex-agents"),
  templates = env("REX_AGENTS_TEMPLATES", HOME .. "/.config/rex/templates"),
  claude_sessions = env("REX_AGENTS_CLAUDE_SESSIONS", HOME .. "/.claude/sessions"),
  config = env("REX_AGENTS_CONFIG", HOME .. "/.config/rex/rex-agents.local.lua"),
}
M.paths.snap = M.paths.state .. "/panes.json"
M.paths.prev = M.paths.state .. "/panes.prev.json"
M.paths.pending = M.paths.state .. "/pending.json"

local REX_APP_BIN = HOME .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS"
M.PATH = table.concat({ HOME .. "/.local/bin", HOME .. "/.amp/bin", HOME .. "/bin", "/opt/homebrew/bin",
  "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", REX_APP_BIN, os.getenv("PATH") or "" }, ":")

-- Defaults; ~/.config/rex/rex-agents.local.lua (a Lua file returning a table) adds to them.
M.config = {
  shells = { "zsh", "-zsh", "bash", "-bash", "sh", "fish", "login" },
  -- programs restarted with the same arguments
  viewers = { "glow", "btop", "htop", "lazygit" },
  -- panes known by label + cwd suffix, restarted with a fixed command:
  --   labelled = { hub = { cwd_suffix = "/app", cmd = { "mix", "run", "--no-halt" } } }
  labelled = {},
  -- service panes known by label. Revive runs `rex do -s SESSION <action>` once per session
  -- with an idle service pane. In templates each label's command is the string given, or
  -- the running program's arguments when the value is `true`.
  services = { labels = {}, action = nil },
  -- seconds a saved pane whose block is gone is kept (server still starting, session hidden)
  keep_missing = 7 * 86400,
}

local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

local function load_local_config()
  local f = io.open(M.paths.config, "r")
  if not f then return end
  f:close()
  local ok, extra = pcall(dofile, M.paths.config)
  if not ok then error("rex-agents config " .. M.paths.config .. ": " .. tostring(extra), 0) end
  if type(extra) ~= "table" then return end
  for _, v in ipairs(extra.viewers or {}) do table.insert(M.config.viewers, v) end
  for _, v in ipairs(extra.shells or {}) do table.insert(M.config.shells, v) end
  for k, v in pairs(extra.labelled or {}) do M.config.labelled[k] = v end
  if extra.services then
    for k, v in pairs(extra.services.labels or {}) do M.config.services.labels[k] = v end
    if extra.services.action then M.config.services.action = extra.services.action end
  end
  if extra.keep_missing then M.config.keep_missing = extra.keep_missing end
end
load_local_config()

local SHELLS = set_of(M.config.shells)
local VIEWERS = set_of(M.config.viewers)
M.SHELLS = SHELLS

-- ---- small helpers ---------------------------------------------------------------------------

local function exec(argv, opts)
  opts = opts or {}
  opts.env = opts.env or {}
  opts.env.PATH = opts.env.PATH or M.PATH
  opts.timeout = opts.timeout or 30
  return rex.exec(argv, opts)
end
M.exec = exec

local function basename(p) return (p:gsub("/+$", ""):match("([^/]+)$")) or p end
M.basename = basename

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function starts_with(s, p) return s:sub(1, #p) == p end
local function ends_with(s, p) return p == "" or s:sub(-#p) == p end

local function split_ws(s)
  local out = {}
  for w in s:gmatch("%S+") do out[#out + 1] = w end
  return out
end

local function slice(t, i, j)
  local out = {}
  for k = i, j or #t do out[#out + 1] = t[k] end
  return out
end

local function concat(a, b)
  local out = {}
  for _, v in ipairs(a) do out[#out + 1] = v end
  for _, v in ipairs(b) do out[#out + 1] = v end
  return out
end

local function list_eq(a, b)
  if a == nil or b == nil then return a == b end
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- POSIX shell quoting, same output as Python's shlex.quote / shlex.join.
function M.quote(s)
  s = tostring(s)
  if s == "" then return "''" end
  if not s:find("[^%w@%%+=:,%./%-_]") then return s end
  return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

function M.join(argv)
  local out = {}
  for i, a in ipairs(argv) do out[i] = M.quote(a) end
  return table.concat(out, " ")
end

-- POSIX shell word splitting (quotes and backslashes), like Python's shlex.split.
function M.split(s)
  local out, cur, have, i, n = {}, {}, false, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "'" then
      local j = s:find("'", i + 1, true)
      if not j then error("unterminated quote in: " .. s, 0) end
      cur[#cur + 1] = s:sub(i + 1, j - 1); have = true; i = j + 1
    elseif c == '"' then
      i = i + 1; have = true
      while i <= n and s:sub(i, i) ~= '"' do
        local d = s:sub(i, i)
        if d == "\\" and i < n and s:sub(i + 1, i + 1):find('[\\"$`\n]') then
          cur[#cur + 1] = s:sub(i + 1, i + 1); i = i + 2
        else
          cur[#cur + 1] = d; i = i + 1
        end
      end
      if i > n then error("unterminated quote in: " .. s, 0) end
      i = i + 1
    elseif c == "\\" and i < n then
      cur[#cur + 1] = s:sub(i + 1, i + 1); have = true; i = i + 2
    elseif c:find("%s") then
      if have then out[#out + 1] = table.concat(cur); cur = {}; have = false end
      i = i + 1
    else
      cur[#cur + 1] = c; have = true; i = i + 1
    end
  end
  if have then out[#out + 1] = table.concat(cur) end
  return out
end

-- Lowercase, runs of anything but a-z0-9 become "-" (template file names).
function M.slug(s)
  local r = tostring(s or ""):lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if r == "" then return "session" end
  return r
end

local function is_default_window_label(label)
  return label == nil or label:match("^Window [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") ~= nil
end
M.is_default_window_label = is_default_window_label

local function home_tilde(p)
  if p and HOME ~= "" and (p == HOME or starts_with(p, HOME .. "/")) then return "~" .. p:sub(#HOME + 1) end
  return p
end

local function expand_home(p)
  if p == "~" then return HOME end
  if p and starts_with(p, "~/") then return HOME .. p:sub(2) end
  return p
end
M.expand_home = expand_home

-- ---- JSON with a stable key order (templates are edited by hand) -----------------------------

local KEY_ORDER = {}
for i, k in ipairs({
  -- top level of panes.json and of a template
  "server", "name", "saved_at", "panes", "windows",
  -- a saved pane
  "kind", "fresh", "revive", "note", "session_id", "session", "window",
  -- a template block (label/cwd are also the next keys of a saved pane), window, split
  "label", "cwd", "cmd", "resume", "hold", "layout", "split", "block", "direction", "ratio", "before", "after",
  -- rest of a saved pane
  "seen", "alive_on",
}) do KEY_ORDER[k] = i end

local ARRAY_KEYS = set_of({ "fresh", "revive", "windows", "argv" })

local function num(x)
  if x == math.floor(x) and math.abs(x) < 2 ^ 53 then return string.format("%d", x) end
  for _, p in ipairs({ 15, 16, 17 }) do
    local s = string.format("%." .. p .. "g", x)
    if tonumber(s) == x then return s end
  end
  return string.format("%.17g", x)
end

local function str(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }
    return m[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if n == 0 then return nil end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local function encode(v, ind, key)
  local tv = type(v)
  if v == nil then return "null" end
  if tv == "boolean" then return v and "true" or "false" end
  if tv == "number" then return num(v) end
  if tv == "string" then return str(v) end
  if tv ~= "table" then error("can't encode " .. tv, 0) end
  local arr = is_array(v)
  if arr == nil then return ARRAY_KEYS[key] and "[]" or "{}" end
  local pad, inner = string.rep("  ", ind), string.rep("  ", ind + 1)
  local parts = {}
  if arr then
    for _, x in ipairs(v) do parts[#parts + 1] = inner .. encode(x, ind + 1, nil) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys, function(a, b)
    local oa, ob = KEY_ORDER[a] or 1000, KEY_ORDER[b] or 1000
    if oa ~= ob then return oa < ob end
    return a < b
  end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = inner .. str(k) .. ": " .. encode(v[k], ind + 1, k)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

function M.encode(v) return encode(v, 0, nil) end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end
M.read_file = read_file

function M.read_json(path)
  local s = read_file(path)
  if not s then return nil end
  local v = rex.json.decode(s)
  return v
end

local function mkdir(dir)
  local r, err = exec({ "mkdir", "-p", "-m", "700", dir })
  if not r then error(err, 0) end
end

-- Write atomically: temp file in the same directory, then rename over the target.
function M.write_json(path, data, mode)
  local dir = path:match("^(.*)/[^/]+$")
  mkdir(dir)
  local tmp = string.format("%s.tmp-%d-%d", path, os.time(), math.random(1, 1e9))
  local f = assert(io.open(tmp, "w"))
  f:write(M.encode(data), "\n")
  f:close()
  if mode then exec({ "chmod", mode, tmp }) end
  local ok, err = os.rename(tmp, path)
  if not ok then os.remove(tmp); error(err, 0) end
end

local function copy_file(src, dst)
  local s = read_file(src)
  if not s then return end
  local tmp = dst .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(s)
  f:close()
  exec({ "chmod", "600", tmp })
  os.rename(tmp, dst)
end

-- ---- Rex -------------------------------------------------------------------------------------

function M.sessions()
  local r, err = rex.call("session.list")
  if not r then error("session.list: " .. tostring(err), 0) end
  return r.sessions or {}
end

-- A `rex do` script may only read or write a session it is attached to (init.lua actions
-- always may). Attach when a call is refused for that reason, then retry once. Attachments
-- last as long as the script.
local function not_attached(err) return err ~= nil and tostring(err):find("not attached", 1, true) ~= nil end

local function attach(sid)
  if not rex.session.attach or not sid then return nil end
  return rex.session.attach{ session_id = sid }
end

function M.raw_view(sid)
  local v, err = rex.session.view{ session_id = sid }
  if v then return v end
  if not_attached(err) then
    local a = attach(sid)
    if a and a.view then return a.view end
  end
  return nil, err
end

-- rex.block.call on a terminal block of session SID, attaching first if needed.
function M.block_call(sid, method, args)
  args.session_id = sid
  local r, err = rex.block.call(T, method, args)
  if r == nil and not_attached(err) and attach(sid) then
    r, err = rex.block.call(T, method, args)
  end
  return r, err
end
local block_call = M.block_call

local function file_url_path(u)
  return (u:gsub("^file://[^/]*", ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function leaf_info(sid, id, labels)
  local info = { block_id = id, label = labels[id] }
  local pw = block_call(sid, "pwd", { block_id = id })
  if pw and pw.pwd then info.cwd = file_url_path(pw.pwd) end
  local pr = block_call(sid, "process", { block_id = id })
  if pr and pr.foreground then
    info.fg = pr.foreground.name
    info.argv0 = pr.foreground.argv0
    info.pid = pr.foreground.pid
    if not info.cwd then info.cwd = pr.foreground.cwd end
  end
  return info
end

local function walk(sid, n, labels)
  if n == nil then return nil end
  if n.block_id then return leaf_info(sid, n.block_id, labels) end
  local s = n.split
  if not s then return nil end
  return { direction = s.direction, ratio = s.ratio, before = walk(sid, s.before, labels), after = walk(sid, s.after, labels) }
end

-- { session_id, label, windows = { { window_id, label, layout } } }, tiled layers only.
function M.view(sid)
  local v = M.raw_view(sid)
  if not v then return nil end
  local ws = {}
  for _, w in ipairs(v.windows or {}) do
    for _, l in ipairs(w.layers or {}) do
      if l.kind == "tiled" then
        local labels = {}
        for _, b in ipairs(l.blocks or {}) do labels[b.block_id] = b.label end
        ws[#ws + 1] = { window_id = w.window_id, label = w.label, layout = walk(v.session_id or sid, l.layout, labels) }
      end
    end
  end
  return { session_id = v.session_id or sid, label = v.label, windows = ws }
end

function M.leaves(node, out)
  out = out or {}
  if not node then return out end
  if node.block_id then
    out[#out + 1] = node
  else
    M.leaves(node.before, out)
    M.leaves(node.after, out)
  end
  return out
end

-- Every session's tiled panes. Reads all foreground programs' argv in one go.
function M.snapshot()
  local out, pids = {}, {}
  for _, s in ipairs(M.sessions()) do
    local v = M.view(s.session_id)
    if v then out[#out + 1] = v end
  end
  M.prefetch_views(out)
  return out
end

-- PID + start time of the server; changes when the server restarts. Same format the Python
-- version wrote ("PID@lstart"), so saved alive_on values keep matching.
function M.server_id()
  local st = rex.call("server.status")
  local pid = st and st.pid
  if not pid then return nil end
  local r = exec({ "ps", "-o", "lstart=", "-p", tostring(pid) })
  if not r or not r.ok then return nil end
  return string.format("%d@%s", pid, trim(r.stdout))
end

-- ---- processes -------------------------------------------------------------------------------

-- Exact argv comes from procargs.js (sysctl KERN_PROCARGS2 through osascript), one call for all
-- the panes of a snapshot. The only environment variable read is Claude Code's relaunch hint; the
-- rest of a process's environment is never read or stored.
local HERE = (debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$")) or "."
local PROCARGS = HERE .. "/procargs.js"
local ENV_WANTED = { "CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS" }
local proc_cache = {}

function M.prefetch(pids, keep)
  if not keep then proc_cache = {} end
  if #pids == 0 then return end
  local argv = { "osascript", "-l", "JavaScript", PROCARGS }
  for _, n in ipairs(ENV_WANTED) do argv[#argv + 1] = "--env"; argv[#argv + 1] = n end
  for _, p in ipairs(pids) do argv[#argv + 1] = tostring(p) end
  local r = exec(argv)
  if not r or not r.ok then return end
  local d = rex.json.decode(r.stdout)
  if type(d) ~= "table" then return end
  for pid, info in pairs(d) do proc_cache[tonumber(pid)] = info end
end

-- Read the argv of every foreground program in these views (from M.view / M.snapshot).
function M.prefetch_views(views)
  local pids = {}
  for _, v in ipairs(views) do
    for _, w in ipairs(v.windows) do
      for _, leaf in ipairs(M.leaves(w.layout)) do
        if leaf.pid and not SHELLS[leaf.fg] then pids[#pids + 1] = leaf.pid end
      end
    end
  end
  M.prefetch(pids)
end

local function procinfo(pid)
  pid = tonumber(pid)
  if proc_cache[pid] == nil then
    M.prefetch({ pid }, true)
    if proc_cache[pid] == nil then proc_cache[pid] = false end
  end
  return proc_cache[pid] or nil
end

-- argv of a process. Falls back to `ps`, which joins arguments with spaces (so a quoted prompt
-- comes back as several words), only when procargs.js can't read the process.
function M.argv(pid)
  local info = procinfo(pid)
  if info and info.argv and #info.argv > 0 then return info.argv end
  local r = exec({ "ps", "-ww", "-o", "args=", "-p", tostring(pid) })
  if not r or not r.ok then return nil end
  local a = split_ws(r.stdout)
  if #a == 0 then return nil end
  return a
end

function M.proc_env(pid, name)
  local info = procinfo(pid)
  return info and info.env and info.env[name] or nil
end

-- ---- Claude Code -----------------------------------------------------------------------------

local C_VALUE = set_of({ "--model", "--permission-mode", "--settings", "--append-system-prompt", "--system-prompt",
  "--agent", "--effort", "--fallback-model", "--setting-sources", "--name", "-n",
  "--permission-prompt-tool", "--output-format", "--input-format", "--debug-file" })
local C_MULTI = set_of({ "--allowed-tools", "--allowedTools", "--disallowed-tools", "--disallowedTools", "--add-dir",
  "--mcp-config", "--plugin-dir", "--tools", "--betas", "--dangerously-load-development-channels", "--channels" })
local C_DROP_VALUE = set_of({ "--resume", "-r", "--session-id", "--from-pr" })
local C_DROP = set_of({ "--continue", "-c", "--fork-session", "-p", "--print" })

-- Launch flags without the conversation selector or a prompt.
function M.claude_flags(args)
  local out, i, n = {}, 1, #args
  while i <= n do
    local a = args[i]
    local key = a:match("^([^=]*)")
    local has_eq = a:find("=", 1, true) ~= nil
    if C_DROP_VALUE[key] then
      if has_eq or i + 1 > n or starts_with(args[i + 1], "-") then i = i + 1 else i = i + 2 end
    elseif C_DROP[key] then
      i = i + 1
    elseif C_VALUE[key] and not has_eq then
      out[#out + 1] = a
      if args[i + 1] then out[#out + 1] = args[i + 1] end
      i = i + 2
    elseif C_MULTI[key] and not has_eq then
      out[#out + 1] = a
      i = i + 1
      while i <= n and not starts_with(args[i], "-") and not args[i]:find("%s") do
        out[#out + 1] = args[i]
        i = i + 1
      end
    else
      if starts_with(a, "-") then out[#out + 1] = a end
      -- anything else is a prompt: drop it
      i = i + 1
    end
  end
  return out
end

function M.claude_session(pid)
  local d = M.read_json(M.paths.claude_sessions .. "/" .. tostring(pid) .. ".json")
  return d
end

local function claude_entry(pid, argv)
  -- set by /restart: the flags the conversation was launched with
  local hint = M.proc_env(pid, "CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS")
  local flags
  if hint ~= nil then
    local ok, v = pcall(M.split, hint)
    flags = ok and v or M.claude_flags(slice(argv, 2))
  else
    flags = M.claude_flags(slice(argv, 2))
  end
  local d = M.claude_session(pid)
  local sid = d and d.sessionId
  local fresh = concat({ "claude" }, flags)
  return { kind = "claude", fresh = fresh, revive = sid and concat(fresh, { "--resume", sid }) or nil,
    note = (not sid) and "no session ID found" or nil }
end

-- ---- Amp -------------------------------------------------------------------------------------

local function amp_thread(pid, argv)
  local r = exec({ "lsof", "-p", tostring(pid), "-Fn" })
  local logs, ids = {}, {}
  if r and r.stdout then
    for line in r.stdout:gmatch("[^\n]+") do
      local path, id = line:match("^n(.*/threads/(T%-[0-9a-f%-]+)%.log)$")
      if path and #id == 38 and not ids[path] then
        ids[path] = id
        logs[#logs + 1] = path
      end
    end
  end
  if #logs == 1 then return ids[logs[1]] end
  if #logs > 1 then
    local st = exec(concat({ "stat", "-f", "%m %N" }, logs))
    local best, best_t = nil, -1
    for line in ((st and st.stdout) or ""):gmatch("[^\n]+") do
      local t, p = line:match("^(%d+) (.*)$")
      if t and ids[p] and tonumber(t) > best_t then best, best_t = ids[p], tonumber(t) end
    end
    return best or ids[logs[#logs]]
  end
  local m = table.concat(argv, " "):match("T%-[0-9a-f%-]+")
  if m and #m == 38 then return m end
  return nil
end

local function has(list, x)
  for _, v in ipairs(list) do if v == x then return true end end
  return false
end

local function amp_entry(pid, argv)
  local rest = slice(argv, 2)
  if has(rest, "--execute") or has(rest, "-x") then
    return nil -- one-shot executions are started by something else
  end
  if has(rest, "--no-tui") then -- long-lived runner: start it again with the same arguments
    local a = concat({ "amp" }, rest)
    return { kind = "amp-runner", fresh = a, revive = a }
  end
  if rest[1] == "orb" and rest[2] == "provider" then
    local a = concat({ "amp" }, rest)
    return { kind = "amp-orb", fresh = a, revive = a }
  end
  local t = amp_thread(pid, argv)
  return { kind = "amp", fresh = { "amp" }, revive = t and { "amp", "threads", "continue", t } or { "amp" },
    note = (not t) and "thread not found, starts a new one" or nil }
end

-- ---- classify a pane -------------------------------------------------------------------------

-- What to retype in this pane, or nil for a shell / an unknown program.
function M.classify(leaf)
  local label, fg, pid = leaf.label, leaf.fg, leaf.pid
  if label and M.config.services.labels[label] ~= nil then
    return { kind = "services" }
  end
  local l = label and M.config.labelled[label]
  if l and ends_with(leaf.cwd or "", l.cwd_suffix or "") then
    -- long-running server known by its pane label (one per machine)
    return { kind = "labelled", fresh = l.cmd, revive = l.cmd }
  end
  if not pid or SHELLS[fg] then return nil end
  local argv = M.argv(pid)
  if not argv then return nil end
  local prog = basename(argv[1])
  if prog == "claude" then return claude_entry(pid, argv) end
  if prog == "amp" then return amp_entry(pid, argv) end
  if VIEWERS[prog] then
    local a = concat({ prog }, slice(argv, 2))
    return { kind = prog, fresh = a, revive = a }
  end
  return nil
end

-- ---- save ------------------------------------------------------------------------------------

function M.load_snap()
  local ok, d = pcall(M.read_json, M.paths.snap)
  if not ok or type(d) ~= "table" then return { panes = {} } end
  d.panes = d.panes or {}
  return d
end

-- Record every pane's program. Returns { panes = N } or { skipped = reason }.
function M.save()
  local old = M.load_snap()
  local server = M.server_id()
  local views = M.snapshot()
  if #views == 0 then
    return { skipped = "no sessions visible yet, kept the previous save" }
  end
  local now = os.time()
  local panes, live, count = {}, {}, 0
  for _, v in ipairs(views) do
    for _, w in ipairs(v.windows) do
      for _, leaf in ipairs(M.leaves(w.layout)) do
        local bid = leaf.block_id
        live[bid] = true
        local e = M.classify(leaf)
        local prev = old.panes[bid]
        if e then
          e.session_id, e.session, e.window = v.session_id, v.label, w.label
          e.label, e.cwd, e.seen, e.alive_on = leaf.label, leaf.cwd, now, server
          panes[bid] = e
        elseif prev then
          -- Forget it only if it ran under THIS server and has since exited: you closed it yourself.
          -- Anything else (server restarted, not revived yet) stays until it is brought back.
          if not (server and prev.alive_on == server) then panes[bid] = prev end
        end
      end
    end
  end
  for bid, prev in pairs(old.panes) do
    -- block not visible right now (server still starting, session hidden): keep it for a while
    if not live[bid] and now - (prev.seen or 0) < M.config.keep_missing then panes[bid] = prev end
  end
  for _ in pairs(panes) do count = count + 1 end
  if read_file(M.paths.snap) then copy_file(M.paths.snap, M.paths.prev) end
  M.write_json(M.paths.snap, { server = server or old.server, saved_at = now, panes = panes }, "600")
  return { panes = count }
end

-- ---- revive ----------------------------------------------------------------------------------

function M.type_into(sid, bid, text)
  local _, err = block_call(sid, "write", { block_id = bid, data = text })
  if err then return nil, err end
  return block_call(sid, "write", { block_id = bid, data = "\r" })
end

-- What revive would do now: { todo = { {bid, sid, entry, line} }, services = { sid... } }.
function M.revive_plan()
  local snap = M.load_snap()
  local live = {}
  for _, v in ipairs(M.snapshot()) do
    for _, w in ipairs(v.windows) do
      for _, leaf in ipairs(M.leaves(w.layout)) do live[leaf.block_id] = { sid = v.session_id, leaf = leaf } end
    end
  end
  local todo, services, seen_sid = {}, {}, {}
  for bid, e in pairs(snap.panes) do
    local l = live[bid]
    if l then
      if e.kind == "services" then
        if SHELLS[l.leaf.fg] and not seen_sid[l.sid] then -- service pane with nothing running
          seen_sid[l.sid] = true
          services[#services + 1] = l.sid
        end
      elseif SHELLS[l.leaf.fg] and e.revive and #e.revive > 0 then
        local line = e.cwd and (" cd " .. M.quote(e.cwd) .. " && " .. M.join(e.revive)) or (" " .. M.join(e.revive))
        todo[#todo + 1] = { bid = bid, sid = l.sid, e = e, line = line }
      end
    end
  end
  table.sort(todo, function(a, b)
    local ka = { a.e.session or "", a.e.window or "", a.bid }
    local kb = { b.e.session or "", b.e.window or "", b.bid }
    for i = 1, 3 do if ka[i] ~= kb[i] then return ka[i] < kb[i] end end
    return false
  end)
  table.sort(services)
  return { todo = todo, services = services }
end

function M.revive_row(t)
  local e = t.e
  return string.format("%-14s %-16s %s%s", (e.session or ""):sub(1, 14), (e.window or ""):sub(1, 16),
    M.join(e.revive):sub(1, 110), e.note and ("  (" .. e.note .. ")") or "")
end

function M.run_services(sid)
  local action = M.config.services.action
  if not action then return nil, "no services action configured" end
  local argv = { "rex", "--autostart=false" }
  local pin = os.getenv("REX_AGENTS_SERVER")
  if pin and pin ~= "" then argv[#argv + 1] = "-S"; argv[#argv + 1] = pin end -- never fall back to another server
  for _, a in ipairs({ "do", "-s", sid, action }) do argv[#argv + 1] = a end
  local r, err = exec(argv, { timeout = 120 })
  if not r then return nil, err end
  return trim(r.stdout ~= "" and r.stdout or r.stderr)
end

-- ---- templates -------------------------------------------------------------------------------

local function tpl_blocks(node, out)
  if not node then return out end
  if node.block then
    if node.block.label then out[node.block.label] = node.block end
  elseif node.split then
    tpl_blocks(node.split.before, out)
    tpl_blocks(node.split.after, out)
  end
  return out
end

local function services_cmd(leaf)
  local v = M.config.services.labels[leaf.label]
  if v == true then
    if not leaf.pid then return nil end
    local argv = M.argv(leaf.pid)
    if not argv then return nil end
    return M.join(concat({ basename(argv[1]) }, slice(argv, 2)))
  end
  if type(v) == "string" then return v end
  return nil
end

local function tpl_node(node, old_blocks)
  if not node then return nil end
  if node.block_id then
    local e = M.classify(node)
    local cmd
    if e and e.kind == "services" then
      cmd = services_cmd(node)
    elseif e and e.fresh then
      cmd = M.join(e.fresh)
    end
    local b = { cwd = home_tilde(node.cwd), cmd = cmd }
    if e and e.revive and e.kind ~= "services" and not list_eq(e.revive, e.fresh) then
      b.resume = M.join(e.revive) -- same conversation; "cmd" starts a new one
    end
    local old = node.label and old_blocks[node.label]
    if old and not b.cmd and old.cmd then -- keep hand-written commands of labelled panes
      b.cmd = old.cmd
      if old.hold then b.hold = true end
    end
    if node.label and node.label ~= "shell" then b.label = node.label end
    return { block = b }
  end
  return { split = { direction = node.direction, ratio = node.ratio or 0.5,
    before = tpl_node(node.before, old_blocks), after = tpl_node(node.after, old_blocks) } }
end

function M.template_path(name) return M.paths.templates .. "/" .. M.slug(name) .. ".json" end

function M.load_template(name)
  local t = M.read_json(M.template_path(name))
  if type(t) ~= "table" then error("template not found: " .. tostring(name), 0) end
  return t
end

function M.template_names()
  local r = exec({ "ls", "-1", M.paths.templates })
  local out = {}
  if r and r.ok then
    for f in r.stdout:gmatch("[^\n]+") do
      if f:match("%.json$") then out[#out + 1] = f:sub(1, -6) end
    end
  end
  table.sort(out)
  return out
end

-- Save a session (or one window of it) as ~/.config/rex/templates/NAME.json.
function M.template_save(sid, name, window_id, v)
  v = v or M.view(sid)
  if not v then error("session " .. tostring(sid) .. " not found", 0) end
  M.prefetch_views({ v })
  local wins = {}
  for _, w in ipairs(v.windows) do
    if w.layout and (window_id == nil or w.window_id == window_id) then wins[#wins + 1] = w end
  end
  if #wins == 0 then
    if window_id then error("window " .. window_id .. " not found", 0) end
    error("session " .. tostring(v.label or sid) .. " has no tiled panes to save", 0)
  end
  if not name or name == "" then
    if window_id == nil then
      name = v.label
    else
      name = wins[1].label or v.label
      if is_default_window_label(name) then
        local cwd
        for _, l in ipairs(M.leaves(wins[1].layout)) do if l.cwd then cwd = l.cwd; break end end
        name = cwd and basename(cwd) or v.label
      end
    end
  end
  local old_blocks = {}
  local okt, old = pcall(M.read_json, M.template_path(name))
  if okt and type(old) == "table" then
    for _, w in ipairs(old.windows or {}) do tpl_blocks(w.layout, old_blocks) end
  end
  local tw = {}
  for _, w in ipairs(wins) do
    local entry = { layout = tpl_node(w.layout, old_blocks) }
    if not is_default_window_label(w.label) then entry.label = w.label end
    tw[#tw + 1] = entry
  end
  local tpl = { name = name, saved_at = os.date("%Y-%m-%d %H:%M"), windows = tw }
  local path = M.template_path(name)
  M.write_json(path, tpl)
  return { saved = home_tilde(path), windows = #tw, name = name }
end

local function rex_layout(node, fresh)
  if node.block then
    local b = node.block
    local opts = {}
    if b.cwd then opts.cwd = expand_home(b.cwd) end
    local cmd
    if fresh then cmd = b.cmd else cmd = b.resume or b.cmd end
    if cmd then opts.initial_input = b.hold and cmd or (cmd .. "\r") end -- hold: typed, not run
    local out = { flavor = SHELL_FLAVOR, options = opts }
    if b.label and b.label ~= "shell" then out.label = b.label end
    return { block = out }
  end
  local s = node.split
  return { split = { direction = s.direction, ratio = s.ratio or 0.5,
    before = rex_layout(s.before, fresh), after = rex_layout(s.after, fresh) } }
end
M.rex_layout = rex_layout

local function has_resume(node)
  if not node then return false end
  if node.block then return node.block.resume ~= nil end
  return node.split ~= nil and (has_resume(node.split.before) or has_resume(node.split.after))
end

function M.template_has_resume(tpl)
  for _, w in ipairs(tpl.windows or {}) do if has_resume(w.layout) then return true end end
  return false
end

function M.session_by_label(label)
  for _, s in ipairs(M.sessions()) do if s.label == label then return s end end
  return nil
end

-- Open a template as a new session. Returns the session.create result, or nil + message.
function M.template_open(name, fresh)
  local tpl = M.load_template(name)
  if M.session_by_label(tpl.name) then
    return nil, string.format("A session named %q is already open; switch to it with ⌘K.", tpl.name)
  end
  local wins = {}
  for _, w in ipairs(tpl.windows or {}) do
    wins[#wins + 1] = { window_label = w.label, layout = rex_layout(w.layout, fresh) }
  end
  local r, err = rex.call("session.create", { label = tpl.name, initial_windows = wins })
  if not r then error("session.create: " .. tostring(err), 0) end
  return r
end

-- Claude conversations in this session that are mid-turn (closing would cut the turn off).
function M.busy_claude(v)
  local busy = {}
  for _, w in ipairs(v.windows) do
    for _, leaf in ipairs(M.leaves(w.layout)) do
      if leaf.pid and not SHELLS[leaf.fg] then
        local argv = M.argv(leaf.pid)
        if argv and basename(argv[1]) == "claude" then
          local d = M.claude_session(leaf.pid)
          if d and d.status == "busy" then busy[#busy + 1] = d.cwd or d.sessionId end
        end
      end
    end
  end
  return busy
end

function M.close_session(sid)
  return rex.call("session.destroy", { session_id = sid })
end

-- ---- tab-to-session / start-pending ----------------------------------------------------------

function M.load_pending()
  local ok, d = pcall(M.read_json, M.paths.pending)
  if ok and type(d) == "table" then return d end
  return {}
end

-- New session NAME with the tab's layout; each pane gets its resume command typed, not run.
function M.tab_to_session(sid, window_id, name)
  local v = M.view(sid)
  local w
  for _, x in ipairs(v and v.windows or {}) do if x.window_id == window_id then w = x end end
  if not w then error(string.format("window %s not found in %s", window_id, sid), 0) end
  local snap = M.load_snap().panes
  local order = {}
  local function build(n)
    if n.block_id then
      local e = snap[n.block_id] or {}
      local cmd = (e.revive and e.kind ~= "services") and M.join(e.revive) or nil
      local opts = { cwd = n.cwd or HOME }
      if cmd then opts.initial_input = cmd end
      local b = { flavor = SHELL_FLAVOR, options = opts }
      if n.label and n.label ~= "shell" then b.label = n.label end
      order[#order + 1] = { old = n.block_id, label = n.label, cmd = cmd }
      return { block = b }
    end
    return { split = { direction = n.direction, ratio = n.ratio or 0.5, before = build(n.before), after = build(n.after) } }
  end
  local layout = build(w.layout)
  local r, err = rex.call("session.create", { label = name, initial_windows = { { window_label = w.label, layout = layout } } })
  if not r then error("session.create: " .. tostring(err), 0) end
  local ids = r.initial_windows[1].block_ids
  for i, o in ipairs(order) do o.new = ids[i] end
  local pend = M.load_pending()
  local keep = {}
  for _, o in ipairs(order) do if o.cmd then keep[#keep + 1] = o end end
  pend[name] = keep
  M.write_json(M.paths.pending, pend, "600")
  return { session = name, session_id = r.session_id, panes = order }
end

function M.start_pending(name)
  local pend = M.load_pending()
  local s = M.session_by_label(name)
  if not s then error("no session named " .. tostring(name), 0) end
  local started, left = {}, {}
  for _, o in ipairs(pend[name] or {}) do
    local _, err = block_call(s.session_id, "write", { block_id = o.new, data = "\r" })
    if err then
      o.error = tostring(err)
      left[#left + 1] = o
    end
    started[#started + 1] = o
  end
  pend[name] = (#left > 0) and left or nil -- keep the ones that failed for another try
  M.write_json(M.paths.pending, pend, "600")
  return started
end

return M
