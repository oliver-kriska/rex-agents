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
  { "knowledge_university", "knowledge-university" }, { "Čaj Ok", "aj-ok" } }) do
  check("slug " .. c[1], A.slug(c[1]), c[2])
end

check("window label default", A.is_default_window_label("Window 0a1b2c3d"), true)
check("window label custom", A.is_default_window_label("PR Marmot"), false)
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
