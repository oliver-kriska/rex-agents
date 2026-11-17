-- Run the same unit suite without Rex. Only the JSON and subprocess APIs are adapted;
-- any accidental server call fails because no server API exists in this adapter.
local json = require("dkjson")
local function quote(s) return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'" end
local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a"); f:close(); return s
end
rex = {
  args = {}, stop = os.exit,
  json = { encode = json.encode, decode = function(s)
    local value, _, err = json.decode(s)
    assert(not err, err)
    return value
  end },
  exec = function(argv, opts)
    opts = opts or {}
    local out, err, input = os.tmpname(), os.tmpname(), os.tmpname()
    local f = assert(io.open(input, "w")); f:write(opts.stdin or ""); f:close()
    local words = {}
    for _, arg in ipairs(argv) do words[#words + 1] = quote(arg) end
    -- Unit cases use only short-lived local tools; timeout/async behaviour belongs to e2e.
    local result = os.execute(table.concat(words, " ") .. " <" .. quote(input) .. " >" .. quote(out) .. " 2>" .. quote(err))
    local r = { ok = result == 0 or result == true, stdout = read(out), stderr = read(err) }
    os.remove(out); os.remove(err); os.remove(input)
    return r
  end,
}
dofile("tests/unit.lua")
