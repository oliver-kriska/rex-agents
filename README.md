# rex-agents

Bring your coding agents back after a [Rex](https://www.superlogical.com/rex/) server restart, and
open whole projects (tabs, splits, agents) from hand-editable templates.

Rex restores sessions, tabs, splits, pane labels and working directories after a restart, under
the same block IDs, but not the programs that ran in them. rex-agents remembers what ran in each
pane and types it back:

- **Claude Code**: `claude <the flags it was started with> --resume <session id>`
- **Amp**: `amp threads continue <thread id>`; `--no-tui` runners with their own arguments
- **viewers** you list (`btop`, `lazygit`, …) with their arguments
- **labelled panes**: a pane known by its label and directory gets a fixed command
- **service panes**: run one of your init.lua actions for the session

It's written in Lua and runs inside Rex (`rex do` scripts and init.lua actions). It needs no
Python, Node or other runtime: only what macOS ships (`ps`, `lsof`, `osascript`) plus `fzf` for
the pickers.

## Install

```sh
git clone … ~/src/rex-agents && cd ~/src/rex-agents
./install.sh            # or ./install.sh --dry-run
```

`install.sh` links `~/.config/rex/rex-agents` and `~/.config/rex/bin/rex-agents` to the
checkout, copies `examples/rex-agents.local.lua` to `~/.config/rex/` if you have none (it never
overwrites yours), and loads a LaunchAgent that runs the watcher. It copies `panes.json` to
`panes.before-install-<time>.json` first, waits for the watcher's first save and runs
`rex-agents verify --against` that copy. If saved panes exist but you had no settings, it stops
before starting the watcher, so a save with the example settings can't drop the panes only your
settings recognise (`--force` starts it anyway). Then add one line to `~/.config/rex/init.lua`:

```lua
require("rex-agents.actions"){}
-- or choose keys:  require("rex-agents.actions"){ keys = { revive = "cmd+shift+b", open = "cmd+shift+t" } }
```

and run `rex config reload`.

## Use

| Key / palette | What it does |
| --- | --- |
| ⌘⇧B · *Agents: Bring Back After Restart* | Lists the saved agents whose panes are idle shells now; enter types their commands back. |
| ⌘⇧T · *Agents: Open Project Template* | Opens a template as a new session, with fresh agents or (for parked projects) the same conversations. |
| *Agents: Save Session as Template* / *Save Tab as Template* | Writes `~/.config/rex/templates/NAME.json` from what runs now. |
| *Agents: Park Session* | Saves the session as a template that continues its conversations, warns about Claude turns still running, then asks before closing it. |

The same from a shell:

```
rex-agents save
rex-agents revive [--pick|--dry-run]
rex-agents template-save SESSION_ID [NAME] [--window WINDOW_ID]
rex-agents template-open [NAME|--pick] [--fresh]
rex-agents park SESSION_ID [NAME]
rex-agents template-list
rex-agents tab-to-session SESSION_ID WINDOW_ID NAME   # then: rex-agents start-pending NAME
rex-agents status [--json]
rex-agents verify [--against FILE]
```

`status` lists every agent pane with its hub name (see below) and whether the running program
already has it:

| State | Meaning |
| --- | --- |
| `ok` | runs with `HUB_NAME` set to its name |
| `restart pending` | runs without `HUB_NAME` (started by hand, or before names existed); gets it the next time rex-agents starts it |
| `runs as NAME` | runs with another `HUB_NAME`, set by hand |
| `not saved yet` | started since the last save (the watcher saves within 20 s) |
| `not running` | an idle shell after a restart; ⌘⇧B brings it back |

`--json` gives the same rows with session and block IDs. `verify` checks `panes.json` (entries
have a command, no duplicate names among live panes, no leftover helper fields), the watcher
and the time of the last save, and exits 1 on a problem. With `--against`, a copy of
`panes.json` taken before a change, it also lists entries that went missing and commands that
changed; a pane you closed or a program you exited is only a warning, and a pane that became
resumable is reported as such. A live agent that can't be resumed is a warning naming the pane.

Revive only types into a pane whose foreground program is a shell at its prompt, so it never
starts anything twice. It checks each pane again right before typing (the picker may have been
open a while), waits up to 10 s for a pane whose shell is still starting, and skips a pane that
runs a shell inside another shell.

## How it works

```
rex-agents/
  core.lua      everything: classify panes, save, revive, templates (works in init.lua and rex do)
  cli.lua       the commands above, run by `rex do` (bin/rex-agents is a thin sh wrapper)
  watch.lua     long-running `rex do --all` script: saves at start, every 2 min, and 20 s
                after a pane's foreground program changes
  actions.lua   init.lua actions and keys
  procargs.js   exact argv via sysctl(KERN_PROCARGS2), through osascript's JavaScript bridge
```

**Classifying a pane.** For each tiled pane, the terminal block's `process` method gives the
foreground PID. Its exact argv comes from `procargs.js` (Rex's Lua has no FFI, and `ps` joins
arguments with spaces, so a quoted prompt would turn into flag values). Claude Code's session ID
comes from `~/.claude/sessions/<pid>.json`; its launch flags are its argv without the prompt and
the conversation selector, or `CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS` when Claude Code set it
(non-empty) on `/restart`. After `/restart` or an update Claude Code keeps the first process and
runs the new version as its child; the session file then belongs to the child, so rex-agents looks
there too. Flag groups repeated by such relaunches (`--allowed-tools X` again and again) are
written once (that variable and `HUB_NAME` are the only parts of a process environment ever read). Amp's thread ID
is the `threads/T-….log` file it holds open (`lsof`).

**Surviving restarts.** `~/.local/state/rex-agents/panes.json` maps block ID → command. Each
entry records the server it was seen alive on (Rex's `instance_id`; entries saved by earlier
versions hold `PID@start time` and are still recognised). A save:

- skips writing when no session is visible yet (server still starting), or when the server
  stopped or restarted while it looked (dying programs would look like ones you exited);
- drops an entry only if its pane is an idle shell *and* it ran under the current server (you
  exited it yourself). After a restart the old entries stay until you revive them;
- keeps entries whose block is missing for a week;
- copies the previous file to `panes.prev.json` first, and writes atomically.

The LaunchAgent keeps the watcher alive (`KeepAlive`). When the server restarts the watcher's
connection drops, it exits and launchd starts it again.

**Notice after a restart.** When the watcher's first save runs under a new server (Rex's
`instance_id` differs from the one in the previous save), it works out what ⌘⇧B would bring back
and, if anything, shows one macOS notification: *rex-agents: N agents can be brought back — press
⌘⇧B*. It never types into a pane. The server it notified for is kept in `notified.json`, so a
watcher that launchd restarts doesn't repeat it. `notify = false` in the settings turns it off. A
pane whose shell is still starting during that save isn't counted.

