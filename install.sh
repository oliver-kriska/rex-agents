#!/bin/sh
# Install rex-agents into ~/.config/rex (symlinks to this checkout) and start the watcher.
#
#   ./install.sh            install / update
#   ./install.sh --dry-run  print what would happen
#   ./install.sh --uninstall
#
# It never edits init.lua; it prints the line to add. It never touches the Rex server.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
LABEL=com.rex-agents.watch
OLD_LABEL=com.rex-agents-save   # the Python version's saver
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/rex-agents.log"
REX=$(command -v rex 2>/dev/null || true)
[ -n "$REX" ] || REX="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

run() {
  echo "+ $*"
  [ "$DRY" = 1 ] || "$@"
}

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  [ -L "$CONF/rex-agents" ] && rm "$CONF/rex-agents"
  [ -L "$CONF/bin/rex-agents" ] && rm "$CONF/bin/rex-agents"
  echo "Removed the watcher and the links. Your templates, $CONF/rex-agents.local.lua and the saved"
  echo "state (~/.local/state/rex-agents) are left in place. Remove the require line from init.lua."
  OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
  if [ -e "$OLD_PLIST.disabled" ]; then
    echo "To bring back the old saver: mv '$OLD_PLIST.disabled' '$OLD_PLIST' && launchctl bootstrap gui/$(id -u) '$OLD_PLIST'"
  fi
  exit 0
fi

[ -x "$REX" ] || { echo "rex not found"; exit 1; }

# 1. code
run mkdir -p "$CONF/bin" "$CONF/templates" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
run ln -sfn "$ROOT/rex-agents" "$CONF/rex-agents"
if [ -e "$CONF/bin/rex-agents" ] && [ ! -L "$CONF/bin/rex-agents" ]; then
  run mv "$CONF/bin/rex-agents" "$CONF/bin/rex-agents.bak-$(date +%Y%m%d%H%M%S)"
fi
run ln -sfn "$ROOT/bin/rex-agents" "$CONF/bin/rex-agents"

# 2. machine settings (only if there are none yet)
if [ ! -e "$CONF/rex-agents.local.lua" ]; then
  run cp "$ROOT/examples/rex-agents.local.lua" "$CONF/rex-agents.local.lua"
fi

# 3. watcher: keeps panes.json current; launchd restarts it whenever the Rex server restarts
if [ "$DRY" = 1 ]; then
  echo "+ write $PLIST and load it"
else
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml "$REX")</string>
    <string>--autostart=false</string>
    <string>do</string>
    <string>$(xml "$CONF/rex-agents/watch.lua")</string>
    <string>--all</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key><string>$(xml "$LOG")</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "+ watcher loaded ($LABEL), log: $LOG"
fi

# 4. retire the earlier Python saver, if present, so two savers don't write panes.json
OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
if [ -e "$OLD_PLIST" ]; then
  if [ "$DRY" = 1 ]; then
    echo "+ launchctl bootout gui/$(id -u)/$OLD_LABEL; mv $OLD_PLIST $OLD_PLIST.disabled"
  else
    launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true
    mv "$OLD_PLIST" "$OLD_PLIST.disabled"
    echo "+ retired $OLD_LABEL (plist kept as $OLD_PLIST.disabled)"
  fi
fi

cat <<EOF

Add this line to $CONF/init.lua (⌘⇧B revive, ⌘⇧T open a template, palette: save/park), then
run \`rex config reload\`:

    require("rex-agents.actions"){}

EOF
