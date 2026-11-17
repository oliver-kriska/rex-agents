#!/bin/sh
# End-to-end test on a THROWAWAY Rex server. Never touches your own server:
#   - starts its own `rex server run` on a private socket, with its own state dir and config
#   - pins every rex call with -S (REX_SERVER alone falls back to the home server when the
#     named server is down)
#   - "restarts" by sending SIGTERM to that server's PID only, after checking its command line
#   - runs fake `claude` / `amp` binaries (tests/fake.c), never the real ones
#
# Covers: save → server restart → revive; park → reopen with conversations; template round trip;
# HUB_NAME names (chosen once, kept across restart/revive/park, made unique on template-open).
# Usage: tests/e2e.sh            (needs cc, jq, fzf not required)
#        REX_BIN=/path/to/rex tests/e2e.sh   (test another Rex version)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/rex-agents-e2e.XXXXXX")
SOCK="/tmp/rex-agents-e2e-$$.sock" # unix socket paths must stay short
URL="unix://$SOCK"
# REX_BIN picks the Rex binary (e.g. a downloaded preview not yet running as your server). The test
# server, every client call and bin/rex-agents (through $T/bin/rex, first on PATH) all use it.
REX=${REX_BIN:-$(command -v rex || echo "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex")}
SERVER_PID=
EXTRA_PID=

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
stop_extra() {
  [ -n "$EXTRA_PID" ] || return 0
  if ps -o comm= -p "$EXTRA_PID" | grep -Fq "$T/bin/hub-server"; then
    kill -TERM "$EXTRA_PID"
    wait "$EXTRA_PID" 2>/dev/null || true
  fi
  EXTRA_PID=
}
cleanup() { stop_extra; stop_server; rm -f "$SOCK"; rm -rf "$T"; }
trap cleanup EXIT INT TERM

# ---- environment: fakes first on PATH, private dirs, a zsh that reads none of your rc files
mkdir -p "$T/bin" "$T/state" "$T/cfg" "$T/agents" "$T/templates" "$T/claude" "$T/amp/threads" "$T/zdot" "$T/w/dir with space" "$T/w/hub-live" "$T/w/plain"
cc -O0 -o "$T/bin/claude" "$ROOT/tests/fake.c"
cp "$T/bin/claude" "$T/bin/amp"
cp "$T/bin/claude" "$T/bin/hub-server"
cp "$T/bin/claude" "$T/bin/btop"
ln -s "$REX" "$T/bin/rex"
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
  local e = io.open("$T/events.txt", "a"); e:write("services\n"); e:close()
end }
EOF
cat > "$T/local.lua" <<EOF
return {
  labelled = { hub = { cwd_suffix = "/hub-live", cmd = { "$T/bin/hub-server", "start", "two words", "$T/ready" },
    ready = { path = "$T/ready", timeout = 5 } } },
  services = { labels = { iex = "iex -S mix phx.server" }, action = "e2e_services" },
}
EOF
unset REX_SESSION REX_BLOCK REX_CLIENT
export ZDOTDIR="$T/zdot" PATH="$T/bin:$PATH" REX_SERVER="$URL" REX_AGENTS_SERVER="$URL" \
  REX_AGENTS_STATE="$T/agents" REX_AGENTS_TEMPLATES="$T/templates" REX_AGENTS_CLAUDE_SESSIONS="$T/claude" \
  REX_AGENTS_CONFIG="$T/local.lua" FAKE_AMP_DIR="$T/amp" REX_AGENTS_WATCH_LABEL=- FAKE_EVENTS="$T/events.txt"
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
echo "# $("$REX" version | head -1)"

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
    v(v(b("hub", W .. "/hub-live", "$T/bin/hub-server start 'two words' $T/ready"), b("iex", W .. "/plain", nil)),
      v(b("restarted", W .. "/plain", "CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS='--model opus --add-dir /tmp' claude --resume 11111111-2222-3333-4444-555555555555"),
        v(b("plain", W .. "/plain", nil), b("oneshot", W .. "/plain", "amp -x 'one shot'"))))) } } }))
assert(rex.call("session.create", { label = "Park Me", initial_windows = {
  { window_label = "Work", layout = h(b("busy", W .. "/plain", "FAKE_STATUS=busy claude --model opus"), b("thread", W .. "/plain", "amp")) } } }))
