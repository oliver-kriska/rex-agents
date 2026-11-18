# Changelog

## Unreleased

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
