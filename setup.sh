#!/bin/sh
# All destination checks happen before mutation. Never reload or restart the Rex server.
set -eu
ROOT=${REX_AGENTS_STABLE_ROOT:-$(cd "$(dirname "$0")" && pwd)}
CONF="$HOME/.config/rex"
STATE="${REX_AGENTS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/rex-agents}"
LABEL=com.rex-agents.watch
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/rex-agents.log"
SERVER=${REX_AGENTS_SERVER:-${REX_SERVER:-}}
DRY=0 UNINSTALL=0 FORCE=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --force) FORCE=1 ;;
    --server) shift; SERVER=${1:?--server needs an endpoint} ;;
    --help|-h)
      echo 'Usage: rex-agents setup [--dry-run] [--uninstall] [--force] [--server ENDPOINT]'
      echo 'Run inside a Rex pane, or pass --server. --force allows example settings over saved state.'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
die() { echo "$*" >&2; exit 1; }
run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
backup() { [ ! -f "$1" ] || cp -p "$1" "$1.bak-$(date +%Y%m%d%H%M%S)-$$"; }

# A fixed, digest-guarded Lua block: user edits (including key customizations) are never replaced.
BODY='require("rex-agents.actions"){ keys = { revive = "cmd+shift+b", open = "cmd+shift+t" } }'
DIGEST=$(printf '%s' "$BODY" | shasum -a 256 | cut -c1-12)
BEGIN="-- rex-agents:begin sha256:$DIGEST"
END='-- rex-agents:end'
INIT="$CONF/init.lua"
MANAGED=0 EXISTING=0
if [ -e "$INIT" ] || [ -L "$INIT" ]; then
  [ -f "$INIT" ] && [ ! -L "$INIT" ] || die "Refusing non-regular init.lua: $INIT"
  if grep -q -- '-- rex-agents:begin\|-- rex-agents:end' "$INIT"; then
    [ "$(grep -c -- '-- rex-agents:begin\|-- rex-agents:end' "$INIT")" = 2 ] || die 'Duplicate or malformed init.lua markers.'
    BLOCK=$(sed -n '/^-- rex-agents:begin/,/^-- rex-agents:end/p' "$INIT")
    EXPECTED=$(printf '%s\n%s\n%s' "$BEGIN" "$BODY" "$END")
    [ "$BLOCK" = "$EXPECTED" ] || die 'Managed init.lua block changed or malformed; keep your edits and remove its markers manually before setup.'
    MANAGED=1
  elif grep -q 'rex-agents.actions' "$INIT"; then
    EXISTING=1
  fi