assert(rex.call("session.create", { label = "Hub Names", initial_windows = {
  { window_label = "Names", layout = h(
    h(b("named", W .. "/plain", "FAKE_NAME='worker chief 2' claude"), b("shell", W .. "/plain", "FAKE_NAME=auto-x FAKE_NAME_SOURCE=derived claude")),
    h(b("mgr", W .. "/plain", "claude"), b("envd", W .. "/plain", "HUB_NAME=from-env claude"))) } } }))
EOF
rx do "$T/fixture.lua" >/dev/null
wait_for Proj mgr "^session "
wait_for Proj amp "^thread "
wait_for "Park Me" busy "^session "
wait_for "Hub Names" envd "^session "

# ---- save
"$RA" save | grep -q "saved 12 panes" || { jq -c "[.panes[].label]" "$T/agents/panes.json"; fail "expected 12 saved panes"; }
P="$T/agents/panes.json"
jq -e '[.panes[] | select(.label == "mgr")][0].revive | index("do the thing") == null and .[1] == "--dangerously-load-development-channels" and .[2] == "server:amp-bridge" and .[3] == "--resume"' "$P" >/dev/null \
  || fail "quoted prompt must be dropped, flags kept"
jq -e '[.panes[] | select(.label == "restarted")][0].fresh == ["claude","--model","opus","--add-dir","/tmp"]' "$P" >/dev/null || fail "/restart hint flags"
jq -e '[.panes[] | select(.label == "runner")][0].revive == ["amp","--no-tui","--runner-id","r1"]' "$P" >/dev/null || fail "amp runner"
jq -e '[.panes[] | select(.label == "oneshot" or .label == "plain")] | length == 0' "$P" >/dev/null || fail "one-shot amp and plain shells are not saved"
ok "save: 12 panes, exact argv, hint flags, runner, skips"

# ---- hub names, chosen on the first save
hub() { jq -r --arg s "$1" --arg l "$2" '[.panes[] | select(.session == $s and .label == $l)][0].hub_name' "$P"; }
expect_hub() { got=$(hub "$1" "$2"); echo "$got" | grep -Eq "^$3\$" || fail "hub name of $1/$2: got $got, want $3"; }
expect_hub "Hub Names" named "worker-chief-2"           # 1: Claude session name you set
expect_hub "Hub Names" shell "hub-names-claude-[0-9a-z]{6}" # 3: derived name, generic label
expect_hub "Hub Names" mgr "mgr"                         # 2: label (sessions are named in order)
expect_hub Proj mgr "proj-mgr"                           #    taken → session name in front
expect_hub "Hub Names" envd "from-env"                   # 0: HUB_NAME it already runs with
expect_hub Proj amp "proj-amp-[0-9a-z]{6}"
expect_hub Proj runner "runner"
expect_hub "Park Me" busy "busy"
jq -e '[.panes[] | select(.kind == "services" or .kind == "labelled") | .hub_name] | all(. == null)' "$P" >/dev/null || fail "only agents get hub names"
jq -e '[.panes[].hub_name | select(.)] | length == (unique | length)' "$P" >/dev/null || fail "hub names must be unique"
jq -e '[.panes[] | keys[] | select(startswith("_"))] | length == 0' "$P" >/dev/null || fail "helper fields leaked into panes.json"
names() { jq -S '[.panes | to_entries[] | {b: .key, h: .value.hub_name}] | sort_by(.b)' "$P"; }
names >"$T/names1.json"
ok "hub names: session name, label, block id, collisions, env"

# ---- status: started by hand, so only the pane started with HUB_NAME has it
st() { "$RA" status --json | jq -r --arg s "$1" --arg l "$2" '[.panes[] | select(.session == $s and .label == $l)][0].state'; }
[ "$(st "Hub Names" envd)" = ok ] || fail "status: envd runs with its name"
[ "$(st Proj mgr)" = "restart pending" ] || fail "status: mgr is restart pending"
[ "$("$RA" status --json | jq '[.panes[]] | length')" = 12 ] || fail "status lists agents, labelled and services"
"$RA" status --json | jq -e '[.panes[] | select(.session_id == null or .block_id == null)] | length == 0' >/dev/null || fail "status rows carry session and block ids"
"$RA" status | grep -q "running agent(s) have no HUB_NAME yet" || fail "status footer"
"$RA" verify >/dev/null || { "$RA" verify; fail "verify after the first save"; }
cp "$P" "$T/before-restart.json"
ok "status: ok / restart pending; verify passes"
# ---- (a) restart the server: panes come back as empty shells under the same block IDs
OLD_SERVER=$(jq -r .server "$P")
stop_server
rm -f "$T/ready"
: >"$T/events.txt"
start_server

