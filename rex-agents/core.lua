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
M.paths.names = M.paths.state .. "/names.json"
M.paths.notified = M.paths.state .. "/notified.json"

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
  -- after a server restart, one macOS notification saying how many panes revive can bring back
  notify = true,
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
  if extra.notify ~= nil then M.config.notify = extra.notify end
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
  "version", "server", "name", "saved_at", "panes", "windows", "blocks",
  -- a saved pane
  "kind", "fresh", "revive", "note", "session_id", "session", "window",
  -- a template block (label/cwd are also the next keys of a saved pane), window, split
  "label", "cwd", "cmd", "resume", "hold", "hub_name", "layout", "split", "block", "direction", "ratio", "before", "after",
  -- rest of a saved pane
  "seen", "alive_on",
}) do KEY_ORDER[k] = i end

local ARRAY_KEYS = set_of({ "fresh", "revive", "windows", "argv", "pids" })

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

-- Identity of the running server; changes when it restarts. Rex's instance_id; servers that don't
-- report one get "PID@lstart", the format earlier versions (and the Python one) stored.
function M.server_id()
  local st = rex.call("server.status")
  if type(st) ~= "table" then return nil end
  if type(st.instance_id) == "string" and st.instance_id ~= "" then return st.instance_id end
  return M.legacy_server_id(st)
end

-- "PID@lstart" of the server, to recognise alive_on values saved before instance_id was used.
function M.legacy_server_id(st)
  st = st or rex.call("server.status")
  local pid = type(st) == "table" and st.pid
  if not pid then return nil end
  local r = exec({ "ps", "-o", "lstart=", "-p", tostring(pid) })
  if not r or not r.ok then return nil end
  return string.format("%d@%s", pid, trim(r.stdout))
end

-- Whether a saved alive_on/server value means the server running now (SERVER), also in the legacy
-- format. LEGACY is computed only when needed and cached in the table CACHE.
function M.same_server(v, server, cache)
  if v == nil or server == nil then return false end
  if v == server then return true end
  if not v:find("@", 1, true) then return false end
  if cache.legacy == nil then cache.legacy = M.legacy_server_id() or false end
  return cache.legacy ~= false and v == cache.legacy
end

-- ---- processes -------------------------------------------------------------------------------

