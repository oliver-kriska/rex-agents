# rex-agents

Bring Claude Code and Amp conversations back after a [Rex](https://www.superlogical.com/rex/)
server restart. Rex restores your tabs and splits; rex-agents remembers the programs in them.
Press **⌘⇧B**, select the panes to resume, and continue where you left off.

Runs as a small Lua extension inside Rex. No hub, Python or Node required.
Viewers, labelled programs, service actions and project templates are optional.

<!-- demo video -->
*Demo video coming soon: restart Rex → press ⌘⇧B → resume selected conversations.*

## Install

### Homebrew

Run in a **Rex pane** after installing [Rex](https://www.superlogical.com/rex/):

**Release preparation:** the stable formula targets v0.1.0 but still has a marked checksum
placeholder. Until the tag and real checksum are published, replace the install line below
with `brew install --HEAD rex-agents`. The placeholder cannot verify a download.

```sh
brew tap oliver-kriska/rex-agents https://github.com/oliver-kriska/rex-agents
brew install rex-agents
rex-agents setup
```

To inspect setup before making changes, run `rex-agents setup --dry-run`. Then reload the config
to activate the keys:

```sh
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
Add `~/.config/rex/bin` to your PATH to use the CLI from other terminals, and reload Rex config
as above. Keep the checkout: the installed Lua module and CLI are links to it.

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

### Uninstall

```sh
rex-agents setup --uninstall --dry-run
rex-agents setup --uninstall
```

Uninstall removes only its unchanged init block, links and watcher. It keeps settings,
templates, logs, backups and saved state. User-written require lines need manual removal.
Run this **before** `brew uninstall rex-agents` or deleting the checkout, then reload Rex config.

## Requirements

- **macOS** and **Rex 0.1.0-preview.18 or newer**. Tested: preview.18 (API 13) and preview.20
  (API 16); other versions are not covered by that claim.
- **fzf** for interactive pickers (installed by the formula; clone users can run `brew install fzf`).
- **Claude Code and/or Amp**, installed and available to your shell, to resume those agents.
- macOS `ps`, `lsof`, `osascript` and `/usr/bin/nc`. No separate Lua runtime is needed to use
  the extension; Rex runs its Lua. Python and a compiler are needed only for end-to-end tests.

## Quick start

1. Install and reload Rex config. Run Claude Code or Amp normally in tiled panes.
2. Run `rex-agents save` once to confirm recording; the watcher then keeps it current.
3. After your next Rex server restart, wait for the restored panes to reach their shell prompts.
4. Press **⌘⇧B**. All resumable command rows start selected. **Tab** toggles a row,
   **Enter** starts the selection, and **Esc** cancels.
5. Run `rex-agents status` or `rex-agents verify` if a pane is missing or cannot resume.

The watcher only records and notifies. It does not start programs after a restart.

## Revive, inspect and verify

**⌘⇧B · Agents: Bring Back After Restart** lists saved panes whose foreground program is now
an idle shell. Enter retypes the selected commands. It saves once before building the picker.
`revive --pick` opens the same picker; `revive --dry-run` only prints the plan. Plain `revive`
starts all eligible saved commands **without a picker**. Use it only when you want that.

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
a previously saved pane that still runs a program but is no longer recognised produces an error.
Invalid saved state or a missing watcher also produces an error (exit 1). It is not an inventory
of every unconfigured program on the machine.

### Restart notification

After a restart, one macOS notification says **“N panes can be brought back — press ⌘⇧B”**.
`notify = false` in local settings disables it. The watcher remembers the notified server in
`notified.json`, so restarting just the watcher does not repeat it. Panes still starting at the
first save are not counted, and labelled programs already running elsewhere are excluded.

## Optional features

All settings live in `~/.config/rex/rex-agents.local.lua`, a Lua file returning a table.
See [the commented example](examples/rex-agents.local.lua). Every key is optional.

### Labelled programs

Use a fixed command for a pane with a particular label, optionally limited by cwd suffix:

```lua
return {
  labelled = {
    api = { cwd_suffix = "/my-app", cmd = { "mix", "phx.server" } },
    hub = { cwd_suffix = "/my-hub", cmd = { "/usr/local/bin/my-hub", "start" },
      running = { socket = "~/Library/Application Support/my-hub/hub.sock" }, ready = true },
  },
}
```

The table key is the pane label. Labelled panes match label + cwd suffix and use the
**current configured command**, not a stale saved command. `cmd` is an argv array, not shell
text; use an absolute executable path for reliable duplicate detection. This feature does
not require hub integration, even if you name a pane `hub`.

During revive, labelled programs start first, then services, then agents and viewers. Before starting a
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

### Service panes

To delegate service startup to an action you already define in Rex's `init.lua`:

```lua
services = {
  labels = { server = "mix phx.server", tunnel = true },
  action = "start_services",
},
```

Revive runs `start_services` once per session that has an idle saved service pane. The strings
in `labels` become template commands; `true` records the running program's argv instead.
Opening a template runs those commands directly, not the action. Without `action`, revive
cannot start service panes.

**Service actions are not selectable rows in the revive picker.** Once you accept the picker,
configured service actions run even if you deselect all command rows. If only services are
eligible, no picker appears. `revive --dry-run` includes the service actions without running them.
Your action must check its own pane safety and prevent duplicate services.

### Viewers

```lua
viewers = { "btop", "lazygit" },
```

Viewer entries match the executable basename and resume with the recorded argv. The list is
empty by default. They receive no generated `HUB_NAME`. Programs not recognised as agents,
viewers, labelled programs or services are not recorded for revival.

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

`template-save` records the current layout and commands without closing anything. Omit `NAME`
to use the session name (or the tab name with `--window`); filenames are lowercase slugs.
`template-open NAME` uses saved `resume` commands when present; `--fresh` uses `cmd` instead.
It refuses to create another session with the template's name. Labelled commands start first;
other template commands follow in layout order.

`park` saves first, then asks whether to close the session (default **No**). Its busy warning
covers detected Claude Code turns, not every possible background job. Closing ends the programs;
only conversations with working resume commands can continue later.

`tab-to-session` **copies**, rather than moves, a tab into a new session. It stages saved
non-service commands without pressing Enter; guarded labelled commands are deferred entirely.
Inspect the new session, close the old tab yourself, then run `start-pending NAME`. That starts
labelled commands first and keeps failed entries for retry. Service panes need their own action
or manual startup. The old tab is never closed by `tab-to-session`.

## Configuration reference

`~/.config/rex/rex-agents.local.lua` returns a Lua table. Missing keys keep these defaults.
Lists extend defaults, and maps merge by key; an empty `shells` list does not remove defaults.
CLI invocations read settings anew. Rerun setup to restart the watcher after editing settings;
reload Rex config if its already-loaded actions need the new settings too.

| Key | Default | Meaning |
| --- | --- | --- |
| `hub` | `false` | Only literal `true` enables generated names and names.json. |
| `notify` | `true` | `false` disables restart notifications. |
| `keep_missing` | `604800` (one week) | Seconds to retain saved entries for missing panes. |
| `shells` | `{ "zsh", "-zsh", "bash", "-bash", "sh", "fish", "login" }` | Additional foreground executable names treated as shells. |
| `viewers` | `{}` | Executable basenames to record and restart with argv. |
| `labelled` | `{}` | Pane label → fixed-command entry, described below. |
| `services.labels` | `{}` | Pane label → template command string, or `true` to capture argv. |
| `services.action` | `nil` | Rex action name to invoke once per eligible session during revive. |

Each `labelled.LABEL` entry supports:

| Key | Default | Meaning |
| --- | --- | --- |
| `cmd` | Required | Nonempty argv array, e.g. `{ "/path/to/server", "start" }`. |
| `cwd_suffix` | `""` | Literal suffix match; omitted means any cwd. |
| `running` | `nil` | By default, search machine-wide argv for the `cmd` prefix. |
| `running.socket` | Required when `running` is set | Unix socket that must accept a connection; overrides argv matching. |
| `ready` | `nil` | No extra readiness gate. `true` waits for the running check; a table waits for `path`. |
| `ready.path` | Required for table form | File to wait for; if equal to `running.socket`, require a connection instead. `~/` expands to HOME. |
| `ready.timeout` | `30` | Seconds before warning and continuing; also 30 seconds for `ready = true`. |

Keep these files private. Commands, template contents, paths and agent identifiers are local
state, not project configuration to commit. There is no secret-redaction layer for command argv.

## Key bindings and palette actions

Setup adds this to `~/.config/rex/init.lua`:

```lua
require("rex-agents.actions"){ keys = { revive = "cmd+shift+b", open = "cmd+shift+t" } }
```

| Default key | Palette action | Effect |
| --- | --- | --- |
| ⌘⇧B | Agents: Bring Back After Restart | Save, show the revive picker, then start selected commands and service actions. |
| ⌘⇧T | Agents: Open Project Template | Pick a template and continue or start fresh. |
| None | Agents: Save Session as Template | Save every tab without closing. |
| None | Agents: Save Tab as Template | Save only the current tab. |
| None | Agents: Park Session (close, reopen later) | Save, then ask whether to close. |

The actions module takes `keys.revive` and `keys.open` (defaults above); `false` disables a
binding without removing the palette action. Its optional `bin` defaults to
`~/.config/rex/bin/rex-agents`. These are **init.lua options**, not local settings keys.
For custom keys, follow the managed-block instructions under [setup](#what-setup-changes),
then reload Rex config. Rex's own ⌘K switches sessions.

## CLI commands

Run inside Rex, or explicitly set `REX_AGENTS_SERVER` to the intended endpoint. `SESSION_ID`
and `WINDOW_ID` below refer to Rex IDs; `NAME` is a template or destination session name.

| Command | Effect |
| --- | --- |
| `setup [--dry-run] [--server ENDPOINT] [--force]` | Install integration; `--force` permits example settings when saved state exists. |
| `setup --uninstall [--dry-run]` | Remove integration, preserving user settings and state. |
| `save` | Record all recognised tiled panes now. |
| `revive [--pick\|--dry-run] [--save-first] [--pause]` | Restore eligible panes; without `--pick`, starts all. `--pause` waits for a key before exiting. |
| `status [--json]` | Show all recognised/saved pane kinds, running state, warnings and watcher health. |
| `verify [--against FILE]` | Check state and watcher; optionally compare with an earlier panes.json. |
| `template-list` | List template filename slugs. |
| `template-save SESSION_ID [NAME] [--window WINDOW_ID]` | Save the session or one tab as a template. |
| `template-open [NAME\|--pick] [--fresh]` | Open a new session; no name opens the picker. |
| `park SESSION_ID [NAME]` | Save a resumable template, then ask to close. |
| `tab-to-session SESSION_ID WINDOW_ID NAME` | Copy a tab into a new session and stage commands, without closing the original. |
| `start-pending NAME` | Start commands staged by tab-to-session; retry previously skipped entries. |
| `--help` | Show CLI usage. `setup --help` shows installer options. |

## How it works

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

| File | Purpose |
| --- | --- |
| `~/.local/state/rex-agents/panes.json` | Current snapshot and resumable commands. |
| `panes.prev.json` in the same directory | Previous snapshot. |
| `pending.json` in the same directory | Commands staged by tab-to-session, retained until successfully started. |
| `notified.json` in the same directory | Last server instance considered for a restart notification. |
| `names.json` in the same directory | Private hub-name map; only when hub is enabled. |
| `labelled-start.lock` in the same directory | Temporary directory serialising labelled launches. |
| `~/.config/rex/templates/*.json` | Hand-editable layouts and fresh/resume commands. |
| `~/Library/Logs/rex-agents.log` | Watcher saves, skipped saves and errors. |
| `~/Library/LaunchAgents/com.rex-agents.watch.plist` | Watcher registration, pinned to the selected Rex endpoint. |

`XDG_STATE_HOME` changes the default state parent directory. Setup creates timestamped backups
alongside files it replaces, including `panes.before-install-*.json` for `verify --against`.

## Safety and limits

**No automatic typing after a restart.** The watcher records and notifies; ⌘⇧B asks which
commands to restore. Explicit `revive`, template-open and start-pending commands can also start
programs, and tab-to-session stages text. Templates and local Lua settings are executable input:
review files from others before using them.

Direct command restoration rechecks each pane before typing and waits up to 10 seconds for
starting shells. It skips busy programs and shells nested inside another shell. Floating
panes are not recorded. These are process checks, not a parser of partially typed shell input;
leave target shell prompts empty before restoring. In-memory program state cannot be restored.

Inside Rex, the CLI pins `REX_SERVER` with `-S`; `REX_AGENTS_SERVER` overrides it. Setup requires
an endpoint and pins the watcher too. Without either variable, ordinary CLI commands use Rex's
default endpoint, so explicitly set `REX_AGENTS_SERVER` when operating outside Rex. All calls use
`--autostart=false`. Every e2e test client is pinned with `-S`; this avoids preview.18's fallback
to the home server when an environment-selected server is unavailable (fixed upstream in preview.19).
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

## Troubleshooting / FAQ

**⌘⇧B does nothing.** Reload Rex config after setup. Check for conflicting key bindings or
use the palette action. Make sure `fzf` is on PATH for the picker.

**“Nothing to bring back.”** Run `status` and `revive --dry-run`. The pane may already be
running, missing, unrecognised, or have no saved resume command. A shell that went idle before
the restart may have had its entry removed normally. Saving after the information is lost
cannot reconstruct the previous conversation.

**The watcher is not loaded or the save is old.** Run `verify`, inspect
`~/Library/Logs/rex-agents.log`, and check the endpoint used at setup. Rerun setup from the
intended Rex pane to reload the watcher. An empty session list deliberately skips saves.

**No notification.** Check `notify`, macOS notification permissions and the watcher log.
The first install is not a restart. Only the first eligible save after a server change counts;
no resumable panes means no notification, and a failed notification is not retried for that instance.

**An agent cannot resume.** `status` gives the reason. Claude Code session files and Amp's
open thread logs are upstream implementation details. Report the agent and Rex versions;
do not post your full state files or process environments.

**A labelled program is “already running,” or launch is unconfirmed.** For a wrapper that
execs another runtime, use `running.socket` and `ready = true`. A live socket proves connection
acceptance, not application health. Wrong-pane location reporting is available only for argv
matches. Abandoned launch locks expire after two minutes; do not remove an active launch's lock.

**Does this require a hub?** No. `hub = false` is the default; viewers, services and labelled
panes also default to empty. Enable only the features you use.

**Will it restore a closed session?** Revive needs the original pane IDs. Use park/templates
to close a project and reopen its conversations later.

## Contributing and tests

Keep the extension compatible with Rex's Lua 5.1 environment; use `rex.exec`, not `io.popen`
or `os.execute`, in extension code. The standalone test adapter is the only exception.
Changes should include tests and accurate CLI/config documentation. Never test against a live
work session. Open an issue or pull request with a minimal reproduction and tool versions;
redact commands, paths and conversation IDs before sharing output.

```sh
brew install lua@5.4 luarocks shellcheck luacheck actionlint
luarocks --lua-version=5.4 --lua-dir="$(brew --prefix lua@5.4)" --tree=/tmp/rex-agents-rocks install dkjson 2.8-2
REX_AGENTS_CONFIG=/nonexistent LUA_PATH='/tmp/rex-agents-rocks/share/lua/5.4/?.lua;;' \
  "$(brew --prefix lua@5.4)/bin/lua" tests/unit-runner.lua
git ls-files -z '*.sh' bin/rex-agents | xargs -0 shellcheck
luacheck rex-agents tests/*.lua examples/*.lua
actionlint
HOMEBREW_NO_AUTO_UPDATE=1 brew style Formula/rex-agents.rb
tests/e2e.sh
REX_BIN=/path/to/rex tests/e2e.sh
sh tests/setup.sh
HOMEBREW_NO_AUTO_UPDATE=1 brew ruby tests/formula.rb   # local packaging only; no tap/install
```

E2e requires `cc`, `jq`, `python3` and Rex; it runs the unit suite too. It starts only private
throwaway servers and stops them with SIGTERM to verified test-owned PIDs. Fake agents cover
save/restart/revive, templates, readiness, duplicate guards and hub opt-in/out. Setup tests use
a disposable HOME **and stub launchctl and Rex**; HOME alone does not isolate launchd.
macOS CI runs the same unit suite without Rex and the setup tests. E2e is tested locally on
preview.18 and preview.20. CI does not download Rex: no unattended, version-pinned distribution
is configured. It runs ShellCheck, Luacheck (Lua 5.1 globals), actionlint, Homebrew style, the
packaging test and a strict metadata audit in a disposable CI tap. None of those checks verifies
the v0.1.0 tarball checksum; the release install check does.

Dependabot groups weekly GitHub Actions updates. There is no runtime package manifest;
Homebrew tools and the test-only dkjson rock are maintained in the workflow, not by Dependabot.
See [RELEASING.md](RELEASING.md) for the stable formula steps and [CHANGELOG.md](CHANGELOG.md)
for release notes.

## License

[MIT](LICENSE), copyright Oliver Kriska.