# ---- the watcher's notice after the restart: one per server instance, none with notify = false
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$1" "$2" >>"%s/notified.txt"\n' "$T" >"$T/notify.sh"
chmod +x "$T/notify.sh"
: >"$T/notified.txt"
sed 's/^return {/return { notify = false,/' "$T/local.lua" >"$T/quiet.lua"
watch_once() { # watch_once CONFIG: run the watcher until it has decided on the notice, then stop it
  REX_AGENTS_CONFIG="$1" REX_AGENTS_NOTIFY_CMD="$T/notify.sh" "$REX" --autostart=false -S "$URL" do "$ROOT/rex-agents/watch.lua" --all interval=3600 soon=3600 >"$T/watch.log" 2>&1 &
  W=$!
  i=0; until grep -q "restart notice: " "$T/watch.log"; do
    i=$((i + 1)); [ $i -lt 100 ] || { cat "$T/watch.log"; fail "watcher did not save"; }; sleep 0.2
  done
  kill -TERM "$W"; wait "$W" 2>/dev/null || true
}
as_before_restart() { jq --arg s "$OLD_SERVER" '.server = $s' "$P" >"$T/p.json" && mv "$T/p.json" "$P"; }
watch_once "$T/quiet.lua"
[ ! -s "$T/notified.txt" ] || fail "notify = false: no notification"
as_before_restart
watch_once "$T/local.lua"
[ "$(cat "$T/notified.txt")" = "rex-agents|12 panes can be brought back — press ⌘⇧B" ] || { cat "$T/notified.txt" "$T/watch.log"; fail "one notification after the restart, including services"; }
grep -q "restart notice: sent: 12 panes" "$T/watch.log" || fail "watcher logs the notice"
watch_once "$T/local.lua"
as_before_restart # a watcher that restarts before its own save under the new server: notified.json says done
watch_once "$T/local.lua"
[ "$(wc -l <"$T/notified.txt")" -eq 1 ] || { cat "$T/notified.txt"; fail "the notice must not repeat for the same server"; }
[ "$(stat -f %Lp "$T/agents/notified.json")" = 600 ] || fail "notified.json must be private"
ok "restart notice: once per server, nothing typed, off with notify = false"

"$RA" save >/dev/null
[ "$(jq '.panes | length' "$P")" = 12 ] || fail "restart must keep every saved pane"
[ "$(jq -r .server "$P")" != "$OLD_SERVER" ] || fail "server id must change on restart"
[ "$("$RA" revive --dry-run | grep -vc "^services:")" = 11 ] || fail "11 panes must be revivable after the restart"
names | diff - "$T/names1.json" >/dev/null || fail "hub names must survive the restart"
[ "$(st Proj mgr)" = "not running" ] || fail "status after restart: not running"
"$RA" verify --against "$T/before-restart.json" >/dev/null || { "$RA" verify --against "$T/before-restart.json"; fail "verify --against after restart"; }
ok "(a) restart: 12 panes kept, new server id, same hub names"

# ---- a shell inside a shell counts as busy: revive skips that pane
bid_of() { rx block ls -s "$1" --json | jq -r --arg l "$2" '.blocks[] | select(.label == $l) | .block_id' | head -1; }
rx send -s Proj -b "$(bid_of Proj amp)" $'zsh\r'
i=0; until [ "$(rx block ls -s Proj --json >/dev/null; pane Proj amp | grep -c 'e2e %')" -ge 2 ] || [ $i -ge 50 ]; do i=$((i + 1)); sleep 0.2; done
"$RA" revive >"$T/revive0.txt"
[ "$(head -2 "$T/events.txt")" = "$(printf 'hub-server\nservices')" ] || { cat "$T/events.txt"; fail "hub ready, then services, before agents"; }
[ -e "$T/ready" ] || fail "hub readiness path was created"
grep -q "timed out" "$T/revive0.txt" && fail "hub readiness must succeed, not time out"
ok "revive order: waits for labelled readiness, then services, then agents"
grep -q "^skipped: Proj / Agents: pane is busy" "$T/revive0.txt" || { cat "$T/revive0.txt"; fail "nested shell must be skipped"; }
[ "$(grep -c '^started:' "$T/revive0.txt")" = 10 ] || { cat "$T/revive0.txt"; fail "expected 10 started next to the nested shell"; }
rx send -s Proj -b "$(bid_of Proj amp)" $'exit\r'
sleep 1
ok "revive re-checks each pane: a nested shell is skipped"