## Agent names (`HUB_NAME`)

Every Claude Code and Amp pane rex-agents starts (revive, template-open, start-pending) gets
`HUB_NAME=<name>` in front of its command, for tools that address agents by name (a message hub,
an MCP server reading `HUB_NAME`). The name is chosen once per pane and then kept across server
restarts, revives and park/reopen, in `hub_name` in `panes.json` and in templates:

1. the `HUB_NAME` the program already runs with;
2. the Claude Code session name, if you set it (`/rename worker chief 2` → `worker-chief-2`);
3. the pane label, unless it's a generic one such as `shell`;
4. `<session>-<kind>-<last 6 characters of the block ID>`.

Names are unique among live panes: a taken one gets the session name in front.
`rex-agents status` shows each pane's name and whether its program already has it. Names follow
`[A-Za-z0-9][A-Za-z0-9._-]*`, at most 64 characters. A program that is already running keeps
its environment; it gets the name the next time rex-agents starts it.

### `names.json`: names for programs already running

A name reaches a program through `HUB_NAME` only when rex-agents starts it. For everything else,
each save also writes `~/.local/state/rex-agents/names.json` (mode 600, atomic), a format kept
stable for other tools:

```json
{
  "version": 1,
  "server": "<Rex server instance_id>",
  "saved_at": 1794900000,
  "blocks": {
    "block:01a1…": { "hub_name": "worker-chief", "kind": "claude", "session": "Chief",
                     "session_id": "session:01a1…", "pids": [41049, 33200] }
  }
}
```

