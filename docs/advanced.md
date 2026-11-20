# Advanced use and setup

Start with the [README](../README.md). These details describe `main`.

## v0.1.0 differences

Homebrew's stable formula currently installs v0.1.0, not the latest `main`:

- In its revive picker, Enter with no marked rows still accepts the cursor row. Use **Esc** to cancel.
- Its service actions are not selectable rows: accepting the picker runs them, and a services-only plan runs without a picker. On `main`, each eligible session has a selectable service row; Enter with nothing marked cancels.
- First-install verify can report a missing `panes.json` as a problem before the watcher saves. Run `rex-agents save` with a session open, then verify again. `main` treats no initial save as information, but still checks watcher health.
- `main` excludes Amp `--execute=…` one-shot commands as well as `-x` and `--execute`; v0.1.0 only checks the separate tokens.

Use the clone installation for the current source. Upgrading a stable installation does not apply unreleased fixes.

## Picker output

On server preview.21+, actions try `rex.ui` directly. Revive shows a multi-picker, all ticked, with session › pane/tab, shortened cwd and kind. ⌘Return confirms; no selection means no work. Template-open asks for a template (last-used first), then Continue/Fresh. Save actions ask for a name, and park saves before asking Close/Keep open. Cancel and timeout stop without a terminal fallback. An empty save name also cancels.

Missing `rex.ui`, `unsupported`, `no_client`, `busy` and `failed` use the legacy path; failures log their detail. Revive/template-open/park fall back to the floating CLI. Save actions retain their original immediate default-name save when native input is unavailable. Native launch results remain in a floating pane for three seconds; there is no second “press any key” prompt. No native prompt runs under `pcall`, a timer or a library callback.

The **terminal fallback** for revive runs `revive --save-first --pick --pause`. Its list shows session, tab and command; block IDs are hidden. Agent conversation IDs can appear **inside the command**, so inspect before sharing captures. With hub enabled a row also shows `[hub-name]`.

Captured from the actual floating picker on a private server with a fake Claude process; the conversation ID is replaced below:

```text
revive>
  1/1 (1) ──────────────────────────────────────────────────────
  tab: toggle · enter: start selected (none: cancel) · esc: cancel
▌┃Demo           Work             claude --model sonnet --resume <conversation-id>
```

All eligible rows start selected. Tab toggles a row; typing filters. Enter starts marked rows, even marked rows hidden by a filter. Esc or Enter with nothing marked cancels. Service rows read `services: Demo → start_services`, one action per session. Labelled commands launch first, followed by selected service actions, then other selected commands.

For automation, `revive --only block:ID,block:OTHER` is an exact allowlist. An empty string or unknown IDs starts nothing; it cannot combine with `--pick` or `--dry-run`. Include `services:SESSION_ID` to request that session's entire configured service action. Obtain block IDs with `rex --autostart=false -S "$REX_SERVER" block ls -s SESSION_ID --json`. Both pickers share the same launch order and idle checks. Native actions run slow launches in the CLI, outside the action's execution time limit.

After accepting that row:

```text
started: Demo / Work → claude --model sonnet --resume <conversation-id>

press any key
```

A skipped command instead shows `skipped: …` with its reason. The pause also happens after cancellation. With no eligible work it shows `Nothing to bring back: every saved pane is running or gone.` and the same pause. Standalone `revive --pick` does not pause unless you also pass `--pause`.

## Templates and copying tabs

Templates are hand-editable JSON. For example:

```json
{
  "name": "My Project",
  "windows": [{ "label": "Work", "layout": {
    "split": { "direction": "horizontal", "ratio": 0.5,
      "before": { "block": { "label": "manager", "cwd": "~/src/app", "cmd": "claude",
                               "resume": "claude --resume <conversation-id>" } },
      "after": { "block": { "label": "server", "cwd": "~/src/app", "cmd": "docker compose up",
                              "hold": true } }
    }
  } }]
}
```

