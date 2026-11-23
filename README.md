# rex-agents

Bring Claude Code and Amp conversations back after a [Rex](https://www.superlogical.com/rex/) server restart. Press **⌘⇧B**, select what to resume, and continue where you left off.

Rex restores sessions, tabs, splits, pane labels and working directories—but not the programs inside them. Your agent panes come back as shells. rex-agents remembers which conversation and command belonged in each pane. You can also **park a project**: save its layout and conversations, close the session, and reopen it later.

Runs as a Lua extension inside Rex. No hub, Python, Node or separate Lua installation required.

https://github.com/user-attachments/assets/59f85a04-6293-4381-8673-1e98ec55dafc

*Reopen a parked project with its tabs, panes and Claude conversation, then park it again.*

## Concepts

- **Revive / picker:** restore saved programs in their original panes; the picker lets you choose which.
- **Park / template:** save a session as a reusable layout with commands, then optionally close it.
- **Watcher:** a macOS launchd background job that saves at startup, every two minutes, and shortly after pane changes. It never types.
- **Labelled programs:** opt-in fixed commands matched by pane label and working directory.
- **Services:** opt-in pane labels whose restart is delegated to your Rex action.
- **Viewers:** opt-in programs restarted with their recorded arguments, without conversation discovery.
- **Hub:** optional names for agents that communicate through a message hub. Off by default.

## Requirements

- macOS and Rex **0.1.0-preview.18 or newer**; tested on preview.18 (API 13), preview.20 (API 16) and preview.21 (API 18).
- Native prompts need **Rex server preview.21+** and a compatible connected app. Older servers use floating terminal pickers.
- **fzf** for terminal/fallback pickers; Homebrew installs it with rex-agents. Clone users: `brew install fzf`.
- Claude Code and/or Amp installed and available to your shell for agent recovery.
- macOS tools `ps`, `lsof`, `osascript` and `/usr/bin/nc` (normally already present).

This README describes `main`. Homebrew installs the latest release, **v0.2.1**; see the [changelog](CHANGELOG.md) for changes on `main` since then.

## Install

### Homebrew

Run these in a **Rex terminal pane**:

```sh
brew tap oliver-kriska/rex-agents https://github.com/oliver-kriska/rex-agents
brew install oliver-kriska/rex-agents/rex-agents
rex-agents setup --dry-run
rex-agents setup
rex --autostart=false -S "$REX_SERVER" config reload
```

If Homebrew refuses an untrusted tap, run `brew trust oliver-kriska/rex-agents`, then retry the install. Older Homebrew versions may not have `brew trust`.

Setup prints its plan before making changes. You should see this final line:

```text
Setup finished. Reload Rex config to activate the keys; ⌘⇧B brings back saved panes.
```

It links the extension, adds its actions to `init.lua`, and loads the **watcher** (launchd job `com.rex-agents.watch`). Its first save may not exist yet; run `rex-agents save` once a session is open. [Full setup details](#setup-internals-and-uninstall).

**What is ENDPOINT?** Run `echo "$REX_SERVER"` in a pane on the intended Rex server. That value identifies the server. Outside Rex, use `rex-agents setup --server ENDPOINT` with that value; use it with `-S` for the reload command too.

### From a clone

```sh
git clone https://github.com/oliver-kriska/rex-agents.git
cd rex-agents
./install.sh --dry-run
./install.sh
export PATH="$HOME/.config/rex/bin:$PATH"
rex --autostart=false -S "$REX_SERVER" config reload
```

Put that PATH line in your shell startup file too. Setup does not change PATH, and Rex does not automatically add this directory. Keep the checkout: the installed files link to it. Outside Rex, pass `--server ENDPOINT` to `install.sh`.

## Quick start

1. Install, reload config, and run Claude Code or Amp normally in a tiled pane.
2. Run `rex-agents save`, then `rex-agents status` and `rex-agents verify`.
3. After a Rex server restart, wait for your restored panes to reach empty shell prompts.
4. Press **⌘⇧B**. All rows start selected; toggle the programs you want, then **⌘Return** confirms the native picker. **Esc** cancels.
5. Results appear briefly in a floating pane. In the terminal fallback, **Tab** toggles, **Enter** confirms, and any key dismisses results.

For one recognised agent, output looks like this (captured on a private test server with a fake agent; save age varies):

```text
$ rex-agents save
saved 1 panes
$ rex-agents status
SESSION            TAB            PANE         KIND       STATE
Demo               Work           shell        claude     running

last save 0 s ago
$ rex-agents verify
1 entries, 1 live agents, last save 0 s ago
ok
```

A normal installation also shows watcher health: `watcher: running (pid N)` in status and `watcher com.rex-agents.watch running, pid N` in verify. The isolated example disables launchd inspection, so it omits those lines.

## Daily use

### Bring programs back after a restart

**⌘⇧B** lists eligible programs from the last watcher save, with their session, pane/tab, directory and kind. It rechecks each selected pane before typing. Confirming an empty selection does nothing. Services have one selectable **whole-session action** each, not per-pane control. Older servers, unavailable clients and failed prompts fall back to the floating fzf picker, which saves first; cancellation and timeout never open a fallback.

Use `rex-agents revive --dry-run` to inspect the plan, or `revive --pick` for fzf in your terminal. **Plain `revive` starts all eligible commands without asking.** `revive --only ID,ID` selects only those block IDs; `services:SESSION_ID` explicitly selects a whole-session service action. [Picker/output details](docs/advanced.md#picker-output).

After a server restart, the watcher can send **“N panes can be brought back — press ⌘⇧B”** once. Set `notify = false` to disable it. Starting shells and labelled programs running elsewhere may be excluded; the count is a plan, not a promise. First install is not a restart.

### Park a project, then continue it later

1. In a project session named **Demo**, use the palette action **Agents: Park Session (close, reopen later)**.
2. It saves the template, warns if a detected Claude turn is busy, then offers **Keep open** or **Close session**. The terminal fallback asks `[y/N]` instead.
3. Later, press **⌘⇧T**, select `demo`, then **Continue conversations**. The terminal fallback combines template and mode in one list.
4. Switch to the new session with Rex's **⌘K**. Tabs, splits and directories return, and agents with saved resume commands continue their conversations.

Choose **Fresh agents** instead to start new conversations. Without a saved resume command, “Continue” uses the fresh command too; fzf omits its “continue” row in that case. The last successfully opened template comes first. Opening creates a session but does not select it in the app, and refuses a duplicate session name.

**Save Session as Template** and **Save Tab as Template** ask for a name prefilled from the session/tab. Older servers save with that default immediately; an explicit `name` action argument skips the prompt. Filenames use lowercase slugs. Templates live in `~/.config/rex/templates/`. [Template JSON, held commands and copying tabs](docs/advanced.md#templates-and-copying-tabs).

### Inspect what can be restored

`status` covers recognised and saved panes, not every program on your machine. It includes missing panes and reasons an agent cannot resume. `verify` checks saved state and watcher health; `verify --against FILE` compares with an earlier `panes.json`.

| KIND in status | Recovery |
| --- | --- |
| `claude` | Supported launch flags plus the saved Claude session ID; unavailable without an ID. |
| `amp` | Continue the discovered thread; otherwise start a new thread. |
| `amp-runner` | Restart `amp --no-tui …` with its recorded arguments. |
| `amp-orb` | Restart `amp orb provider …`; no generated hub name. |
| `labelled` | Use the current configured command for that pane label. |
| `services` | Run your action once per selected Rex session. |
| Viewer basename, e.g. `btop` | Replay its saved arguments using PATH. |

Amp one-shot `-x` / `--execute` jobs are excluded (`--execute=…` also on `main`). Codex has no built-in conversation recovery. [Recognition limits and status states](docs/advanced.md#recognition-and-status).

### Keys, palette actions and CLI

| Default key | Palette action | Internal action name |
| --- | --- | --- |
| ⌘⇧B | Agents: Bring Back After Restart | `revive_agents` |
| ⌘⇧T | Agents: Open Project Template | `open_project` |
| None | Agents: Save Session as Template | `save_session_template` |
| None | Agents: Save Tab as Template | `save_tab_template` |
| None | Agents: Park Session (close, reopen later) | `park_session` |

To rebind, first remove the two `rex-agents:begin` / `rex-agents:end` marker comments from the setup-added block in `~/.config/rex/init.lua`, keeping its require line. Then edit it, for example:

```lua
require("rex-agents.actions"){ keys = { revive = "cmd+shift+r", open = false } }
```

`false` disables only that binding, not the action. Reload config afterward. `rex --autostart=false -S "$REX_SERVER" keymap` lists config bindings; check duplicate keys and your app's shortcut settings too. Without a client request it cannot show every client-side clash. [Action options](docs/advanced.md#action-options).

**Server targeting:** the CLI pins `REX_SERVER` with `-S`; `REX_AGENTS_SERVER` overrides it. With neither set, commands target Rex's **default server**. Outside Rex, explicitly set `REX_AGENTS_SERVER=ENDPOINT`. Even `--help` needs a reachable server; `setup --help` does not.

| `rex-agents` command | Effect |
| --- | --- |
| `setup [--dry-run] [--force] [--server ENDPOINT]` | Install integration; see setup rules below. |
| `setup --uninstall [--dry-run]` | Remove integration, retain user settings/state. |
| `save` | Record recognised tiled panes now. |
| `revive [--pick\|--dry-run\|--only IDS] [--save-first] [--pause]` | Restore selected commands; `--pause` waits for a key afterward. |
| `status [--json]` | Pane states, reasons, watcher health and warnings. |
| `verify [--against FILE]` | Check state; errors cause failure, warnings do not. |
| `template-list` | List template filename slugs. |
| `template-save SESSION_ID [NAME] [--window WINDOW_ID]` | Save a session or one tab. |
| `template-open [NAME\|--pick] [--fresh]` | Open a template; no name opens the picker. |
| `park SESSION_ID [NAME]` | Save, then ask to close. |
| `tab-to-session SESSION_ID WINDOW_ID NAME` | Copy a tab and stage commands; leave the original open. |
| `start-pending NAME` | Start staged commands; keep failed entries for retry. |
| `--help` | CLI usage. |

For **Rex** IDs, run `rex --autostart=false -S "$REX_SERVER" ls --json`, then `rex --autostart=false -S "$REX_SERVER" window ls -s SESSION_ID --json`. Read `.sessions[].session_id` and `.windows[].window_id`. A Rex “window” is a tab; these are not Claude conversation IDs or macOS window IDs.

## Optional features

Edit `~/.config/rex/rex-agents.local.lua`, a Lua file returning a table. [Example config](examples/rex-agents.local.lua). Rerun setup to restart the watcher after editing settings, and reload Rex config for already-loaded actions.

### Labelled programs

Use a fixed command for a specifically named pane. An ordinary pane label alone does **not** enable this feature.

```lua
return {
  labelled = {
    worker = { cwd_suffix = "/my-app", cmd = { "/usr/local/bin/my-worker", "start" },
      running = { socket = "~/Library/Application Support/my-worker/worker.sock" }, ready = true },
  },
}
```

`worker` must be the pane label. Without `running.socket`, duplicate detection matches a machine-wide argv prefix; wrappers need the socket check. The socket must accept a connection, not just exist. `ready = true` waits up to 30 s after launch; a timeout warns and continues. Labelled commands start before selected services, then agents/viewers. These are best-effort guards, not singleton enforcement. [Running/readiness details](docs/advanced.md#labelled-programs).

### Services and viewers

Use `services = { labels = { server = "docker compose up" }, action = "start_services" }` to delegate revive to a custom action. A selected action runs once per session, not once per pane. Template-open runs the label's command directly instead. The action is **not built in**: add the [minimal init.lua example](docs/advanced.md#service-action-example), then invoke it with `rex --autostart=false -S "$REX_SERVER" do -s SESSION_ID start_services` or select its service row in revive.

Use `viewers = { "btop", "lazygit" }` to replay those programs by basename and saved argv. Their KIND is the basename, not `viewer`. Viewers do not discover conversation IDs or receive generated hub names.

### Hub names

Set `hub = true` to assign stable agent names through `names.json`, without a `HUB_NAME` launch prefix. Set `hub_env = true` too only for the old prefix-based behavior.
This is optional; it does not install a hub. chief is a separate message-hub tool whose client can read the map.
Already-running agents keep their environment; status adds a hub-name column.
Saves and confirmed agent launches publish private `names.json`; disabling the feature removes it on the next successful save.
See the [names.json contract and chief client rules](docs/names-json.md).

## Configuration reference

Missing keys keep their defaults; lists extend defaults and maps merge by key.
Config edits apply on the watcher's next save and the next palette action, without restarting either. Invalid edits keep the last good config and log a warning; one-shot CLI commands still reject a broken config.

| Local config key | Default | Meaning |
| --- | --- | --- |
| `hub` | `false` | Only literal `true` enables hub integration. |
| `hub_env` | `false` | With hub enabled, opt into the old `HUB_NAME=` launch prefix. Otherwise clients resolve names through `names.json`; nested agents do not inherit a generated environment name. |
| `resume_prompt` | `nil` (off) | With hub enabled, send one initial prompt on eligible Claude conversation restores. Costs one turn per restored session; [temporary waiter workaround](docs/names-json.md#optional-resume-prompt). |
| `notify` | `true` | Restart notification; `false` disables it. |
| `keep_missing` | `604800` | Seconds to retain missing panes (one week). |
| `shells` | `{"zsh","-zsh","bash","-bash","sh","fish","login"}` | Add foreground names treated as shells. |
| `viewers` | `{}` | Basenames restarted with saved arguments. |
| `labelled` | `{}` | Label → entry below. |
| `services.labels` | `{}` | Label → template command string; `true` captures the running argv. |
| `services.action` | `nil` | Your Rex action name; required to revive services. |
| `labelled.LABEL.cmd` | Required | Nonempty argv array, not shell text. |
| `labelled.LABEL.cwd_suffix` | `""` | Literal cwd suffix; empty matches anywhere. |
| `labelled.LABEL.running` | `nil` | Default: machine-wide argv-prefix detection. |
| `labelled.LABEL.running.socket` | Required with `running` | Unix stream socket accepting connections; replaces argv detection. |
| `labelled.LABEL.ready` | `nil` | No extra readiness wait; `true` waits for running, table waits for path. |
| `labelled.LABEL.ready.path` | Required with table | Existence check, or connection check when equal to `running.socket`; `~/` expands. |
| `labelled.LABEL.ready.timeout` | `30` | Seconds; also 30 for `ready = true`. |

## Upgrading

```sh
brew upgrade oliver-kriska/rex-agents/rex-agents
rex-agents setup
rex --autostart=false -S "$REX_SERVER" config reload
```

Setup links use Homebrew's stable `opt` path. Rerunning it restarts the watcher with the new code, not Rex. Clone users update their checkout instead of running `brew upgrade`, then run setup and reload. Homebrew upgrades only when the formula points to a new release.

## Troubleshooting

- **⌘⇧B does nothing:** reload config, check `keymap` and app shortcuts, try the palette action, and confirm `fzf` is on PATH.
- **Nothing to bring back:** inspect `status` and `revive --dry-run`. A program may already be running, unrecognised, missing or unresumable. Saving cannot recover an ID already lost.
- **No first save:** open a session and run `save`. On `main`, verify reports this as information; a missing/stopped watcher or invalid state remains a problem.
- **Watcher missing or stale save:** run `rex-agents setup` from the intended Rex pane; inspect `~/Library/Logs/rex-agents.log`. Empty session lists deliberately skip saves.
- **No notification:** check `notify`, macOS permissions and watcher logs. A failed notification is not retried for that server instance.
- **Cannot resume / already running:** read the reason in `status`; wrappers often need `running.socket`. [More diagnostic details](docs/advanced.md#recognition-and-status).
- **Closed a session:** revive needs its original pane IDs. Park/templates are the way to reopen a closed project.

## Setup internals and uninstall

Setup backs up changed `init.lua`, prior watcher plist and existing saved panes; it copies example settings only when absent. It keeps an existing require line. It refuses unrelated links/files or edited managed blocks before changes. Remove the block's marker comments before customising its require line. If saved state exists without settings, restore the settings or explicitly accept defaults with `setup --force`.

Before changing between a clone and Homebrew install, uninstall the old integration. Before deleting a checkout or running `brew uninstall rex-agents`:

```sh
rex-agents setup --uninstall --dry-run
rex-agents setup --uninstall
rex --autostart=false -S "$REX_SERVER" config reload
```

Uninstall removes its unchanged init block, links and watcher. It keeps settings, templates, logs, backups and state. If you supplied your own require line, remove it **before** reloading. [Paths and backup details](docs/advanced.md#files-and-setup).

## How it works and safety

The watcher saves at startup, every 120 s and 20 s after the first event in a burst of pane/process changes. It records exact argv and discovers Claude session IDs and Amp thread logs. These agent internals can change upstream. Saves are atomic, with a previous-snapshot backup.

- **No automatic typing after restart.** Only explicit revive/template/start-pending commands start programs; copying a tab stages text.
- Direct restoration checks for idle shells before typing and skips busy/nested shells. Leave prompts empty: it cannot detect partially typed input. Floating panes are excluded.
- Parking closes programs, not just their UI. It preserves supported conversations, **not in-memory program state**; its busy warning covers detected Claude turns only.
- Settings/templates are executable input. Review files from others; keep local commands, paths and agent IDs private. There is no argv secret-redaction layer.
- All CLI calls use `--autostart=false`; rex-agents never stops or restarts the Rex server. Service actions remain responsible for their own safety and duplicate prevention.

State lives in `~/.local/state/rex-agents/` (or `$XDG_STATE_HOME/rex-agents`): snapshots, pending commands, notification decisions, last-used template and optional hub names. Templates live in `~/.config/rex/templates/`. [File purposes and locks](docs/advanced.md#files-and-setup).

## Contributing and tests

On macOS, install mise, Xcode Command Line Tools and Homebrew, then run `mise install` and `make check`. CI runs the same command. Use throwaway Rex servers for e2e, never work sessions. See [development tools, test commands and isolation rules](docs/contributing.md), [releasing](RELEASING.md) and the [changelog](CHANGELOG.md).

## License

[MIT](LICENSE), copyright Oliver Kriska.
