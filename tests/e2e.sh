#!/bin/sh
# End-to-end test on a THROWAWAY Rex server. Never touches your own server:
#   - starts its own `rex server run` on a private socket, with its own state dir and config
#   - pins every rex call with -S (REX_SERVER alone falls back to the home server when the
#     named server is down)
#   - "restarts" by sending SIGTERM to that server's PID only, after checking its command line
#   - runs fake `claude` / `amp` binaries (tests/fake.c), never the real ones
#
# Covers: save → server restart → revive; park → reopen with conversations; template round trip.
# Usage: tests/e2e.sh            (needs cc, jq, fzf not required)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/rex-agents-e2e.XXXXXX")
SOCK="/tmp/rex-agents-e2e-$$.sock" # unix socket paths must stay short
URL="unix://$SOCK"
REX=$(command -v rex || echo "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex")
SERVER_PID=

rx() { "$REX" --autostart=false -S "$URL" "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok - $*"; }

stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  if ps -o command= -p "$SERVER_PID" | grep -q -- "--listen $URL"; then
    kill -TERM "$SERVER_PID"
    while kill -0 "$SERVER_PID" 2>/dev/null; do sleep 0.2; done
  fi
  SERVER_PID=
}
cleanup() { stop_server; rm -f "$SOCK"; rm -rf "$T"; }
trap cleanup EXIT INT TERM

# ---- environment: fakes first on PATH, private dirs, a zsh that reads none of your rc files
mkdir -p "$T/bin" "$T/state" "$T/cfg" "$T/agents" "$T/templates" "$T/claude" "$T/amp/threads" "$T/zdot" "$T/w/dir with space" "$T/w/hub-live" "$T/w/plain"
cc -O0 -o "$T/bin/claude" "$ROOT/tests/fake.c"
cp "$T/bin/claude" "$T/bin/amp"
cat > "$T/zdot/.zshrc" <<EOF
export PATH="$T/bin:\$PATH"
PROMPT='e2e %# '
EOF
: > "$T/zdot/.zprofile"
ln -s "$ROOT/rex-agents" "$T/cfg/rex-agents"
cat > "$T/cfg/init.lua" <<EOF
require("rex-agents.actions"){ bin = "$ROOT/bin/rex-agents" }
rex.action{ name = "e2e_services", title = "e2e services", run = function(ctx)
  local f = io.open("$T/services.txt", "a"); f:write(ctx.session_id, "\n"); f:close()
end }
EOF
cat > "$T/local.lua" <<'EOF'
return {
  labelled = { hub = { cwd_suffix = "/hub-live", cmd = { "sleep", "86400" } } },
  services = { labels = { iex = "iex -S mix phx.server" }, action = "e2e_services" },
}
EOF
unset REX_SESSION REX_BLOCK REX_CLIENT
export ZDOTDIR="$T/zdot" PATH="$T/bin:$PATH" REX_SERVER="$URL" REX_AGENTS_SERVER="$URL" \
  REX_AGENTS_STATE="$T/agents" REX_AGENTS_TEMPLATES="$T/templates" REX_AGENTS_CLAUDE_SESSIONS="$T/claude" \
  REX_AGENTS_CONFIG="$T/local.lua" FAKE_AMP_DIR="$T/amp"
RA="$ROOT/bin/rex-agents"

start_server() {
  "$REX" server run --listen "$URL" --state-dir "$T/state" --config "$T/cfg/init.lua" >>"$T/server.log" 2>&1 &
  SERVER_PID=$!
  i=0; until rx whoami >/dev/null 2>&1; do i=$((i + 1)); [ $i -lt 100 ] || fail "server did not start"; sleep 0.1; done
}

# pane output of session $1, pane labelled $2
pane() {
  b=$(rx block ls -s "$1" --json | jq -r --arg l "$2" '.blocks[] | select(.label == $l) | .block_id' | head -1)
  rx capture -s "$1" -b "$b" --trim --unwrap
}
wait_for() { # wait_for SESSION LABEL REGEX
  i=0; until pane "$1" "$2" | grep -Eq "$3"; do i=$((i + 1)); [ $i -lt 50 ] || { pane "$1" "$2" | tail -5; fail "$1/$2: no match for $3"; }; sleep 0.2; done
}

start_server

# ---- fixture
cat > "$T/fixture.lua" <<EOF
local W = "$T/w"
local function b(label, cwd, input)
  local o = { cwd = cwd }
  if input then o.initial_input = input .. "\r" end
  return { block = { flavor = "com.superlogical.terminal.shell", label = label, options = o } }
end
local function h(a, c) return { split = { direction = "horizontal", ratio = 0.5, before = a, after = c } } end
local function v(a, c) return { split = { direction = "vertical", ratio = 0.3, before = a, after = c } } end
assert(rex.call("session.create", { label = "Proj", initial_windows = {
  { window_label = "Agents", layout = h(
    v(b("mgr", W .. "/dir with space", "claude --dangerously-load-development-channels server:amp-bridge 'do the thing'"),
      v(b("amp", W .. "/plain", "amp"), b("runner", W .. "/plain", "amp --no-tui --runner-id r1"))),
    v(v(b("hub", W .. "/hub-live", "sleep 86400"), b("iex", W .. "/plain", nil)),
      v(b("restarted", W .. "/plain", "CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS='--model opus --add-dir /tmp' claude --resume 11111111-2222-3333-4444-555555555555"),
        v(b("plain", W .. "/plain", nil), b("oneshot", W .. "/plain", "amp -x 'one shot'"))))) } } }))