- `cmd` starts fresh, `resume` continues, and `hold` types without Enter. Replace the placeholder ID with a real saved conversation before using this example.
- Optional `hub_name` takes effect only with `hub = true`; template-open resolves collisions using a session prefix or another unique name.
- Saving matches existing template panes by their ordinary labels to preserve handwritten commands/hold for unrecognised programs. This is separate from the **Labelled programs** config feature.
- Session templates use the session name by default. `--window WINDOW_ID` uses the tab name; a default Rex tab name falls back to a pane's cwd basename. Filenames use lowercase slugs.
- `template-open NAME` prefers `resume`; `--fresh` uses `cmd`. The template's `name` determines the new session label. A duplicate name is refused.
- Labelled commands start first; other commands follow layout order. Guarded commands are not pretyped before duplicate/idle checks. An already-running labelled program leaves its new pane empty.
- Park saves before asking to close. The default is No. Its busy-turn warning covers detected Claude turns, not arbitrary background jobs.

To copy one tab without closing the original:

```sh
rex-agents save
rex-agents tab-to-session SESSION_ID WINDOW_ID "Project Copy"
# Inspect the copy and close the original tab yourself, then:
rex-agents start-pending "Project Copy"
```

The copy uses the **last snapshot**, not a new scan. Non-service commands are staged without Enter; guarded labelled commands are deferred entirely. `start-pending` starts labelled commands first and retains failed entries for retry. Services need their own action or manual startup. Do not edit staged text: starting it presses Enter rather than retyping the saved command.

With hub enabled, copied commands retain their old names, unlike template-open's collision handling. Do not start both copies. Neither copying nor starting pending commands closes the old tab.

## Labelled programs

The config key must match the pane label and its `cwd_suffix`. Commands come from **current settings**, not stale saved commands. Use an absolute executable path for reliable argv matching.

By default, rex-agents searches machine-wide process argv for a whole-argument prefix. Additional arguments still match; a partial argument does not. An existing process is omitted from the picker and reported as `already running (pid N, in SESSION / PANE)` when attribution is possible. Template-open/start-pending use this guard when their complete command matches a configured entry.

For wrappers that exec a different runtime, `running.socket` replaces the argv check. The Unix stream socket must accept a connection; no payload is sent. This proves reachability, not application health. A stale socket fails. Socket checks report the answering filename, without PID/pane attribution.

`ready = true` waits for the running check, up to 30 seconds. `ready = { path = "~/path/to/ready", timeout = 30 }` waits for existence, or connection acceptance if the path equals `running.socket`. A timeout warns and continues; an already-running program is ready immediately.

`status` and `verify` warn about wrong-pane argv matches, unmatched configured labels and stale saved commands. A program found elsewhere is not saved as that other pane's labelled entry.

Launches share `labelled-start.lock`. Unconfirmed launches warn and release it after 10 seconds, or the running-readiness timeout. Locks at least two minutes old expire. External starts, separate state directories and waits longer than the lease can race it. Strict singleton enforcement belongs in the program; do not delete an active lock.

## Service action example

Add this to `~/.config/rex/init.lua` alongside the existing rex-agents require line. It targets tiled panes labelled `server` **in the requested session only**, using the extension's idle-shell check. Set `services = { labels = { server = "docker compose up" }, action = "start_services" }` in local settings too.

```lua
rex.action{
  name = "start_services", title = "Start project services",
  run = function(ctx)
    local A = require("rex-agents.core")
    local view = assert(A.view(ctx.session_id), "session not found")
    for _, window in ipairs(view.windows) do
      for _, pane in ipairs(A.leaves(window.layout)) do
        if pane.label == "server" then
          local ok, err = A.type_if_idle(ctx.session_id, pane.block_id, "docker compose up")
          if not ok then error(tostring(err)) end
        end
      end
    end
  end,
}
```

Reload config, then invoke `rex --autostart=false -S "$REX_SERVER" do -s SESSION_ID start_services`, or select its service row in revive. Docker must be installed and the pane's cwd must contain your Compose file. Leave the prompt empty. This example avoids typing into busy processes; it does not detect a detached service already running elsewhere. Use a service manager or add a project-specific duplicate check when needed. Template-open runs the configured command directly instead of calling this action.

## Action options

These are `init.lua` options, **not** `rex-agents.local.lua` settings:

```lua
require("rex-agents.actions"){
  keys = { revive = "cmd+shift+b", open = "cmd+shift+t" },
  bin = os.getenv("HOME") .. "/.config/rex/bin/rex-agents",
}
```

Those are the defaults. Set a key to `false` to disable its binding while keeping the palette action. Remove setup's two marker comments before customising its managed line. Session/tab save actions accept an optional `name` argument when invoked with `rex do`; the park action uses the current session name.

## Recognition and status

- Claude is recognised by executable basename `claude`. IDs come from `~/.claude/sessions/<pid>.json`, including relaunched descendants up to two levels down. Supported flags come from argv or `CLAUDE_CODE_RELAUNCH_RESUME_HINT_FLAGS`; prompt/conversation-selector flags are removed before adding the saved ID. Print-mode processes are not separately excluded, but `-p`/`--print` is removed on restore. The parser cannot anticipate every future value-taking flag.
- Interactive Amp IDs come from open `threads/T-….log` files via `lsof`. Without an ID it starts plain `amp`, with a picker warning. Original interactive launch flags are not retained. Runner/orb modes replay saved arguments.
- Viewers replay their basename and argv through PATH, not their original absolute executable path. They do not add conversation discovery for unsupported agents.
- Foreground shells, unrecognised programs and floating panes are not recorded as agents.
- States include `running`, `not running`, `busy (different program)`, `cannot resume: REASON`, `pane missing`, and `already running (…)`. With hub enabled the additional name state is explained in [names-json.md](names-json.md).
- `verify` checks commands, helper fields, watcher health and save age. `--against FILE` also reports lost entries and changed commands. Closed panes/exited programs warn; a previously saved pane still running but no longer recognised errors. Errors exit 1; warnings alone do not.

Report agent and Rex versions when recognition breaks. Do not post complete state files, process environments or sensitive argv.

## Files and setup

The watcher saves at startup, every 120 s and 20 s after the first process/block/session event in a burst. Later events do not reset that timer. `procargs.js` reads exact argv through macOS sysctl using osascript's JavaScript bridge. Only the relaunch-flags variable and, when enabled, `HUB_NAME` are read from process environments.

`panes.json` maps block IDs to commands and server instance IDs. Saves are skipped with no visible sessions or if Rex restarts during a scan. An idle shell drops its saved entry only if it ran on the current server; entries survive restarts. Missing panes remain for `keep_missing` seconds.

| Location | Purpose |
| --- | --- |
| `~/.config/rex/rex-agents` | Symlink to installed Lua modules. |
| `~/.config/rex/bin/rex-agents` | Symlink to CLI wrapper. |
| `~/.config/rex/rex-agents.local.lua` | Private settings; copied only if absent. |
| `~/.config/rex/templates/*.json` | Layouts and fresh/resume commands. |
| `~/.local/state/rex-agents/panes.json` | Current snapshot; atomic save. |
| `panes.prev.json` in that directory | Previous snapshot. |
| `pending.json` in that directory | Copied commands retained until successfully started. |
| `notified.json` in that directory | Server instance considered for a restart notification. |
| `last-template.json` in that directory | Last successfully opened template slug; atomic, mode 600. |
| `names.json` in that directory | Private hub map, only with hub enabled. |
| `names.lock` in that directory | Serialises final snapshot/map commits, not process scans; abandoned locks expire after two minutes. |
| `labelled-start.lock` in that directory | Temporary launch-serialisation directory. |
| `~/Library/Logs/rex-agents.log` | Watcher saves, skipped saves and errors. |
| `~/Library/LaunchAgents/com.rex-agents.watch.plist` | Watcher pinned to the setup endpoint. |

`XDG_STATE_HOME` changes the state parent directory. Setup creates timestamped backups beside files it replaces, including `panes.before-install-*.json` for `verify --against`. It recognises the original install.sh watcher by label and script path, backs it up and replaces it. An existing custom actions require line is kept.

The watcher remembers notification decisions in `notified.json`; restarting just the watcher does not repeat a notification. The first install is not a restart. Only the first eligible save after a server change counts; no resumable panes means no notification, and notification failure is not retried for that instance.
