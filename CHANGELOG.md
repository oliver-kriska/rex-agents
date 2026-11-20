# Changelog

## Unreleased

- Apply config edits on the next watcher save and palette action without restarting; invalid edits retain the last good config and warn once per bad text.
- Save templates from the current session/tab after the name prompt, rejecting sessions or tabs closed while the prompt was open.
- Protect expired names and labelled-launch locks while their owner is alive; compare PID and process start time before reclaiming them.
- Scan outside `names.lock` and merge concurrent startup publications at commit time, retaining
  newer live names, PIDs and restore commands. Native revive uses the last save without a full scan first.
- Add opt-in `resume_prompt` for hub-enabled Claude conversation restores, a temporary waiter
  recovery request costing one turn per restored session. Never retain the prompt in saved commands.
- Use native Rex prompts for action-launched revive, template selection/mode, park confirmation
  and template names on server preview.21+. Preserve legacy fallbacks; cancellation never starts work.
- Add `revive --only` for explicit selections and remember the last opened template privately.
- Publish agent PIDs to names.json immediately after managed launches, with bounded polling,
  relaunched-child detection and serialization against concurrent saves. Keep HUB_NAME prefixes.
- Cancel revive when Enter is pressed with no selected rows. Make service actions selectable,
  including services-only plans, instead of starting them implicitly.
- Exclude Amp `--execute=…` one-shot jobs from recovery.
- Treat a missing first snapshot as informational while still reporting watcher failures;
  point missing-watcher guidance at `rex-agents setup`.
- Reorganise the README around installation and daily use, with output examples and linked
  references for templates, setup, hub clients and contributor checks.

## v0.1.0 — 2026-11-17

First public release of rex-agents, a macOS Lua extension for Rex.

- Record Claude Code session IDs and supported launch flags, including relaunched children;
  resume Amp threads (or start plain Amp when no thread is found), and preserve non-TUI runner
  and orb-provider arguments after a Rex server restart.
- Restore selected commands with ⌘⇧B and show an opt-out notification when the first
  successful save after a server restart finds panes to bring back.
- Save project layouts as templates, open fresh or continued conversations, park sessions,
  and copy tabs into sessions with commands staged for later startup.
- Configure viewers, labelled programs and per-session service actions. Start labelled
  programs first, check for existing instances by argv or Unix socket, and optionally wait
  for readiness before agents start.
- Inspect all recognised pane kinds with `status` and validate saved state with `verify`.
- Make hub naming opt-in, preserving the version-1 private names.json contract and child PIDs.
- Add Homebrew packaging and shared setup with dry-run, backups, stable opt links and
  uninstall that preserves user settings and state.
- Test on Rex 0.1.0-preview.18 and preview.20; run standalone unit/setup tests and shell,
  Lua, workflow and formula checks in macOS CI.