# ---- (b) revive everything
"$RA" revive >"$T/revive.txt"
[ "$(grep -c '^started:' "$T/revive.txt")" = 1 ] || { cat "$T/revive.txt"; fail "expected the skipped pane to start now"; }
grep -q "^services:" "$T/revive.txt" || fail "services action"
wait_for Proj mgr "argv: \[--dangerously-load-development-channels\] \[server:amp-bridge\] \[--resume\]"
wait_for Proj amp "argv: \[threads\] \[continue\] \[T-"
wait_for Proj runner "argv: \[--no-tui\] \[--runner-id\] \[r1\]"
wait_for Proj restarted "argv: \[--model\] \[opus\] \[--add-dir\] \[/tmp\] \[--resume\] \[11111111-2222-3333-4444-555555555555\]"
pane Proj plain | grep -q FAKE && fail "plain shell must stay empty"
wait_for Proj mgr "^hub=proj-mgr$"
wait_for Proj amp "^hub=proj-amp-"
wait_for Proj runner "^hub=runner$"
wait_for "Hub Names" named "^hub=worker-chief-2$"
wait_for "Hub Names" envd "^hub=from-env$"
wait_for "Hub Names" shell "^hub=hub-names-claude-"
"$RA" revive --dry-run | grep -q "^services:" || true
"$RA" save >/dev/null
[ "$(jq -r '[.panes[] | select(.kind != "services")] | map(.alive_on) | unique | length' "$P")" = 1 ] || fail "revived panes are alive on the new server"
names | diff - "$T/names1.json" >/dev/null || fail "hub names must survive the revive"
ok "(b) revive: 10 + 1 commands typed into the right panes with their HUB_NAME, services action run"

# ---- status after the revive: every agent runs with its name
"$RA" status --json | jq -e '[.panes[] | select(.kind == "claude" or .kind == "amp" or .kind == "amp-runner") | select(.state != "ok")] | length == 0' >/dev/null \
  || { "$RA" status; fail "status after revive: all ok"; }
# verify finds what the manual checks looked for
mkdir -p "$T/bad"
jq '(.panes | to_entries | map(select(.value.session == "Proj" and (.value.label == "amp" or .value.label == "runner"))) | map(.key)) as $k
    | .panes[$k[0]].hub_name = "dup" | .panes[$k[1]].hub_name = "dup" | .panes[$k[0]]._env_hub = "x"' "$P" >"$T/bad/panes.json"
jq '(.panes | to_entries | map(select(.value.label == "mgr" and .value.session == "Proj")) | .[0].key) as $b
    | .panes[$b].revive = ["claude", "--model", "other"]
    | .panes["block:gone"] = {kind: "claude", label: "gone", session: "Proj", revive: ["claude"]}' "$P" >"$T/bad/old.json"
REX_AGENTS_STATE="$T/bad" "$RA" verify --against "$T/bad/old.json" >"$T/verify.txt" 2>&1 && fail "verify must fail on a bad panes.json"
grep -q "hub name dup is used by 2 live panes" "$T/verify.txt" || { cat "$T/verify.txt"; fail "verify: duplicate hub name"; }
grep -q "helper field _env_hub" "$T/verify.txt" || fail "verify: leaked helper field"
grep -q "revive command changed: Proj" "$T/verify.txt" || fail "verify: changed revive command"
grep -q "gone since .*pane closed" "$T/verify.txt" || fail "verify: closed pane is a warning"
REX_AGENTS_WATCH_LABEL=e2e-no-such-watcher "$RA" verify >"$T/verify.txt" 2>&1 && fail "verify must fail without the watcher"
grep -q "watcher e2e-no-such-watcher is not loaded" "$T/verify.txt" || fail "verify: watcher"
ok "status after revive: all ok; verify catches duplicates, leaked fields, changed commands, missing watcher"