assert(rex.call("session.create", { label = "Park Me", initial_windows = {
  { window_label = "Work", layout = h(b("busy", W .. "/plain", "FAKE_STATUS=busy claude --model opus"), b("thread", W .. "/plain", "amp")) } } }))
EOF
rx do "$T/fixture.lua" >/dev/null
wait_for Proj mgr "^session "
wait_for Proj amp "^thread "
wait_for "Park Me" busy "^session "

# ---- save
"$RA" save | grep -q "saved 8 panes" || { jq -c "[.panes[].label]" "$T/agents/panes.json"; fail "expected 8 saved panes"; }
P="$T/agents/panes.json"
jq -e '[.panes[] | select(.label == "mgr")][0].revive | index("do the thing") == null and .[1] == "--dangerously-load-development-channels" and .[2] == "server:amp-bridge" and .[3] == "--resume"' "$P" >/dev/null \
  || fail "quoted prompt must be dropped, flags kept"
jq -e '[.panes[] | select(.label == "restarted")][0].fresh == ["claude","--model","opus","--add-dir","/tmp"]' "$P" >/dev/null || fail "/restart hint flags"
jq -e '[.panes[] | select(.label == "runner")][0].revive == ["amp","--no-tui","--runner-id","r1"]' "$P" >/dev/null || fail "amp runner"
jq -e '[.panes[] | select(.label == "oneshot" or .label == "plain")] | length == 0' "$P" >/dev/null || fail "one-shot amp and plain shells are not saved"
ok "save: 8 panes, exact argv, hint flags, runner, skips"

# ---- (a) restart the server: panes come back as empty shells under the same block IDs
OLD_SERVER=$(jq -r .server "$P")
stop_server
start_server
"$RA" save >/dev/null
[ "$(jq '.panes | length' "$P")" = 8 ] || fail "restart must keep every saved pane"
[ "$(jq -r .server "$P")" != "$OLD_SERVER" ] || fail "server id must change on restart"
[ "$("$RA" revive --dry-run | grep -vc "^services:")" = 7 ] || fail "7 panes must be revivable after the restart"
ok "(a) restart: 8 panes kept, new server id"

# ---- (b) revive everything
"$RA" revive >"$T/revive.txt"
[ "$(grep -c '^started:' "$T/revive.txt")" = 7 ] || { cat "$T/revive.txt"; fail "expected 7 started"; }
grep -q "^services:" "$T/revive.txt" || fail "services action"
wait_for Proj mgr "argv: \[--dangerously-load-development-channels\] \[server:amp-bridge\] \[--resume\]"
wait_for Proj amp "argv: \[threads\] \[continue\] \[T-"
wait_for Proj runner "argv: \[--no-tui\] \[--runner-id\] \[r1\]"
wait_for Proj restarted "argv: \[--model\] \[opus\] \[--add-dir\] \[/tmp\] \[--resume\] \[11111111-2222-3333-4444-555555555555\]"
pane Proj plain | grep -q FAKE && fail "plain shell must stay empty"
"$RA" revive --dry-run | grep -q "^services:" || true
"$RA" save >/dev/null
[ "$(jq -r '[.panes[] | select(.kind != "services")] | map(.alive_on) | unique | length' "$P")" = 1 ] || fail "revived panes are alive on the new server"
ok "(b) revive: 7 commands typed into the right panes, services action run"

# ---- (c) park and reopen
PARK=$(rx ls --json | jq -r '.sessions[] | select(.label == "Park Me") | .session_id')
echo y | "$RA" park "$PARK" >"$T/park.txt"
grep -q "Reopen later with" "$T/park.txt" || fail "park hint"
rx ls --json | jq -e '[.sessions[] | select(.label == "Park Me")] | length == 0' >/dev/null || fail "park must close the session"
jq -e '.windows[0].layout.split.before.block.resume | test("^claude --model opus --resume ")' "$T/templates/park-me.json" >/dev/null || fail "template resume"
"$RA" template-open park-me >/dev/null
wait_for "Park Me" busy "argv: \[--model\] \[opus\] \[--resume\]"
wait_for "Park Me" thread "argv: \[threads\] \[continue\] \[T-"
"$RA" template-open park-me | grep -q "already open" || fail "already-open guard"
ok "(c) park + reopen: conversations continue"

# ---- templates keep hand-written cmd/hold
PROJ=$(rx ls --json | jq -r '.sessions[] | select(.label == "Proj") | .session_id')
"$RA" template-save "$PROJ" >/dev/null
jq '(.. | objects | select(.label? == "oneshot")) |= (.cmd = "echo hold" | .hold = true)' "$T/templates/proj.json" >"$T/p.json" && mv "$T/p.json" "$T/templates/proj.json"
"$RA" template-save "$PROJ" >/dev/null
jq -e '[.. | objects | select(.label? == "oneshot")][0] | .cmd == "echo hold" and .hold == true' "$T/templates/proj.json" >/dev/null || fail "hold kept"
jq -e '[.. | objects | select(.label? == "iex")][0].cmd == "iex -S mix phx.server"' "$T/templates/proj.json" >/dev/null || fail "services cmd"
ok "templates: hand-written cmd/hold kept, services command"

"$REX" --autostart=false -S "$URL" do "$ROOT/tests/unit.lua" | tail -1
echo "all e2e checks passed"
