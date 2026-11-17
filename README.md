# rex-agents

Bring Claude Code and Amp conversations back after a [Rex](https://www.superlogical.com/rex/)
server restart. Rex restores your tabs and splits; rex-agents remembers the programs in them.
Press **⌘⇧B**, select the panes to resume, and continue where you left off.

Runs as a small Lua extension inside Rex. No hub, Python or Node required.
Viewers, labelled programs, service actions and project templates are optional.

## Install

Requirements: **macOS**, **Rex 0.1.0-preview.18 or newer** (tested on preview.18 and preview.20),
and **fzf** for interactive pickers. Claude Code and/or Amp must already be installed.
Process inspection uses macOS `ps`, `lsof` and `osascript`; Unix socket probes use `/usr/bin/nc`.

### Homebrew

The formula lives in this repository, following the same tap layout as chief-of-staff.
Until a tagged release is published, it is **HEAD-only**:

```sh
brew tap oliver-kriska/rex-agents https://github.com/oliver-kriska/rex-agents
brew install --HEAD rex-agents
```

These commands become available once the repository and formula are published. From a **Rex
pane**, run:

```sh
rex-agents setup --dry-run
rex-agents setup
rex --autostart=false -S "$REX_SERVER" config reload
```

Outside a Rex pane, pass `rex-agents setup --server ENDPOINT`. Setup pins the watcher to that
server; it never starts or restarts Rex and does not type into panes.

### Git clone

```sh
git clone https://github.com/oliver-kriska/rex-agents.git
cd rex-agents
./install.sh --dry-run
./install.sh
```

Run these inside a Rex pane too, or pass `--server ENDPOINT`. `install.sh` uses the same setup.
Add `~/.config/rex/bin` to your PATH to use the CLI from other terminals.

### What setup changes

Setup prints its plan first, then:

- links the Lua module and CLI into `~/.config/rex/`;
- copies `examples/rex-agents.local.lua` only when settings are absent;
- backs up `init.lua` and adds an idempotent, marked `require("rex-agents.actions"){ keys = … }`
  block; an existing require line is kept, including custom keys;
- backs up saved panes and its previous plist, then installs and loads
  `~/Library/LaunchAgents/com.rex-agents.watch.plist`;
- runs `verify`. On a fresh install, it may report that the first watcher save is still pending.

Homebrew links point to the stable `opt/rex-agents/libexec` path, not a versioned Cellar path.
They survive upgrades. The running watcher picks up new Lua code when it next starts; rerun
setup after an upgrade to reload the watcher immediately (without restarting Rex).

Setup refuses unrelated files/links and modified managed blocks before changing anything.
To customize the inserted key bindings, remove its two marker comments first; the remaining
require line is yours. If saved state exists without settings, restore your settings first;
`--force` explicitly accepts the example settings instead. Settings and templates are never
overwritten. The old install.sh watcher is recognised by its label and script path, backed up
and upgraded. Before switching between clone and Homebrew installations, uninstall the old integration.

```sh
rex-agents setup --uninstall --dry-run
rex-agents setup --uninstall
```

Uninstall removes only its unchanged init block, links and watcher. It keeps settings,
templates, logs, backups and saved state. User-written require lines need manual removal.
Run this **before** `brew uninstall rex-agents` or deleting the checkout, then reload Rex config.

## Use

**⌘⇧B · Agents: Bring Back After Restart** lists saved panes whose foreground program is now
an idle shell. Enter retypes the selected commands. Nothing resumes automatically.

```sh
rex-agents save
rex-agents revive --dry-run
rex-agents revive --pick
rex-agents status
rex-agents status --json
rex-agents verify
rex-agents verify --against /path/to/panes.before-install.json
```

Claude Code resumes with its launch flags and `--resume SESSION_ID`. Amp resumes with
`amp threads continue THREAD_ID`; `--no-tui` runners keep their own arguments.

`status` covers agents and every configured pane kind, including missing panes and reasons a
pane cannot resume. States include `running`, `not running`, `busy (different program)`,
`cannot resume: REASON`, `pane missing`, and `already running (…)` for labelled programs.
`verify` checks commands, helper fields, watcher health and save age. With `--against`, it also
reports lost entries and changed commands. Closed panes and exited programs produce warnings;
an unrecognised running program or invalid saved state produces an error (exit 1).

After a restart, one macOS notification says **“N panes can be brought back — press ⌘⇧B”**.
`notify = false` in local settings disables it. The watcher remembers the notified server in
`notified.json`, so restarting just the watcher does not repeat it. Panes still starting at the
first save are not counted, and labelled programs already running elsewhere are excluded.

## Optional features

All settings live in `~/.config/rex/rex-agents.local.lua`, a Lua file returning a table.
See [the commented example](examples/rex-agents.local.lua). Every key is optional.

### Viewers, labelled programs and service panes

All three lists are empty by default. For example:

```lua
return {
  viewers = { "btop", "lazygit" },
  labelled = {
    api = { cwd_suffix = "/my-app", cmd = { "mix", "phx.server" } },
    hub = { cwd_suffix = "/my-hub", cmd = { "/usr/local/bin/my-hub", "start" },
      running = { socket = "~/Library/Application Support/my-hub/hub.sock" }, ready = true },
  },
  services = { labels = { server = "mix phx.server", tunnel = true }, action = "start_services" },
}
```

Viewers resume with their arguments. Labelled panes match label + cwd suffix and use the
**current configured command**, not a stale saved command. Service panes run the named
init.lua action once per session with an idle service pane; a `true` command records the
running program's arguments for templates. Service actions are user-owned code.

Labelled programs start first, then services, then agents and viewers. Before starting a
labelled command, rex-agents searches machine-wide process argv for a whole-argument prefix
match. An existing copy is skipped, omitted from the picker and reported as
`already running (pid N, in SESSION / PANE)` when its pane is known. Template-open and
start-pending apply the same check when their complete command matches a labelled entry.

Wrappers that exec a different runtime cannot be found by argv. Set `running.socket` to
override that check: the Unix stream socket must **accept a connection**, not merely exist.
No payload is sent. A stale socket is not running. This checks reachability, not application
health, and reports `already running (hub.sock answers)` without a PID or pane attribution.

`ready = true` waits up to 30 seconds for the running check after launch. Alternatively,
`ready = { path = "~/path/to/ready", timeout = 30 }` waits for path existence. If that path is
the configured running socket, it must accept a connection. A timeout warns and continues;
an already-running program is ready immediately.

`status` and `verify` warn if a labelled program runs in the wrong pane, a configured label
matches no pane, or a saved command differs from config. Finding it elsewhere does not save
it under that other pane. Socket-only checks cannot attribute a process to a pane.

### Hub names (opt-in)

Add this one line inside the local settings table to enable agent names:

```lua
hub = true,
```

When enabled, commands started by revive, template-open and start-pending receive
`HUB_NAME=<name>`. Names persist in `panes.json` and templates and are unique among live panes.
Priority: an existing `HUB_NAME`, a user-set Claude Code session name, a non-generic pane
label, then `<session>-<kind>-<last 6 block ID characters>`. Collisions add the session name.
Names use `[A-Za-z0-9][A-Za-z0-9._-]*` and have at most 64 characters.

Status then adds a hub column: `ok` means the environment matches, `restart pending` means
the running agent has no `HUB_NAME`, and `runs as NAME` means it has a different one. Already
running processes keep their environments. Hub names are validated only when enabled.

Every enabled save writes a private (mode 600), atomic `~/.local/state/rex-agents/names.json`:

```json
{
  "version": 1,
  "server": "<server instance_id>",
  "saved_at": 1794900000,
  "blocks": {
    "<block id>": { "hub_name": "worker-demo", "kind": "claude", "session": "Demo",
                    "session_id": "<session id>", "pids": [10001, 10002] }
  }
}
```

Only running agents are listed. `pids` includes the pane's foreground process and the
relaunched Claude Code child. Version 1 is unchanged for chief v0.1.0-pre.9 clients.
Turning hub integration off removes this map on the next successful save and stops generated
prefixes, hub metadata, columns and validation. Explicit commands and inherited environments
remain user-controlled; rex-agents does not strip a manually supplied `HUB_NAME`.

**chief client rules (v0.1.0-pre.9):** both `hub mcp` and CLI commands resolve names in order:
`--as`, `HUB_NAME`, then `blocks[$REX_BLOCK]` in names.json. They refuse the file unless it is
a plain user-owned file with no group/other mode bits, version 1, saved within 10 minutes and
no more than 1 minute in the future. A listed PID must be a client ancestor; all intervening
processes must be shells or launchers. Each refusal prints a one-line reason. This lookup
reads only names.json plus one `ps`.

### Project templates and parking

**⌘⇧T · Agents: Open Project Template** opens fresh agents or continues parked conversations.
Palette actions save a session/tab as a template or park a session. Parking warns about busy
Claude turns and asks before closing. Templates are hand-editable JSON under
`~/.config/rex/templates/NAME.json`:

```json
{
  "name": "My Project",
  "windows": [{ "label": "Agents", "layout": {
    "split": { "direction": "horizontal", "ratio": 0.5,
      "before": { "block": { "label": "manager", "cwd": "~/src/app", "cmd": "claude",
                               "resume": "claude --resume <session-id>" } },
      "after": { "block": { "label": "server", "cwd": "~/src/app", "cmd": "mix phx.server",
                              "hold": true } }
    }
  } }]
}
```

`cmd` starts fresh; `resume` continues; `hold` types without enter. Optional `hub_name` is used
only with `hub = true`; taken names get a session prefix. Saving preserves handwritten
commands/hold for labelled panes it cannot recognise.

```sh
rex-agents template-save SESSION_ID NAME --window WINDOW_ID
rex-agents template-open NAME --fresh
rex-agents template-list
rex-agents park SESSION_ID NAME
rex-agents tab-to-session SESSION_ID WINDOW_ID NAME
rex-agents start-pending NAME
```

## Internals and safety

`core.lua` classifies, saves and restores panes; `cli.lua` exposes commands; `actions.lua`
registers keys; `watch.lua` saves at startup, every two minutes and 20 seconds after process
changes. `procargs.js` reads exact argv via macOS sysctl using osascript's JavaScript bridge.
Claude session IDs come from `~/.claude/sessions/<pid>.json`, including relaunched children;
launch flags come from argv or `CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS`. Only that variable
and (with hub enabled) `HUB_NAME` are read from process environments. Amp thread IDs come from
open `threads/T-….log` files via `lsof`. These agent internals may change upstream.

`panes.json` maps block IDs to commands and Rex server instance IDs. Saves are atomic, with
a `panes.prev.json` backup. A save is skipped if no sessions are visible or Rex restarts during
the scan. An idle shell drops its entry only if it ran on the current server; entries survive
server restarts. Missing panes are kept for `keep_missing` seconds (default one week).

Revive rechecks every pane immediately before typing and waits up to 10 seconds for starting
shells. It never types into a busy program or a shell nested inside another shell. Floating
panes are not recorded. In-memory program state cannot be restored.

Every test client is pinned with `-S`; this avoids preview.18's fallback to the home server
when an environment-selected server is unavailable (fixed upstream in preview.19).
On preview.20, newly created block ownership does not prevent the `write` used by start-pending.

Labelled launches share a `labelled-start.lock`. Unconfirmed launches warn and release it
after 10 seconds (or the running-readiness timeout). Locks at least two minutes old expire.
External starts, separate state directories and readiness waits longer than the lease can
race this check. Strict singleton enforcement belongs in the program itself. Service actions
must avoid duplicates themselves. Nothing here stops or restarts a Rex server.

Test overrides: `REX_AGENTS_STATE`, `REX_AGENTS_TEMPLATES`, `REX_AGENTS_CLAUDE_SESSIONS`,
`REX_AGENTS_CONFIG`, `REX_AGENTS_SERVER`, `REX_AGENTS_REX`, `REX_AGENTS_WATCH_LABEL` (`-` skips
launchd inspection), and `REX_AGENTS_NOTIFY_CMD` (called as `CMD TITLE TEXT`). Homebrew supplies
`REX_AGENTS_STABLE_ROOT` to setup.

## Tests

```sh
tests/e2e.sh
REX_BIN=/path/to/rex tests/e2e.sh
sh tests/setup.sh
HOMEBREW_NO_AUTO_UPDATE=1 brew ruby tests/formula.rb   # local packaging only; no tap/install
# Without Rex: Lua 5.1 and the test-only dkjson 2.8 module
REX_AGENTS_CONFIG=/nonexistent lua tests/unit-runner.lua
```

E2e requires `cc`, `jq`, `python3` and Rex; it runs the unit suite too. It starts only private
throwaway servers and stops them with SIGTERM to verified test-owned PIDs. Fake agents cover
save/restart/revive, templates, readiness, duplicate guards and hub opt-in/out. Setup tests use
a disposable HOME **and stub launchctl and Rex**; HOME alone does not isolate launchd.
macOS CI runs the same unit suite without Rex and the setup tests. E2e is tested locally on
preview.18 and preview.20.

## License

[MIT](LICENSE), copyright Oliver Kriska.