-- Exact argv comes from procargs.js (sysctl KERN_PROCARGS2 through osascript), one call for all
-- the panes of a snapshot. The only environment variables read are Claude Code's relaunch hint and
-- HUB_NAME; the rest of a process's environment is never read or stored.
local HERE = (debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$")) or "."
local PROCARGS = HERE .. "/procargs.js"
local ENV_WANTED = { "CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS", "HUB_NAME" }
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

-- A bare executable matches its absolute argv[0] too; arguments must match whole words.
-- Never use the whitespace-split ps fallback for duplicate detection.
function M.argv_prefix(argv, cmd)
  if not argv or not cmd or #cmd == 0 or #argv < #cmd then return false end
  for i, word in ipairs(cmd) do
    local actual = argv[i]
    if i == 1 and not word:find("/", 1, true) then actual = basename(actual) end
    if actual ~= word then return false end
  end
  return true
end

-- Read exact argv only for possible matches. ps is a candidate filter, never the verdict.
-- Include parents so a match below a foreground wrapper can be attributed to its Rex pane.
function M.labelled_processes()
  local r, err = exec({ "ps", "-ww", "-axo", "pid=,ppid=,args=" })
  if not r or not r.ok then error("cannot check labelled processes: " .. tostring(err or (r and r.stderr)), 0) end
  local pids, parents = {}, {}
  for line in r.stdout:gmatch("[^\n]+") do
    local pid, parent, args = line:match("^%s*(%d+)%s+(%d+)%s+(.*)$")
    if pid then
      parents[tonumber(pid)] = tonumber(parent)
      for _, config in pairs(M.config.labelled) do
        if args:find(basename(config.cmd[1]), 1, true) then
          pids[#pids + 1] = pid
          break
        end
      end
    end
  end
  local matches = {}
  if #pids == 0 then return matches, parents end
  local result, why = exec(concat({ "osascript", "-l", "JavaScript", PROCARGS }, pids))
  local data = result and result.ok and rex.json.decode(result.stdout)
  if type(data) ~= "table" then error("cannot read exact labelled argv: " .. tostring(why), 0) end
  for _, pid in ipairs(pids) do
    if not data[pid] then
      local alive = exec({ "ps", "-p", pid, "-o", "pid=" })
      if not alive or alive.ok then error("cannot rule out a labelled program at pid " .. pid .. ": argv unavailable", 0) end
    end
  end
  for pid, info in pairs(data) do
    for label, config in pairs(M.config.labelled) do
      if M.argv_prefix(info.argv, config.cmd) then
        matches[label] = matches[label] or {}
        table.insert(matches[label], tonumber(pid))
      end
    end
  end
  for _, list in pairs(matches) do table.sort(list) end
  return matches, parents
end

function M.process_location(pid, parents, views)
  local ancestors = {}
  while pid and pid > 0 and not ancestors[pid] do
    ancestors[pid] = true
    pid = parents[pid]
  end
  for _, v in ipairs(views) do
    for _, w in ipairs(v.windows) do
      for _, leaf in ipairs(M.leaves(w.layout)) do
        if ancestors[leaf.pid] then return v, leaf end
      end
    end
  end
end

function M.labelled_running(label, matches, parents, views)
  if not matches then matches, parents = M.labelled_processes() end
  local pid = matches[label] and matches[label][1]
  if not pid then return nil end
  local v, leaf = M.process_location(pid, parents, views or M.snapshot())
  return "already running (pid " .. pid .. (v and (", in " .. (v.label or v.session_id) .. " / " .. (leaf.label or leaf.block_id)) or "") .. ")"
end

-- Templates contain shell text, not argv. Guard only a complete command equal to the configured
-- argv; shell compositions and wrappers are not inferred to be the same program.
function M.labelled_command(text)
  local ok, argv = pcall(M.split, text)
  if not ok then return nil end
  for label, config in pairs(M.config.labelled) do
    if list_eq(argv, config.cmd) then return label end
  end
end

function M.labelled_warnings(views, snap, matches, parents)
  local warnings = {}
  for label, config in pairs(M.config.labelled) do
    local found = false
    for _, v in ipairs(views) do
      for _, w in ipairs(v.windows) do
        for _, leaf in ipairs(M.leaves(w.layout)) do
          if leaf.label == label and ends_with(leaf.cwd or "", config.cwd_suffix or "") then found = true end
        end
      end
    end
    if not found then warnings[#warnings + 1] = label .. ": configuration matches no pane" end
    for _, pid in ipairs(matches[label] or {}) do
      local v, leaf = M.process_location(pid, parents, views)
      if v and (leaf.label ~= label or not ends_with(leaf.cwd or "", config.cwd_suffix or "")) then
        warnings[#warnings + 1] = label .. ": runs in " .. (v.label or v.session_id) .. "/" .. (leaf.label or leaf.block_id) .. ", not in its labelled pane"
      end
    end
    for _, e in pairs(snap.panes) do
      if e.kind == "labelled" and e.label == label and not list_eq(e.revive, config.cmd) then
        warnings[#warnings + 1] = label .. ": saved revive differs from current config cmd (revive uses current config)"
      end
    end
  end
  table.sort(warnings)
  return warnings
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
  return M.dedupe_flags(out)
end

-- Drop a flag group (a flag and the values after it) identical to an earlier one. Claude Code's
-- relaunch (/restart, auto-update) passes the original arguments again, so `--allowed-tools X`
-- groups repeat once per relaunch.
function M.dedupe_flags(flags)
  local groups, cur = {}, nil
  for _, a in ipairs(flags) do
    if starts_with(a, "-") or not cur then
      cur = { a }
      groups[#groups + 1] = cur
    else
      cur[#cur + 1] = a
    end
  end
  local out, seen = {}, {}
  for _, g in ipairs(groups) do
    local k = table.concat(g, "\0")
    if not seen[k] then
      seen[k] = true
      for _, a in ipairs(g) do out[#out + 1] = a end
    end
  end
  return out
end

-- Claude Code's sessions/<pid>.json. Claude Code has been seen leaving stray characters after the
-- object (a trailing "}"), which makes the whole file invalid JSON; only the leading object is read.
function M.leading_json_object(s)
  if type(s) ~= "string" then return nil end
  local start = s:find("{", 1, true)
  if not start then return nil end
  local depth, in_str, esc = 0, false, false
  for i = start, #s do
    local c = s:sub(i, i)
    if in_str then
      if esc then esc = false elseif c == "\\" then esc = true elseif c == '"' then in_str = false end
    elseif c == '"' then in_str = true
    elseif c == "{" then depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return s:sub(start, i) end
    end
  end
  return nil
end

function M.claude_session(pid)
  local raw = read_file(M.paths.claude_sessions .. "/" .. tostring(pid) .. ".json")
  if not raw then return nil end
  local ok, d = pcall(rex.json.decode, raw)
  if ok and type(d) == "table" then return d end
  local obj = M.leading_json_object(raw)
  if not obj then return nil end
  ok, d = pcall(rex.json.decode, obj)
  return ok and type(d) == "table" and d or nil
end

-- The sessions file of a running Claude Code: its own, or its relaunched child's (see claude_child).
function M.claude_session_of(pid)
  local d = M.claude_session(pid)
  if type(d) == "table" and d.sessionId then return d, pid end
  local c = M.claude_child(pid)
  if c then return M.claude_session(c), c end
  return d, pid
end

-- After /restart or an auto-update, Claude Code keeps the first `claude` process (the pane's
-- foreground) and runs the new version as its child; only the child has a sessions file. Returns
-- the pid of the first descendant (two levels deep) that has one.
function M.claude_child(pid)
  local function children(p)
    local r = exec({ "pgrep", "-P", tostring(p) })
    local out = {}
    if r and r.ok then for c in r.stdout:gmatch("%d+") do out[#out + 1] = tonumber(c) end end
    return out
  end
  for _, c in ipairs(children(pid)) do
    local ok, d = pcall(M.claude_session, c)
    if ok and type(d) == "table" and d.sessionId then return c end
    for _, g in ipairs(children(c)) do
      local ok2, d2 = pcall(M.claude_session, g)
      if ok2 and type(d2) == "table" and d2.sessionId then return g end
    end
  end
  return nil
end

local function claude_entry(pid, argv)
  local ok, d = pcall(M.claude_session, pid)
  local child
  if not ok or type(d) ~= "table" or not d.sessionId then
    child = M.claude_child(pid)
    if child then
      pid, d = child, M.claude_session(child)
      argv = M.argv(child) or argv
    end
  end
  -- set by /restart: the flags the conversation was launched with (empty means "use argv")
  local hint = M.proc_env(pid, "CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS")
  local flags
  if hint ~= nil and hint:match("%S") then
    local ok2, v = pcall(M.split, hint)
    flags = ok2 and M.dedupe_flags(v) or M.claude_flags(slice(argv, 2))
  else
    flags = M.claude_flags(slice(argv, 2))
  end
  if type(d) ~= "table" then d = nil end
  local sid = d and d.sessionId
  if not sid then -- last resort: the conversation it was started with
    for i = 2, #argv - 1 do
      if (argv[i] == "--resume" or argv[i] == "-r") and argv[i + 1]:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then sid = argv[i + 1] end
    end
  end
  local fresh = concat({ "claude" }, flags)
  return { kind = "claude", fresh = fresh, revive = sid and concat(fresh, { "--resume", sid }) or nil,
    note = (not sid) and "no session ID found" or nil,
    _name = d and d.name, _name_source = d and d.nameSource, _child = child }
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
  local e
  if prog == "claude" then e = claude_entry(pid, argv) elseif prog == "amp" then e = amp_entry(pid, argv) end
  if e then
    e._env_hub = M.proc_env(pid, "HUB_NAME") -- set when rex-agents started it
    e._pids = { tonumber(pid), e._child } -- the agent's processes, for names.json
    e._child = nil
    return e
  end
  if VIEWERS[prog] then
    local a = concat({ prog }, slice(argv, 2))
    return { kind = prog, fresh = a, revive = a }
  end
  return nil
end

-- ---- hub names -------------------------------------------------------------------------------
--
-- Every Claude Code / Amp pane rex-agents starts gets HUB_NAME=<name> in front of its command, a
-- name the pane keeps across restarts and revives (it owns an inbox on the hub). It is chosen once
-- and stored as hub_name in panes.json and in templates:
--   0. HUB_NAME the running program already has (only if no other pane has the same one)
--   1. the Claude Code session name, if you set it yourself (/rename): "worker chief 2" → worker-chief-2
--   2. the pane label, unless it is a generic one like "shell"
--   3. <session>-<kind>-<last 6 characters of the block ID>
-- Names must be unique among live panes; a taken one is tried again with the session name in front.

local AGENT_KINDS = set_of({ "claude", "amp", "amp-runner" })
M.AGENT_KINDS = AGENT_KINDS
local GENERIC_LABELS = set_of({ "shell", "terminal", "claude", "amp" })

-- The hub's rule: a letter or digit, then letters, digits, ".", "_" or "-"; at most 64.
function M.hub_valid(s)
  return type(s) == "string" and #s <= 64 and s:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") ~= nil
end

function M.hub_slug(s)
  local r = tostring(s or ""):lower():gsub("[^a-z0-9._-]+", "-"):gsub("%-%-+", "-"):gsub("^[^a-z0-9]+", "")
  r = r:sub(1, 64):gsub("[-._]+$", "")
  return r
end

-- A new name for agent entry E in block BID, not in TAKEN (rules 1-3 above).
function M.hub_pick(e, bid, taken)
  local sess = M.hub_slug(e.session or "")
  local cands = {}
  if e._name and e._name_source == "user" then cands[#cands + 1] = M.hub_slug(e._name) end
  local l = e.label
  if l and l ~= "" and not GENERIC_LABELS[l:lower()] and not SHELLS[l] then cands[#cands + 1] = M.hub_slug(l) end
  local tries = {}
  for _, c in ipairs(cands) do
    if c ~= "" then
      tries[#tries + 1] = c
      if sess ~= "" and c ~= sess and not starts_with(c, sess .. "-") then tries[#tries + 1] = M.hub_slug(sess .. "-" .. c) end
    end
  end
  local tail = "-" .. M.hub_slug(e.kind) .. "-" .. (tostring(bid):gsub("[^%w]", "")):sub(-6):lower()
  local head = (sess ~= "" and sess or "pane"):sub(1, 64 - #tail):gsub("[-._]+$", "")
  local base = head .. tail
  tries[#tries + 1] = base
  for _, t in ipairs(tries) do
    if M.hub_valid(t) and not taken[t] then return t end
  end
  local i = 2
  while taken[base:sub(1, 60) .. "-" .. i] do i = i + 1 end
  return base:sub(1, 60) .. "-" .. i
end

-- Give every live agent entry in PANES a hub_name (see the rules above) and drop the helper
-- fields classify added. OLD is the previous save's panes; LIVE the block IDs on screen.
local function assign_hub_names(panes, live, old)
  local agents = {}
  for bid in pairs(live) do
    local e = panes[bid]
    if e and AGENT_KINDS[e.kind] then agents[#agents + 1] = bid end
  end
  table.sort(agents, function(a, b)
    local sa, sb = panes[a].session or "", panes[b].session or ""
    if sa ~= sb then return sa < sb end
    return a < b
  end)
  local env_count = {}
  for _, bid in ipairs(agents) do
    local n = panes[bid]._env_hub
    if n then env_count[n] = (env_count[n] or 0) + 1 end
  end
  local taken, rest, need = {}, {}, {}
  for _, bid in ipairs(agents) do -- 0: what the program runs with
    local e = panes[bid]
    local n = e._env_hub
    if M.hub_valid(n) and env_count[n] == 1 and not taken[n] then
      e.hub_name = n
      taken[n] = true
    else
      rest[#rest + 1] = bid
    end
  end
  for _, bid in ipairs(rest) do -- the name chosen before
    local e, prev = panes[bid], old[bid]
    local n = e.hub_name or (prev and prev.hub_name)
    if M.hub_valid(n) and not taken[n] then
      e.hub_name = n
      taken[n] = true
    else
      e.hub_name = nil
      need[#need + 1] = bid
    end
  end
  for _, bid in ipairs(need) do -- 1-3: a new one
    local n = M.hub_pick(panes[bid], bid, taken)
    panes[bid].hub_name = n
    taken[n] = true
  end
  for _, e in pairs(panes) do e._name, e._name_source, e._env_hub = nil, nil, nil end
end

-- names.json: a published, versioned map block ID → hub name of every agent RUNNING now, so a tool
-- inside an agent (the hub's MCP server) can find its name through $REX_BLOCK when HUB_NAME isn't
-- set. `pids` are the agent's processes (the pane's foreground program and, after a Claude Code
-- relaunch, its child); a reader should accept the name only if one of them is its ancestor, so a
-- nested agent started inside that pane doesn't take it. Format version 1 is kept stable; see README.
function M.names_doc(panes, pids, server, now)
  local blocks = {}
  for bid, p in pairs(pids) do
    local e = panes[bid]
    if e and AGENT_KINDS[e.kind] and M.hub_valid(e.hub_name) then
      blocks[bid] = { hub_name = e.hub_name, kind = e.kind, session = e.session, session_id = e.session_id, pids = p }
    end
  end
  return { version = 1, saved_at = now, server = server, blocks = blocks }
end

-- "HUB_NAME=<name> " for an agent entry, else "".
function M.hub_prefix(e)
  if e and AGENT_KINDS[e.kind] and M.hub_valid(e.hub_name) then return "HUB_NAME=" .. e.hub_name .. " " end
  return ""
end

-- Block IDs of every pane in every session (tiled and floating), without reading the panes.
function M.live_block_ids()
  local ids = {}
  for _, s in ipairs(M.sessions()) do
    local v = M.raw_view(s.session_id)
    for _, w in ipairs(v and v.windows or {}) do
      for _, l in ipairs(w.layers or {}) do
        for _, b in ipairs(l.blocks or {}) do ids[b.block_id] = true end
      end
    end
  end
  return ids
end

-- Names held by live agent panes (from the last save).
function M.live_hub_names(snap)
  snap = snap or M.load_snap().panes
  local live, taken = M.live_block_ids(), {}
  for bid, e in pairs(snap) do
    if live[bid] and AGENT_KINDS[e.kind] and e.hub_name then taken[e.hub_name] = true end
  end
  return taken
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
  local panes, live, count, legacy, pids = {}, {}, 0, {}, {}
  for _, v in ipairs(views) do
    for _, w in ipairs(v.windows) do
      for _, leaf in ipairs(M.leaves(w.layout)) do
        local bid = leaf.block_id
        live[bid] = true
        local e = M.classify(leaf)
        local prev = old.panes[bid]
        if e and e._pids then pids[bid], e._pids = e._pids, nil end
        if e then
          e.session_id, e.session, e.window = v.session_id, v.label, w.label
          e.label, e.cwd, e.seen, e.alive_on = leaf.label, leaf.cwd, now, server
          panes[bid] = e
        elseif prev then
          -- Forget it only if it ran under THIS server and has since exited: you closed it yourself.
          -- Anything else (server restarted, not revived yet) stays until it is brought back.
          if not M.same_server(prev.alive_on, server, legacy) then panes[bid] = prev end
        end
      end
    end
  end
  for bid, prev in pairs(old.panes) do
    -- block not visible right now (server still starting, session hidden): keep it for a while
    if not live[bid] and now - (prev.seen or 0) < M.config.keep_missing then panes[bid] = prev end
  end
  assign_hub_names(panes, live, old.panes)
  -- If the server stopped or restarted while we looked, programs that were dying would look like
  -- programs you exited. Keep the previous save instead.
  if server and M.server_id() ~= server then
    return { skipped = "the Rex server stopped or restarted during the scan, kept the previous save" }
  end
  for _ in pairs(panes) do count = count + 1 end
  if read_file(M.paths.snap) then copy_file(M.paths.snap, M.paths.prev) end
  M.write_json(M.paths.snap, { server = server or old.server, saved_at = now, panes = panes }, "600")
  M.write_json(M.paths.names, M.names_doc(panes, pids, server, now), "600")
  return { panes = count }
end

-- ---- status and verify -----------------------------------------------------------------------

-- The LaunchAgent that runs watch.lua: { label, loaded, pid }, or nil when the check is off
-- (REX_AGENTS_WATCH_LABEL=-, used by the tests).
function M.watcher()
  local label = env("REX_AGENTS_WATCH_LABEL", "com.rex-agents.watch")
  if label == "-" then return nil end
  local r = exec({ "launchctl", "list", label })
  if not r or not r.ok then return { label = label, loaded = false } end
  return { label = label, loaded = true, pid = tonumber(r.stdout:match('"PID"%s*=%s*(%d+)')) }
end

-- One row per classified or saved pane, including missing and unresumable panes:
-- { session, session_id, window, label, block_id, kind, hub_name, env_hub, state }. state is
--   ok               the program runs with HUB_NAME = its hub name
--   restart pending  it runs without HUB_NAME; it gets the name the next time rex-agents starts it
--   runs as NAME     it runs with another HUB_NAME (set by hand, or shared with another pane)
--   not saved yet    started since the last save
--   not running      the pane is an idle shell (⌘⇧B brings it back)
-- Reads the panes and the last save; changes nothing.
function M.status()
  local snap = M.load_snap()
  local rows, seen = {}, {}
  local views = M.snapshot()
  local matches, parents = M.labelled_processes()
  for _, v in ipairs(views) do
    for _, w in ipairs(v.windows) do
      for _, leaf in ipairs(M.leaves(w.layout)) do
        local bid = leaf.block_id
        local saved = snap.panes[bid]
        seen[bid] = true
        local classified = M.classify(leaf)
        local e = classified or saved
        if e then
          local hub, env_hub = saved and saved.hub_name, classified and classified._env_hub
          local pane = M.pane_state(v.session_id, bid)
          local reason
          if e.kind == "services" and not M.config.services.action then reason = "no services action configured"
          elseif e.kind == "labelled" and not M.config.labelled[e.label or leaf.label] then reason = "labelled configuration removed"
          elseif e.kind ~= "services" and (not e.revive or #e.revive == 0) then reason = e.note or "no revive command" end
          local state
          if reason then state = "cannot resume: " .. reason
          elseif e.kind == "labelled" then
            state = M.labelled_running(e.label or leaf.label, matches, parents, views) or (pane == "idle" and "not running" or ("pane is " .. pane))
          elseif pane == "idle" then state = "not running"
          elseif pane ~= "busy" then state = "pane is " .. pane
          elseif not classified then state = "busy (different program)"
          elseif not AGENT_KINDS[e.kind] then state = "running"
          elseif not hub then state = "not saved yet"
          elseif env_hub == hub then state = "ok"
          elseif env_hub then state = "runs as " .. env_hub
          else state = "restart pending" end
          rows[#rows + 1] = { session = v.label, session_id = v.session_id, window = w.label, label = leaf.label,
            block_id = bid, kind = e.kind, hub_name = hub, env_hub = env_hub, state = state, reason = reason }
        end
      end
    end
  end
  for bid, e in pairs(snap.panes) do
    if not seen[bid] then
      rows[#rows + 1] = { session = e.session, session_id = e.session_id, window = e.window,
        label = e.label, block_id = bid, kind = e.kind, hub_name = e.hub_name,
        state = "pane missing", reason = e.note or "pane missing" }
    end
  end
  table.sort(rows, function(a, b)
    local ka = { a.session or "", a.window or "", a.label or "", a.block_id }
    local kb = { b.session or "", b.window or "", b.label or "", b.block_id }
    for i = 1, 4 do if ka[i] ~= kb[i] then return ka[i] < kb[i] end end
    return false
  end)
  return { rows = rows, saved_at = snap.saved_at, watcher = M.watcher(),
    warnings = M.labelled_warnings(views, snap, matches, parents) }
end

-- Check panes.json, the watcher and (with AGAINST, a copy of panes.json taken before a change)
-- what changed. Returns { errors = {...}, warnings = {...}, info = {...} }; nothing is written.
function M.verify(against)
  local errors, warnings, info = {}, {}, {}
  local function err(f, ...) errors[#errors + 1] = string.format(f, ...) end
  local function warn(f, ...) warnings[#warnings + 1] = string.format(f, ...) end
  local function note(f, ...) info[#info + 1] = string.format(f, ...) end
  local function where(bid, e)
    return string.format("%s / %s / %s (%s)", e.session or "?", e.window or "?", e.label or "?", bid)
  end

  local ok, snap = pcall(M.read_json, M.paths.snap)
  if not ok or type(snap) ~= "table" or type(snap.panes) ~= "table" then
    err("%s is missing or not valid JSON", M.paths.snap)
    return { errors = errors, warnings = warnings, info = info }
  end
  local live = M.live_block_ids()
  local views = M.snapshot()
  local matches, parents = M.labelled_processes()
  for _, warning in ipairs(M.labelled_warnings(views, snap, matches, parents)) do warn("%s", warning) end
  local count, agents, holders, no_cmd = 0, 0, {}, 0
  for bid, e in pairs(snap.panes) do
    count = count + 1
    for k in pairs(e) do
      if type(k) == "string" and k:sub(1, 1) == "_" then err("helper field %s left in %s", k, where(bid, e)) end
    end
    if not e.kind then
      err("no kind: %s", where(bid, e))
    elseif e.kind ~= "services" and (type(e.revive) ~= "table" or #e.revive == 0) then
      if not e.note then err("no revive command: %s", where(bid, e))
      elseif live[bid] then warn("open pane's agent can't be resumed (%s): %s", e.note, where(bid, e))
      else no_cmd = no_cmd + 1 end
    end
    if AGENT_KINDS[e.kind] then
      if e.hub_name ~= nil and not M.hub_valid(e.hub_name) then err("invalid hub name %q: %s", tostring(e.hub_name), where(bid, e)) end
      if live[bid] then
        agents = agents + 1
        if not e.hub_name then err("live agent without a hub name: %s", where(bid, e)) end
        if e.hub_name then
          holders[e.hub_name] = holders[e.hub_name] or {}
          table.insert(holders[e.hub_name], where(bid, e))
        end
      end
    elseif e.hub_name ~= nil then
      err("hub name on a %s pane: %s", tostring(e.kind), where(bid, e))
    end
  end
  for name, list in pairs(holders) do
    if #list > 1 then err("hub name %s is used by %d live panes: %s", name, #list, table.concat(list, "; ")) end
  end
  local age = snap.saved_at and (os.time() - snap.saved_at)
  note("%d entries, %d live agents, last save %s", count, agents, age and (age .. " s ago") or "unknown")
  if no_cmd > 0 then note("%d closed panes can't be resumed (e.g. Claude Code without a session ID); kept up to %d days", no_cmd, math.floor(M.config.keep_missing / 86400)) end
  if age and age > 300 then warn("last save was %d s ago (the watcher saves every 2 min)", age) end
  local server = M.server_id()
  if server and snap.server and not M.same_server(snap.server, server, {}) then
    warn("the last save is from before the Rex server restarted (%s, now %s)", snap.server, server)
  end

  local w = M.watcher()
  if w then
    if not w.loaded then err("watcher %s is not loaded (run ./install.sh)", w.label)
    elseif not w.pid then err("watcher %s is loaded but not running (see ~/Library/Logs/rex-agents.log)", w.label)
    else note("watcher %s running, pid %d", w.label, w.pid) end
  end

  if against then
    local ok2, old = pcall(M.read_json, against)
    if not ok2 or type(old) ~= "table" or type(old.panes) ~= "table" then
      err("%s is missing or not valid JSON", against)
    else
      -- what each live pane runs now, to tell an exited program from one no longer recognised
      local fg
      local function fg_of(bid)
        if not fg then
          fg = {}
          for _, sess in ipairs(M.sessions()) do
            local v = M.view(sess.session_id)
            for _, w2 in ipairs(v and v.windows or {}) do
              for _, leaf in ipairs(M.leaves(w2.layout)) do fg[leaf.block_id] = leaf.fg or "" end
            end
          end
        end
        return fg[bid]
      end
      local n_old, missing, added, changed = 0, 0, 0, 0
      for bid, o in pairs(old.panes) do
        n_old = n_old + 1
        local e = snap.panes[bid]
        if not e then
          missing = missing + 1
          local now_fg = live[bid] and fg_of(bid)
          if not live[bid] then
            warn("gone since %s, pane closed: %s %s", against, where(bid, o), tostring(o.kind))
          elseif now_fg == nil or SHELLS[now_fg] then
            warn("gone since %s, program exited: %s %s", against, where(bid, o), tostring(o.kind))
          else
            err("no longer recognised (pane runs %s): %s %s", now_fg, where(bid, o), tostring(o.kind))
          end
        elseif e.kind ~= o.kind then
          changed = changed + 1
          err("kind changed %s → %s: %s", tostring(o.kind), tostring(e.kind), where(bid, e))
        elseif (o.revive == nil or #o.revive == 0) and e.revive and #e.revive > 0 then
          note("now resumable: %s", where(bid, e))
        elseif M.join(e.revive or {}) ~= M.join(o.revive or {}) then
          changed = changed + 1
          err("revive command changed: %s\n    was: %s\n    now: %s", where(bid, e), M.join(o.revive or {}), M.join(e.revive or {}))
        end
      end
      for bid in pairs(snap.panes) do if not old.panes[bid] then added = added + 1 end end
      note("against %s: %d → %d entries, %d missing, %d new, %d changed", against, n_old, count, missing, added, changed)
    end
  end
  table.sort(errors)
  return { errors = errors, warnings = warnings, info = info }
end

-- ---- revive ----------------------------------------------------------------------------------

-- What a pane is doing now: "idle" (a shell at its prompt), "starting" (the shell isn't up yet),
-- "busy" (a program runs, or a shell inside another shell), or "gone".
function M.pane_state(sid, bid)
  local r = block_call(sid, "process", { block_id = bid })
  if not r then return "gone" end
  local fg = r.foreground
  if not fg then return "starting" end
  local name = tostring(fg.name or ""):gsub("^%-", "")
  if (name == "login" or name == "rex") and r.child and fg.pid == r.child.pid then return "starting" end
  if not SHELLS[fg.name] and not SHELLS[name] then return "busy" end
  for _, a in ipairs(r.ancestors or {}) do
    local an = tostring(a.name or ""):gsub("^%-", "")
    if SHELLS[an] and an ~= "login" then return "busy" end
  end
  return "idle"
end

-- Wait up to WAIT seconds (default 10) for a starting pane, then type TEXT + enter only if the pane
-- is an idle shell. Returns true, or nil and why not.
function M.type_if_idle(sid, bid, text, wait)
  local deadline = os.time() + (wait or 10)
  local st = M.pane_state(sid, bid)
  while st == "starting" and os.time() < deadline and rex.sleep do
    rex.sleep(0.3)
    st = M.pane_state(sid, bid)
  end
  if st ~= "idle" then return nil, "pane is " .. st end
  return M.type_into(sid, bid, text)
end

function M.type_into(sid, bid, text)
  local _, err = block_call(sid, "write", { block_id = bid, data = text })
  if err then return nil, err end
  return block_call(sid, "write", { block_id = bid, data = "\r" })
end

function M.wait_ready(label)
  local ready = M.config.labelled[label].ready
  if not ready then return end
  local path = expand_home(ready.path)
  local deadline = os.time() + (ready.timeout or 30)
  repeat
    local r = exec({ "test", "-e", path }) -- includes sockets, which io.open cannot read
    if r and r.ok then return end
    if os.time() >= deadline or not rex.sleep then break end
    rex.sleep(0.2)
  until false
  return label .. ": readiness timed out waiting for " .. path .. "; continuing"
end

-- Serialize labelled launches using this state directory until the exact program appears.
-- A crash or unconfirmed launch leaves the lock behind rather than risk starting another copy.
function M.start_command(sid, bid, text, label, hold)
  local keep_lock = false
  local function start()
    local deadline = os.time() + 10
    local state = M.pane_state(sid, bid)
    while state == "starting" and os.time() < deadline and rex.sleep do
      rex.sleep(0.3)
      state = M.pane_state(sid, bid)
    end
    if state ~= "idle" then return nil, "pane is " .. state end
    -- Check after waiting for the shell, not only when the picker or template was opened.
    if label then
      local reason = M.labelled_running(label)
      if reason then return nil, reason end
    end
    if hold then
      return block_call(sid, "write", { block_id = bid, data = text })
    end
    keep_lock = label ~= nil
    local ok, err = M.type_if_idle(sid, bid, text, 0)
    if not ok or not label then return ok, err end
    deadline = os.time() + 10
    repeat
      if M.labelled_running(label) then keep_lock = false; break end
      if os.time() >= deadline or not rex.sleep then break end
      rex.sleep(0.2)
    until false
    if keep_lock then return ok, label .. ": launch unconfirmed; labelled-start.lock retained; inspect before retrying" end
    return ok, M.wait_ready(label)
  end
  if not label then return start() end
  mkdir(M.paths.state)
  local lock = M.paths.state .. "/labelled-start.lock"
  local r = exec({ "mkdir", lock })
  if not r or not r.ok then return nil, "labelled launch locked: " .. lock end
  local ok, result, detail = pcall(start)
  if not keep_lock then exec({ "rmdir", lock }) end
  if not ok then return nil, tostring(result) end
  return result, detail
end

-- What revive would do now: { todo = { {bid, sid, entry, line} }, services = { sid... } }.
function M.revive_plan()
  local snap = M.load_snap()
  local live = {}
  local views = M.snapshot()
  local matches, parents = M.labelled_processes()
  for _, v in ipairs(views) do
    for _, w in ipairs(v.windows) do
      for _, leaf in ipairs(M.leaves(w.layout)) do live[leaf.block_id] = { sid = v.session_id, leaf = leaf } end
    end
  end
  local todo, services, seen_sid, skipped = {}, {}, {}, {}
  local service_panes = 0
  for bid, e in pairs(snap.panes) do
    local l = live[bid]
    if l then
      if e.kind == "services" then
        if M.config.services.action and M.pane_state(l.sid, bid) == "idle" then
          service_panes = service_panes + 1
          if not seen_sid[l.sid] then
            seen_sid[l.sid] = true
            services[#services + 1] = l.sid
          end
        end
      elseif SHELLS[l.leaf.fg] and e.revive and #e.revive > 0 then
        local argv, reason, label = e.revive
        if e.kind == "labelled" then
          label = e.label
          local config = M.config.labelled[label]
          if not config then reason = "labelled configuration removed"
          else
            argv = config.cmd
            reason = M.labelled_running(label, matches, parents, views)
          end
        end
        if reason then
          skipped[#skipped + 1] = { bid = bid, label = e.label, reason = reason }
        else
          local cmd = M.hub_prefix(e) .. M.join(argv)
          local line = e.cwd and (" cd " .. M.quote(e.cwd) .. " && " .. cmd) or (" " .. cmd)
          todo[#todo + 1] = { bid = bid, sid = l.sid, e = e, line = line, labelled = label, argv = argv }
        end
      end
    end
  end
  table.sort(todo, function(a, b)
    if (a.labelled ~= nil) ~= (b.labelled ~= nil) then return a.labelled ~= nil end
    local ka = { a.e.session or "", a.e.window or "", a.bid }
    local kb = { b.e.session or "", b.e.window or "", b.bid }
    for i = 1, 3 do if ka[i] ~= kb[i] then return ka[i] < kb[i] end end
    return false
  end)
  table.sort(services)
  return { todo = todo, services = services, service_panes = service_panes, skipped = skipped }
end

-- ---- notice after a server restart ------------------------------------------------------------

-- Whether the restart notice is due: the save before the watcher started (PREV) was taken under
-- another server than the one running now (CUR), and no notice went out for CUR yet. NOTIFIED is
-- notified.json, which keeps a watcher that launchd restarts (or a second watcher) from repeating it.
function M.restart_notice_due(prev, cur, notified, cache)
  if prev == nil or cur == nil then return false end -- first install, or the server isn't answering
  if M.same_server(prev, cur, cache or {}) then return false end -- only the watcher restarted
  return not (type(notified) == "table" and notified.server == cur)
end

function M.restart_message(n)
  return string.format("%d %s can be brought back — press ⌘⇧B", n, n == 1 and "pane" or "panes")
end

-- Show a macOS notification. REX_AGENTS_NOTIFY_CMD replaces osascript (tests); it gets TITLE TEXT.
-- The texts travel as arguments of `on run argv`, so nothing in them is parsed as AppleScript.
function M.notify(title, text)
  local cmd = env("REX_AGENTS_NOTIFY_CMD", nil)
  local argv = cmd and { cmd, title, text } or { "osascript",
    "-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run",
    title, text }
  local r, err = exec(argv)
  if not r then return nil, err end
  if not r.ok then return nil, trim((r.stderr or "") ~= "" and r.stderr or ("exit " .. tostring(r.code))) end
  return true
end

-- Called by the watcher after each save until it returns non-nil. PREV is panes.json's server from
-- before the watcher's first save. Returns { count, sent, why } once decided, or nil to try again
-- after the next save (no save has happened under this server yet).
function M.restart_notice(prev)
  if M.config.notify == false then return { count = 0, why = "off (notify = false)" } end
  local cur = M.server_id()
  if cur == nil or M.load_snap().server ~= cur then return nil end -- the save under this server was skipped
  local okn, notified = pcall(M.read_json, M.paths.notified)
  if not M.restart_notice_due(prev, cur, okn and notified or nil) then
    return { count = 0, why = "not due (no server restart, or already sent for this server)" }
  end
  local plan = M.revive_plan()
  local n = #plan.todo + plan.service_panes
  -- recorded before notifying: a failing notifier must not make every watcher restart try again
  M.write_json(M.paths.notified, { server = cur, saved_at = os.time(), count = n }, "600")
  if n == 0 then return { count = 0, why = "nothing to bring back" } end
  local ok, err = M.notify("rex-agents", M.restart_message(n))
  if not ok then return { count = n, why = "notify failed: " .. tostring(err) } end
  return { count = n, sent = true, why = "sent: " .. M.restart_message(n) }
end

function M.revive_row(t)
  local e = t.e
  return string.format("%-14s %-16s %s%s%s", (e.session or ""):sub(1, 14), (e.window or ""):sub(1, 16),
    M.join(t.argv or e.revive):sub(1, 110), M.hub_prefix(e) ~= "" and ("  [" .. e.hub_name .. "]") or "",
    e.note and ("  (" .. e.note .. ")") or "")
end

function M.run_services(sid)
  local action = M.config.services.action
  if not action then return nil, "no services action configured" end
  -- the same rex binary bin/rex-agents ran (PATH here prefers the installed app's)
  local argv = { env("REX_AGENTS_REX", "rex"), "--autostart=false" }
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

local function tpl_node(node, old_blocks, hub_for)
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
    if e and AGENT_KINDS[e.kind] then b.hub_name = hub_for(node, e, old) end
    if old and not b.cmd and old.cmd then -- keep hand-written commands of labelled panes
      b.cmd = old.cmd
      if old.hold then b.hold = true end
      b.hub_name = old.hub_name
    end
    if node.label and node.label ~= "shell" then b.label = node.label end
    return { block = b }
  end
  return { split = { direction = node.direction, ratio = node.ratio or 0.5,
    before = tpl_node(node.before, old_blocks, hub_for), after = tpl_node(node.after, old_blocks, hub_for) } }
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
  -- hub name of an agent pane: a hand-written one in the old template wins, then what the program
  -- runs with, then the one the last save chose, else a new one
  local snap = M.load_snap().panes
  local taken = M.live_hub_names(snap)
  local function hub_for(node, e, old)
    if old and old.hub_name then return old.hub_name end
    local env = node.pid and M.proc_env(node.pid, "HUB_NAME")
    if M.hub_valid(env) then return env end
    local s = snap[node.block_id]
    if s and M.hub_valid(s.hub_name) then return s.hub_name end
    local n = M.hub_pick({ kind = e.kind, label = node.label, session = v.label, _name = e._name,
      _name_source = e._name_source }, node.block_id, taken)
    taken[n] = true
    return n
  end
  local tw = {}
  for _, w in ipairs(wins) do
    local entry = { layout = tpl_node(w.layout, old_blocks, hub_for) }
    if not is_default_window_label(w.label) then entry.label = w.label end
    tw[#tw + 1] = entry
  end
  local tpl = { name = name, saved_at = os.date("%Y-%m-%d %H:%M"), windows = tw }
  local path = M.template_path(name)
  M.write_json(path, tpl)
  return { saved = home_tilde(path), windows = #tw, name = name }
end

-- HUB(name) → the name to use (template_open makes taken names unique); nil = use as written.
local function rex_layout(node, fresh, hub, launches)
  if node.block then
    local b = node.block
    local opts = {}
    if b.cwd then opts.cwd = expand_home(b.cwd) end
    local cmd
    if fresh then cmd = b.cmd else cmd = b.resume or b.cmd end
    local labelled = cmd and M.labelled_command(cmd)
    if cmd and b.hub_name then
      local n = hub and hub(b.hub_name) or b.hub_name
      if not M.hub_valid(n) then n = M.hub_slug(n) end
      if n ~= "" then cmd = "HUB_NAME=" .. n .. " " .. cmd end
    end
    if launches then
      launches[#launches + 1] = { cmd = cmd, labelled = labelled, hold = b.hold, label = b.label }
    elseif cmd then opts.initial_input = b.hold and cmd or (cmd .. "\r") end -- hold: typed, not run
    local out = { flavor = SHELL_FLAVOR, options = opts }
    if b.label and b.label ~= "shell" then out.label = b.label end
    return { block = out }
  end
  local s = node.split
  return { split = { direction = s.direction, ratio = s.ratio or 0.5,
    before = rex_layout(s.before, fresh, hub, launches), after = rex_layout(s.after, fresh, hub, launches) } }
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
  -- a name a live pane already uses gets the session name in front (then -2, -3…)
  local taken, sess = M.live_hub_names(), M.hub_slug(tpl.name)
  local function hub(n)
    if not M.hub_valid(n) then n = M.hub_slug(n) end
    if n == "" then return n end
    local t = n
    if taken[t] and sess ~= "" and not starts_with(t, sess .. "-") then t = M.hub_slug(sess .. "-" .. n) end
    local i = 2
    while taken[t] do t = n:sub(1, 60) .. "-" .. i; i = i + 1 end
    taken[t] = true
    return t
  end
  local wins, launches = {}, {}
  for i, w in ipairs(tpl.windows or {}) do
    launches[i] = {}
    wins[#wins + 1] = { window_label = w.label, layout = rex_layout(w.layout, fresh, hub, launches[i]) }
  end
  local r, err = rex.call("session.create", { label = tpl.name, initial_windows = wins })
  if not r then error("session.create: " .. tostring(err), 0) end
  r.messages = {}
  -- Do not put guarded commands in initial_input: another copy may start while the session opens.
  for _, labelled_first in ipairs({ true, false }) do
    for i, list in ipairs(launches) do
      for j, launch in ipairs(list) do
        if launch.cmd and (launch.labelled ~= nil) == labelled_first then
          local ok, detail = M.start_command(r.session_id, r.initial_windows[i].block_ids[j],
            launch.cmd, launch.labelled, launch.hold)
          if detail then r.messages[#r.messages + 1] = (launch.label or "pane") .. ": " .. (ok and "warning: " or "skipped: ") .. detail end
        end
      end
    end
  end
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
          local d = M.claude_session_of(leaf.pid)
          if type(d) == "table" and d.status == "busy" then busy[#busy + 1] = d.cwd or d.sessionId end
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
      local cmd = (e.revive and e.kind ~= "services") and (M.hub_prefix(e) .. M.join(e.revive)) or nil
      local labelled = cmd and M.labelled_command(cmd)
      if e.kind == "labelled" and M.config.labelled[e.label] then
        labelled, cmd = e.label, M.join(M.config.labelled[e.label].cmd)
      end
      local opts = { cwd = n.cwd or HOME }
      if cmd and not labelled then opts.initial_input = cmd end
      local b = { flavor = SHELL_FLAVOR, options = opts }
      if n.label and n.label ~= "shell" then b.label = n.label end
      order[#order + 1] = { old = n.block_id, label = n.label, cmd = cmd, labelled = labelled, staged = not labelled }
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
    o.labelled = o.labelled or M.labelled_command(o.cmd)
  end
  for _, labelled_first in ipairs({ true, false }) do
    for _, o in ipairs(pend[name] or {}) do
      if (o.labelled ~= nil) == labelled_first then
        local ok, detail
        if o.labelled and not M.config.labelled[o.labelled] then detail = "labelled configuration removed"
        else
          if o.labelled and o.staged == false then o.cmd = M.join(M.config.labelled[o.labelled].cmd) end
          local text = o.staged == false and o.cmd or ""
          ok, detail = M.start_command(s.session_id, o.new, text, o.labelled)
        end
        o.error, o.warning = nil, nil
        if not ok then o.error = tostring(detail); left[#left + 1] = o
        else o.warning = detail end
        started[#started + 1] = o
      end
    end
  end
  pend[name] = (#left > 0) and left or nil -- keep the ones that failed for another try
  M.write_json(M.paths.pending, pend, "600")
  return started
end

return M
