#!/bin/sh
# HOME alone does not isolate launchctl's GUI domain. Stub BOTH external entrypoints.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/rex-agents-setup.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/home & space/.config/rex" "$T/opt" "$T/Cellar/1/libexec"
cp -R "$ROOT/bin" "$ROOT/rex-agents" "$ROOT/examples" "$ROOT/setup.sh" "$T/Cellar/1/libexec/"
ln -s "$T/Cellar/1/libexec" "$T/opt/rex-agents"
cat >"$T/bin/rex" <<'EOF'
#!/bin/sh
[ "$1" = --autostart=false ] && [ "$2" = -S ] && [ "$3" = unix:///test-only.sock ] || exit 99
printf '%s\n' "$@" >>"$HOME/rex-calls"
EOF
cat >"$T/bin/launchctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$HOME/launch-calls"
case $1 in bootstrap) /usr/bin/plutil -lint "$3" ;; esac
EOF
chmod +x "$T/bin/rex" "$T/bin/launchctl"
export HOME="$T/home & space" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  REX_AGENTS_STABLE_ROOT="$T/opt/rex-agents" REX_AGENTS_REX="$T/bin/rex" \
  REX_AGENTS_SERVER=unix:///test-only.sock
unset REX_AGENTS_DIR REX_AGENTS_STATE XDG_STATE_HOME REX_AGENTS_CONFIG
CONF="$HOME/.config/rex"
PLIST="$HOME/Library/LaunchAgents/com.rex-agents.watch.plist"
RA="$ROOT/bin/rex-agents"
fail() { echo "FAIL: $*"; exit 1; }
printf '%s\n' '-- user config' 'local user_setting = true' >"$CONF/init.lua"
cp "$CONF/init.lua" "$T/original"
"$RA" setup --dry-run >/dev/null
cmp "$T/original" "$CONF/init.lua"
[ ! -e "$PLIST" ] && [ ! -e "$HOME/launch-calls" ] || fail 'dry-run mutated state'
"$RA" setup >"$T/setup-log"
[ "$(readlink "$CONF/rex-agents")" = "$T/opt/rex-agents/rex-agents" ] || fail 'not an opt link'
grep -q 'verify' "$T/setup-log" || fail 'verify not announced'
grep -q cli.lua "$HOME/rex-calls" || fail 'verify not run'
[ "$(plutil -extract ProgramArguments.3 raw "$PLIST")" = unix:///test-only.sock ] || fail 'watcher not pinned'
[ "$(plutil -extract EnvironmentVariables.HOME raw "$PLIST")" = "$HOME" ] || fail 'XML escaping'
cmp "$T/original" "$CONF"/init.lua.bak-*
cp "$CONF/init.lua" "$T/installed"
echo '-- keep this setting' >>"$CONF/rex-agents.local.lua"
"$RA" setup >/dev/null
cmp "$T/installed" "$CONF/init.lua"
grep -q 'keep this setting' "$CONF/rex-agents.local.lua" || fail 'settings overwritten'
echo 'ok - setup dry-run, pinned watcher, backups, idempotency, config preservation'

# Simulate brew upgrade without Homebrew or any real launchd job.
mkdir -p "$T/Cellar/2"
cp -R "$T/Cellar/1/libexec" "$T/Cellar/2/libexec"
ln -sfn "$T/Cellar/2/libexec" "$T/opt/rex-agents"
rm -rf "$T/Cellar/1"
[ -f "$CONF/rex-agents/core.lua" ] || fail 'upgrade broke Lua link'
"$CONF/bin/rex-agents" setup >/dev/null
"$RA" setup --uninstall --dry-run >/dev/null
[ -L "$CONF/rex-agents" ] && [ -e "$PLIST" ] || fail 'uninstall dry-run changed files'
"$RA" setup --uninstall >/dev/null
[ ! -L "$CONF/rex-agents" ] && [ ! -e "$PLIST" ] || fail 'uninstall left integration'
grep -q 'local user_setting = true' "$CONF/init.lua" || fail 'uninstall lost user config'
if grep -q rex-agents.actions "$CONF/init.lua"; then fail 'uninstall left managed actions'; fi
[ -f "$CONF/rex-agents.local.lua" ] || fail 'uninstall removed settings'
"$RA" setup --uninstall >/dev/null
echo 'ok - opt upgrade, uninstall dry-run, uninstall and repeated uninstall'

# A prior install.sh generated an unmarked plist with this exact script path.
cat >"$PLIST" <<EOF
<plist version="1.0"><dict><key>Label</key><string>com.rex-agents.watch</string>
<key>ProgramArguments</key><array><string>$T/bin/rex</string><string>--autostart=false</string>
<string>do</string><string>$(printf '%s' "$CONF/rex-agents/watch.lua" | sed 's/\&/\&amp;/g')</string><string>--all</string>
</array></dict></plist>
EOF
printf '%s\n' 'require("rex-agents.actions"){ keys = { open = false } }' >"$CONF/init.lua"
cp "$CONF/init.lua" "$T/custom"
"$RA" setup >/dev/null
grep -q 'Managed by rex-agents setup' "$PLIST" || fail 'legacy watcher not upgraded'
cmp "$T/custom" "$CONF/init.lua"
"$RA" setup --uninstall >/dev/null
cmp "$T/custom" "$CONF/init.lua"
: >"$CONF/init.lua"
"$RA" setup >/dev/null
sed 's/cmd+shift+b/cmd+shift+r/' "$CONF/init.lua" >"$T/edited"
cp "$T/edited" "$CONF/init.lua"
if "$RA" setup --uninstall >"$T/error" 2>&1; then fail 'edited managed block accepted'; fi
cmp "$T/edited" "$CONF/init.lua"
[ -e "$PLIST" ] || fail 'refusal partially uninstalled'
echo 'ok - existing require preserved; modified managed block refuses before mutation'

# A fresh HOME with unrelated destinations must not lose them or load anything.
export HOME="$T/conflict"
mkdir -p "$HOME/.config/rex/rex-agents"
if /bin/sh "$ROOT/install.sh" >"$T/error" 2>&1; then fail 'foreign directory overwritten'; fi
[ ! -e "$HOME/launch-calls" ] || fail 'loaded watcher on conflict'
export HOME="$T/no-settings"
mkdir -p "$HOME/.local/state/rex-agents"
echo '{"panes":{}}' >"$HOME/.local/state/rex-agents/panes.json"
if "$RA" setup >"$T/error" 2>&1; then fail 'state without settings accepted'; fi
[ ! -e "$HOME/.config/rex" ] || fail 'missing-settings guard mutated config'
"$RA" setup --force >/dev/null
test -f "$HOME/.local/state/rex-agents/"panes.before-install-*.json
echo 'ok - foreign destinations and saved state protected; force backs up state'