# ---- (c) park and reopen
PARK=$(rx ls --json | jq -r '.sessions[] | select(.label == "Park Me") | .session_id')
sed -i '' 's/"status":"idle"/"status":"busy"/' "$T"/claude/*.json  # revived fakes start idle; mark the turn busy
echo y | "$RA" park "$PARK" >"$T/park.txt"
grep -q "Reopen later with" "$T/park.txt" || fail "park hint"
grep -q "Still working" "$T/park.txt" || fail "park warns about a busy Claude turn"
rx ls --json | jq -e '[.sessions[] | select(.label == "Park Me")] | length == 0' >/dev/null || fail "park must close the session"
jq -e '.windows[0].layout.split.before.block.resume | test("^claude --model opus --resume ")' "$T/templates/park-me.json" >/dev/null || fail "template resume"
jq -e '.windows[0].layout.split.before.block.hub_name == "busy" and .windows[0].layout.split.after.block.hub_name == "thread"' "$T/templates/park-me.json" >/dev/null || fail "template hub names"
"$RA" template-open park-me >/dev/null
wait_for "Park Me" busy "argv: \[--model\] \[opus\] \[--resume\]"
wait_for "Park Me" thread "argv: \[threads\] \[continue\] \[T-"
wait_for "Park Me" busy "^hub=busy$"
"$RA" template-open park-me | grep -q "already open" || fail "already-open guard"
ok "(c) park + reopen: conversations continue, same hub names"

# ---- templates keep hand-written cmd/hold
PROJ=$(rx ls --json | jq -r '.sessions[] | select(.label == "Proj") | .session_id')
"$RA" template-save "$PROJ" >/dev/null
jq '(.. | objects | select(.label? == "oneshot")) |= (.cmd = "echo hold" | .hold = true)' "$T/templates/proj.json" >"$T/p.json" && mv "$T/p.json" "$T/templates/proj.json"
"$RA" template-save "$PROJ" >/dev/null
jq -e '[.. | objects | select(.label? == "oneshot")][0] | .cmd == "echo hold" and .hold == true' "$T/templates/proj.json" >/dev/null || fail "hold kept"
jq -e '[.. | objects | select(.label? == "iex")][0].cmd == "iex -S mix phx.server"' "$T/templates/proj.json" >/dev/null || fail "services cmd"
jq '(.. | objects | select(.label? == "mgr")) |= (.hub_name = "custom-mgr")' "$T/templates/proj.json" >"$T/p.json" && mv "$T/p.json" "$T/templates/proj.json"
"$RA" template-save "$PROJ" >/dev/null
jq -e '[.. | objects | select(.label? == "mgr")][0].hub_name == "custom-mgr"' "$T/templates/proj.json" >/dev/null || fail "hand-written hub name kept"
ok "templates: hand-written cmd/hold/hub_name kept, services command"

# ---- a template opened next to the session it was saved from: taken names get the new session's name
HUBS=$(rx ls --json | jq -r '.sessions[] | select(.label == "Hub Names") | .session_id')
"$RA" template-save "$HUBS" >/dev/null
jq '.name = "Hub Copy"' "$T/templates/hub-names.json" >"$T/h.json" && mv "$T/h.json" "$T/templates/hub-names.json"
"$RA" template-open hub-names --fresh >/dev/null
wait_for "Hub Copy" named "^hub=hub-copy-worker-chief-2$"
wait_for "Hub Copy" mgr "^hub=hub-copy-mgr$"
"$RA" save >/dev/null
# unique among live panes (the parked session's old blocks keep their names for a week; seen is older)
jq -e '([.panes[].seen] | max) as $m | [.panes[] | select(.seen == $m) | .hub_name | select(.)] | length == (unique | length)' "$P" >/dev/null \
  || { jq -c '[.panes[] | {session, label, hub_name, seen}]' "$P"; fail "hub names unique after template-open"; }
ok "template-open: taken hub names get the session name in front"

# ---- Claude Code relaunched itself (/restart, update): the session runs in a child process
cat > "$T/relaunch.lua" <<EOF
assert(rex.call("session.create", { label = "Relaunch", initial_windows = {
  { window_label = "R", layout = { block = { flavor = "com.superlogical.terminal.shell", label = "re",
    options = { cwd = "$T/w/plain", initial_input = "FAKE_RELAUNCH=1 CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS= claude --model opus --allowed-tools a --allowed-tools a\\r" } } } } } }))
EOF
rx do "$T/relaunch.lua" >/dev/null
wait_for Relaunch re "^session "
SID=$(pane Relaunch re | sed -n 's/^session //p' | head -1)
"$RA" save >/dev/null
jq -e --arg s "$SID" '[.panes[] | select(.session == "Relaunch")][0].revive == ["claude","--model","opus","--allowed-tools","a","--resume",$s]' "$P" >/dev/null \
  || { jq -c '[.panes[] | select(.session == "Relaunch")]' "$P"; fail "relaunched claude: session from the child, flags deduped, empty hint ignored"; }
ok "relaunched Claude Code: session id from the child process, repeated flags dropped"

# ---- names.json: running agents by block, with their processes; a broken sessions file still reads
cat > "$T/broken.lua" <<EOF
assert(rex.call("session.create", { label = "Broken", initial_windows = {
  { window_label = "B", layout = { block = { flavor = "com.superlogical.terminal.shell", label = "brk",
    options = { cwd = "$T/w/plain", initial_input = "FAKE_BROKEN=1 claude --model opus\\r" } } } } } }))
EOF
rx do "$T/broken.lua" >/dev/null
wait_for Broken brk "^session "
"$RA" save >/dev/null
jq -e '[.panes[] | select(.session == "Broken")][0].revive | index("--resume") != null' "$P" >/dev/null || fail "sessions file with a stray } must still give the session id"
N="$T/agents/names.json"
[ "$(stat -f %Lp "$N")" = 600 ] || fail "names.json must be private"
jq -e '.version == 1 and (.server | length) > 0 and (.blocks | length) > 0' "$N" >/dev/null || fail "names.json shape"
jq -e '[.blocks[].hub_name] | length == (unique | length)' "$N" >/dev/null || fail "names.json names unique"
RB=$(rx block ls -s Relaunch --json | jq -r '.blocks[0].block_id')
jq -e --arg b "$RB" '.blocks[$b].pids | length == 2' "$N" >/dev/null || { jq . "$N"; fail "relaunched claude lists both processes"; }
CHILD=$(jq -r --arg b "$RB" '.blocks[$b].pids[1]' "$N")
ps -o comm= -p "$CHILD" | grep -q claude || fail "second pid is the running child"
jq -e '[.blocks[] | select(.kind != "claude" and .kind != "amp" and .kind != "amp-runner")] | length == 0' "$N" >/dev/null || fail "names.json lists agents only"
ok "names.json: private, versioned, unique names, agent pids incl. the relaunched child; tolerant sessions parse"

# ---- tab-to-session + start-pending: the new session's blocks come from session.create (on
# preview.20 they start without an owner), and start-pending writes into them from another `rex do`
BRK=$(rx ls --json | jq -r '.sessions[] | select(.label == "Broken") | .session_id')
BWIN=$(rx window ls -s "$BRK" --json | jq -r '.windows[0].window_id')
"$RA" tab-to-session "$BRK" "$BWIN" Moved >/dev/null
wait_for Moved brk "claude --model opus --resume "
pane Moved brk | grep -q "^FAKE" && fail "tab-to-session must type the command, not run it"
"$RA" start-pending Moved | grep -q "^started brk" || fail "start-pending output"
wait_for Moved brk "argv: \[--model\] \[opus\] \[--resume\]"
jq -e '.Moved == null' "$T/agents/pending.json" >/dev/null || fail "start-pending clears what it started"
ok "tab-to-session + start-pending: typed into session.create blocks, then run"

# ---- labelled guard on template-open and pending starts, including commands in unlabelled panes
jq -n --arg cwd "$T/w/hub-live" --arg cmd "$T/bin/hub-server start 'two words' '$T/ready'" \
  '{name:"Guard", windows:[{label:"Work", layout:{block:{label:"hub", cwd:$cwd, cmd:$cmd}}}]}' >"$T/templates/guard.json"
"$RA" template-open guard >"$T/guard.txt"
grep -q "already running (pid .*in Proj / hub" "$T/guard.txt" || { cat "$T/guard.txt"; fail "template guard reports existing Rex location"; }
pane Guard hub | grep -q "hub-server" && fail "duplicate command must not even be staged"
"$RA" save >/dev/null
G=$(rx ls --json | jq -r '.sessions[] | select(.label == "Guard") | .session_id')
GW=$(rx window ls -s "$G" --json | jq -r '.windows[0].window_id')
"$RA" tab-to-session "$G" "$GW" PendingHub >/dev/null
"$RA" start-pending PendingHub >"$T/pending.txt"
grep -q "already running (pid" "$T/pending.txt" || { cat "$T/pending.txt"; fail "pending starts guard duplicates"; }
pane PendingHub hub | grep -q "hub-server" && fail "pending duplicate command must not be typed"
jq -e '.PendingHub | length == 1' "$T/agents/pending.json" >/dev/null || fail "skipped pending starts remain retryable"
ok "labelled duplicate guard: template-open and start-pending leave panes untouched"

# Move the test hub to an unlabelled pane on the private server.
rx send -s Proj -b "$(bid_of Proj hub)" $'\003'
sleep 0.5
rx send -s Proj -b "$(bid_of Proj plain)" "$T/bin/hub-server start 'two words' '$T/ready' --extra"$'\r'
wait_for Proj plain '^FAKE hub-server'
"$RA" save >/dev/null
jq -e '[.panes[] | select(.session == "Proj" and .label == "plain")] | length == 0' "$P" >/dev/null || fail "wrong-pane hub must not acquire a saved entry"
"$RA" status --json >"$T/status.json"
jq -e '.warnings | index("hub: runs in Proj/plain, not in its labelled pane") != null' "$T/status.json" >/dev/null || fail "status diagnoses wrong-pane hub"
"$RA" verify >"$T/verify.txt"
grep -q 'hub: runs in Proj/plain, not in its labelled pane' "$T/verify.txt" || fail "verify diagnoses wrong-pane hub"
"$RA" revive --dry-run >"$T/plan.txt"
grep -q '^skipped: hub: already running (pid .*in Proj / plain' "$T/plan.txt" || fail "revive excludes wrong-pane running hub"
# The picker uses plan.todo; assert that it has no labelled row rather than drive interactive fzf.
cat >"$T/plan.lua" <<EOF
package.path = "$ROOT/?.lua;" .. package.path
local A = require("rex-agents.core")
for _, t in ipairs(A.revive_plan().todo) do assert(not t.labelled, "duplicate offered to picker") end
EOF
rx do "$T/plan.lua" >/dev/null
ok "wrong-pane hub: reported by status/verify, excluded from revive picker, not saved there"

# A process outside Rex still blocks a launch; a near-match argv must not block one.
rx send -s Proj -b "$(bid_of Proj plain)" $'\003'
sleep 0.5
"$T/bin/hub-server" start 'two words' "$T/ready" --external >"$T/external.txt" &
EXTRA_PID=$!
sleep 0.2
"$RA" start-pending PendingHub >"$T/pending.txt"
grep -q "already running (pid $EXTRA_PID)" "$T/pending.txt" || { cat "$T/pending.txt"; fail "machine-wide duplicate detection"; }
stop_extra
"$T/bin/hub-server" starter 'two words' "$T/ready" >"$T/external.txt" &
EXTRA_PID=$!
sleep 0.2
"$RA" start-pending PendingHub >"$T/pending.txt"
grep -q '^started hub' "$T/pending.txt" || { cat "$T/pending.txt"; fail "different whole argv word must not match"; }
wait_for PendingHub hub '^FAKE hub-server'
jq -e '.PendingHub == null' "$T/agents/pending.json" >/dev/null || fail "successful pending launch clears retry"
stop_extra
ok "machine-wide guard: matches extra argv, rejects partial argument matches, retries safely"

# Stale saved commands are warnings; revive plans use current config, never the stale argv.
rx send -s PendingHub -b "$(bid_of PendingHub hub)" $'\003'
sleep 0.5
"$RA" save >/dev/null
jq '(.panes[] | select(.kind == "labelled")).revive = ["obsolete-hub", "start"]' "$P" >"$T/p.json" && mv "$T/p.json" "$P"
"$RA" verify >"$T/verify.txt"
grep -q 'saved revive differs from current config cmd' "$T/verify.txt" || fail "verify stale labelled cmd"
"$RA" revive --dry-run >"$T/plan.txt"
grep -q 'obsolete-hub' "$T/plan.txt" && fail "stale labelled command offered for revive"
grep -q 'hub-server start' "$T/plan.txt" || fail "current labelled config not offered"
sed 's/labelled = {/labelled = { absent = { cmd = { "e2e-absent-program" } },/' "$T/local.lua" >"$T/absent.lua"
REX_AGENTS_CONFIG="$T/absent.lua" "$RA" verify >"$T/verify.txt"
grep -q 'absent: configuration matches no pane' "$T/verify.txt" || fail "verify orphan configuration"
"$RA" revive >"$T/multi-revive.txt"
[ "$(grep -c '^started:' "$T/multi-revive.txt")" -eq 1 ] || { cat "$T/multi-revive.txt"; fail "multiple saved hub panes must start just one program"; }
wait_for Guard hub '^FAKE hub-server'
grep -q 'already running (pid' "$T/multi-revive.txt" || fail "revive must recheck after the first labelled launch"
rx send -s Guard -b "$(bid_of Guard hub)" $'\003'
sleep 0.5
ok "verify: stale labelled commands and unmatched configuration; revive uses current command"

# A readiness timeout warns and continues to the next program; hold still only stages text.
sed "s@ready = { path = \"$T/ready\", timeout = 5 }@ready = { path = \"$T/never-ready\", timeout = 1 }@" "$T/local.lua" >"$T/timeout.lua"
jq --arg cwd "$T/w/plain" '.name = "Timeout" | .windows[0].layout = {split:{direction:"horizontal", before:.windows[0].layout,
  after:{split:{direction:"vertical", before:{block:{label:"viewer",cwd:$cwd,cmd:"btop"}},after:{block:{label:"held",cwd:$cwd,cmd:"echo HELD",hold:true}}}}}}' \
  "$T/templates/guard.json" >"$T/templates/timeout.json"
REX_AGENTS_CONFIG="$T/timeout.lua" "$RA" template-open timeout >"$T/timeout.txt"
grep -q 'readiness timed out.*continuing' "$T/timeout.txt" || { cat "$T/timeout.txt"; fail "readiness timeout reported"; }
wait_for Timeout viewer '^FAKE btop'
wait_for Timeout held 'echo HELD'
pane Timeout held | grep -q '^HELD$' && fail "held command must not run"
"$RA" save >/dev/null
"$RA" status --json >"$T/status.json"
jq -e '[.panes[] | select(.session == "Timeout" and .label == "viewer")][0] | .kind == "btop" and .state == "running"' "$T/status.json" >/dev/null || fail "viewer status"
jq '(.panes[] | select(.session == "Proj" and .label == "mgr")) |= (del(.revive) | .note = "no session ID found")' "$P" >"$T/bad/panes.json"
# The pane is stopped only in the private fixture so status must use its saved unresumable entry.
rx send -s Proj -b "$(bid_of Proj mgr)" $'\003'
sleep 0.5
REX_AGENTS_STATE="$T/bad" "$RA" status --json >"$T/status.json"
jq -e '[.panes[] | select(.session == "Proj" and .label == "mgr")][0].state == "cannot resume: no session ID found"' "$T/status.json" >/dev/null || fail "unresumable reason"
jq -e '[.panes[] | select(.state == "pane missing")] | length > 0' "$T/status.json" >/dev/null || fail "missing saved panes included"
ok "readiness timeout continues; held commands stay staged; status includes viewers, missing and unresumable panes"

# Two clients can open different templates together, but must not launch two copies of the hub.
rx send -s Timeout -b "$(bid_of Timeout hub)" $'\003'
sleep 0.5
jq '.name = "ConcurrentA"' "$T/templates/guard.json" >"$T/templates/concurrent-a.json"
jq '.name = "ConcurrentB"' "$T/templates/guard.json" >"$T/templates/concurrent-b.json"
BEFORE=$(grep -c '^hub-server$' "$T/events.txt")
"$RA" template-open concurrent-a >"$T/a.txt" &
A_PID=$!
"$RA" template-open concurrent-b >"$T/b.txt" &
B_PID=$!
wait "$A_PID"
wait "$B_PID"
sleep 2.5
[ "$(grep -c '^hub-server$' "$T/events.txt")" -eq "$((BEFORE + 1))" ] || { cat "$T/a.txt" "$T/b.txt"; fail "concurrent clients started duplicate hubs"; }
cat "$T/a.txt" "$T/b.txt" | grep -Eq 'already running|labelled launch locked' || fail "concurrent loser explains the skip"
ok "concurrent template clients start exactly one labelled program"

"$REX" --autostart=false -S "$URL" do "$ROOT/tests/unit.lua" >"$T/unit.txt" || { cat "$T/unit.txt"; fail "unit tests"; }
tail -1 "$T/unit.txt"
echo "all e2e checks passed"