Only agents running at the time of the save are listed, with unique names. `pids` are the agent's
processes: the pane's foreground program and, after a Claude Code `/restart` or update, its
relaunched child. A reader (for example a hub client with `HUB_NAME` unset) looks up `$REX_BLOCK`
and should accept the name only if one of `pids` is its own ancestor (so a nested agent started
inside that pane doesn't take it) and the file is recent (saves happen every 2 minutes).
`HUB_NAME`, when set, always wins.

## Templates

`~/.config/rex/templates/NAME.json`, meant to be edited by hand:

```json
{
  "name": "My Project",
  "saved_at": "2026-01-01 12:00",
  "windows": [
    {
      "label": "Agents",
      "layout": {
        "split": {
          "direction": "horizontal",
          "ratio": 0.5,
          "before": { "block": { "label": "manager", "cwd": "~/src/app", "cmd": "claude",
                                 "resume": "claude --resume 0f…" } },
          "after":  { "block": { "label": "server", "cwd": "~/src/app", "cmd": "mix phx.server",
                                 "hold": true } }
        }
      }
    }
  ]
}
```

- `cmd` starts the pane fresh; `resume` (written by park) continues the same conversation.
- `hold: true` types the command without pressing enter.
- `hub_name` (agents only) is the pane's `HUB_NAME`. A hand-written one is kept when you save the
  template again (for labelled panes). If a live pane already uses it when the template opens, the
  session name goes in front.
- Saving again keeps a hand-written `cmd`/`hold` of a labelled pane whose program it can't
  recognise.

## Settings

`~/.config/rex/rex-agents.local.lua` returns a table (see `examples/rex-agents.local.lua`):
extra `viewers`, `labelled` panes (`label` + `cwd_suffix` → `cmd`), service panes (`services.labels`
and the init.lua `services.action` to run), `keep_missing`, and `notify = false` to turn off the
notice after a restart.

Environment overrides, mainly for tests: `REX_AGENTS_STATE`, `REX_AGENTS_TEMPLATES`,
`REX_AGENTS_CLAUDE_SESSIONS`, `REX_AGENTS_CONFIG`, `REX_AGENTS_SERVER`,
`REX_AGENTS_WATCH_LABEL` (the LaunchAgent `status`/`verify` check; `-` skips the check),
`REX_AGENTS_NOTIFY_CMD` (a program run as `CMD TITLE TEXT` instead of `osascript`), and
`REX_AGENTS_REX` (the `rex` binary; `bin/rex-agents` sets it to the one it runs, so the services
`rex do -s` uses the same version).

## Safety notes

- Up to Rex CLI 0.1.0-preview.18, when `REX_SERVER` names a server that isn't answering, the
  `rex` CLI quietly falls back to your home server (fixed in preview.19). `bin/rex-agents`
  therefore always passes `-S` (the pane's own `REX_SERVER`, or `REX_AGENTS_SERVER`), and
  `tests/e2e.sh` does the same.
- Nothing here stops or restarts a Rex server.

## Tests

```sh
rex do tests/unit.lua   # pure helpers (argv filtering, quoting, JSON, layouts)
tests/e2e.sh            # full cycle on a private throwaway server with fake claude/amp binaries
REX_BIN=/path/to/rex tests/e2e.sh   # the same with another Rex binary (server and clients)
```

`e2e.sh` starts its own `rex server run` on a private socket, saves, restarts that server with
SIGTERM to its own PID, checks the restart notice (through `REX_AGENTS_NOTIFY_CMD`), revives,
parks and reopens a session, moves a tab to a new session, and checks every pane's argv.

Tested with Rex 0.1.0-preview.18 and 0.1.0-preview.20 (all e2e checks pass on both). On
preview.20, blocks made by `session.create` are still owned by the client that created them; the
current online docs describe blocks that start without an owner, which only affects `resize` and
`set_theme`, not the `write` that start-pending uses.

## Limits

- macOS only (`osascript`, `lsof`, the `~/Library` paths).
- Floating panes aren't recorded.
- Revive retypes commands; it can't restore a program's in-memory state.