fi
for dest in "$CONF/rex-agents" "$CONF/bin/rex-agents"; do
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    [ -L "$dest" ] || die "Refusing to replace non-symlink: $dest"
    target=$(readlink "$dest")
    case $dest in
      */bin/*) expected="$ROOT/bin/rex-agents" ;;
      *) expected="$ROOT/rex-agents" ;;
    esac
    [ "$target" = "$expected" ] || die "Link belongs to another install: $dest -> $target. Uninstall that version first."
  fi
done
if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] || die "Refusing non-regular plist: $PLIST"
  if ! grep -Fq '<!-- Managed by rex-agents setup -->' "$PLIST"; then
    # Adopt the old install.sh watcher only when its label and script path both match.
    [ "$(plutil -extract Label raw "$PLIST" 2>/dev/null)" = "$LABEL" ] &&
      [ "$(plutil -extract ProgramArguments.2 raw "$PLIST" 2>/dev/null)" = "do" ] &&
      [ "$(plutil -extract ProgramArguments.3 raw "$PLIST" 2>/dev/null)" = "$CONF/rex-agents/watch.lua" ] ||
      die "Existing watcher was not written by setup: $PLIST. Back it up and remove it before setup."
  fi
fi

if [ "$UNINSTALL" = 0 ]; then
  [ -n "$SERVER" ] || die 'Run setup inside a Rex pane, or pass --server ENDPOINT.'
  REX=${REX_AGENTS_REX:-$(command -v rex 2>/dev/null || true)}
  [ -n "$REX" ] || REX="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  [ -x "$REX" ] || die 'Rex not found; set REX_AGENTS_REX to its executable.'
  [ -f "$ROOT/rex-agents/core.lua" ] || die "Invalid installation root: $ROOT"
  if [ "$FORCE" = 0 ] && [ ! -e "$CONF/rex-agents.local.lua" ] && [ -s "$STATE/panes.json" ]; then
    die 'Saved state exists without local settings. Restore your settings first, or use --force to accept example settings.'
  fi
  echo "Plan: link modules and CLI from $ROOT; copy example settings only if missing."
  echo "Plan: back up and add actions to $INIT unless already configured."
  echo "Plan: back up saved panes and $PLIST; load watcher pinned to $SERVER; run verify."
else
  echo "Plan: unload $LABEL and remove its managed plist, links and unchanged init.lua block."
  echo 'Settings, templates, logs, backups and saved state will be kept.'
fi
[ "$DRY" = 0 ] || exit 0

if [ "$UNINSTALL" = 1 ]; then
  if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm "$PLIST"
  fi
  for dest in "$CONF/rex-agents" "$CONF/bin/rex-agents"; do
    [ ! -L "$dest" ] || rm "$dest"
  done
  if [ "$MANAGED" = 1 ]; then
    backup "$INIT"
    awk '/^-- rex-agents:begin/ {skip=1} !skip {print} /^-- rex-agents:end/ {skip=0}' "$INIT" >"$INIT.tmp-$$"
    cat "$INIT.tmp-$$" >"$INIT"
    rm "$INIT.tmp-$$"
  fi
  [ "$EXISTING" = 0 ] || echo 'Your existing rex-agents require line was left intact; remove it before reloading Rex config.'
  exit 0
fi

run mkdir -p "$CONF/bin" "$CONF/templates" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
run ln -sfn "$ROOT/rex-agents" "$CONF/rex-agents"
run ln -sfn "$ROOT/bin/rex-agents" "$CONF/bin/rex-agents"
[ -e "$CONF/rex-agents.local.lua" ] || run cp "$ROOT/examples/rex-agents.local.lua" "$CONF/rex-agents.local.lua"
if [ "$MANAGED" = 0 ] && [ "$EXISTING" = 0 ]; then
  backup "$INIT"
  printf '\n%s\n%s\n%s\n' "$BEGIN" "$BODY" "$END" >>"$INIT"
fi
BEFORE=
if [ -s "$STATE/panes.json" ]; then
  BEFORE="$STATE/panes.before-install-$(date +%Y%m%d%H%M%S)-$$.json"
  run cp -p "$STATE/panes.json" "$BEFORE"
fi
backup "$PLIST"
cat >"$PLIST.tmp-$$" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!-- Managed by rex-agents setup -->
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$(xml "$REX")</string><string>--autostart=false</string>
    <string>-S</string><string>$(xml "$SERVER")</string>
    <string>do</string><string>$(xml "$CONF/rex-agents/watch.lua")</string><string>--all</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$(xml "$HOME")</string>
    <key>REX_AGENTS_STATE</key><string>$(xml "$STATE")</string>
    <key>REX_AGENTS_CONFIG</key><string>$(xml "$CONF/rex-agents.local.lua")</string>
    <key>REX_AGENTS_SERVER</key><string>$(xml "$SERVER")</string>
    <key>REX_AGENTS_REX</key><string>$(xml "$REX")</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key><string>$(xml "$LOG")</string>
</dict></plist>
EOF
mv "$PLIST.tmp-$$" "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
run launchctl bootstrap "gui/$(id -u)" "$PLIST"
# No wait for a first save: an empty Rex session list is normal on a new install.
echo '+ rex-agents verify (a first watcher save may still be pending)'
REX_AGENTS_SERVER=$SERVER REX_AGENTS_REX=$REX REX_AGENTS_CONFIG="$CONF/rex-agents.local.lua" \
  "$ROOT/bin/rex-agents" verify ${BEFORE:+--against "$BEFORE"} || echo 'Verify reported problems; inspect them above and rerun rex-agents verify after the first save.'
echo 'Setup finished. Reload Rex config to activate the keys; ⌘⇧B brings back saved panes.'
