# Hub names and names.json

Hub integration is optional. Add `hub = true` inside `~/.config/rex/rex-agents.local.lua`'s returned table, then rerun setup to restart the watcher and reload Rex config. This does not install a hub. **chief** is a separate message-hub tool with a client that consumes this map; rex-agents works without it.

## Name assignment

Revive, template-open and start-pending prefix Claude Code, interactive Amp and Amp runner commands with `HUB_NAME=<name>`. Amp orb providers and viewers receive no generated prefix. Already-running agents keep their environment.

Saves assign unique names among live agent panes **on the inspected Rex server**, not across servers. Priority:

1. Valid, unique existing `HUB_NAME`.
2. Previously saved name for that pane.
3. User-set Claude Code session name.
4. Non-generic pane label.
5. `<session>-<kind>-<last 6 block ID characters>`.

Collisions try a session prefix, then a generated name or numeric suffix. Renaming a conversation does not replace a saved name. Names match `[A-Za-z0-9][A-Za-z0-9._-]*` and contain at most 64 characters.

Status adds a hub column: `ok` means the environment matches, `restart pending` means the agent has no `HUB_NAME`, and `runs as NAME` means it has another one. Name validation is enabled only with this feature.

## Producer contract: version 1

Each enabled save writes an atomic, mode-600 `~/.local/state/rex-agents/names.json`. The state-directory overrides also affect its location.

Revive, template-open and start-pending also publish a newly launched agent's PID as soon as its foreground process is recognised, without waiting for the watcher or a conversation file. The detected relaunched Claude child is included too. The startup path polls every 0.2 s with a nine-second wall-clock budget after typing Enter, caps subprocess timeouts to the remaining budget, and targets publication within **10 s per launched pane**. If it cannot confirm/publish, it reports a warning and continues; the watcher still saves 20 s after the first process event and every 120 s. Held commands and hub-disabled launches do not poll.

This is a bounded best-effort startup path, not a guarantee that a failed or indefinitely slow agent starts. Rex IPC and OS scheduling can also stall beyond the polling budget. A consumer should allow at least the 10 s target and retain a retry/reconnect path, rather than assuming a row must exist on its first read. Entries can lag exits until the watcher reconciles them; always validate PID ancestry.

Full scans and startup updates share `names.lock` so a concurrent save or launch cannot overwrite another launch's PID row. A busy full save is skipped; startup polling retries within its budget. An abandoned lock expires after two minutes. Names and format are unchanged; the `HUB_NAME` prefix is still supplied.

```json
{
  "version": 1,
  "server": "<Rex server instance_id>",
  "saved_at": 1794900000,
  "blocks": {
    "<Rex block ID>": {
      "hub_name": "worker-demo",
      "kind": "claude",
      "session": "Demo",
      "session_id": "<Rex session ID>",
      "pids": [10001, 10002]
    }
  }
}
```

`saved_at` is a Unix timestamp in seconds. `session_id` identifies the **Rex session**, not a Claude conversation. Only running `claude`, `amp` and `amp-runner` panes appear. `pids` includes the foreground process and, when found, the relaunched Claude descendant (searched up to two levels down). Version 1 remains compatible with chief v0.1.0-pre.9.

Disabling hub integration removes the map on the next successful save and stops generated prefixes, metadata, columns and validation. Explicit commands/inherited environments remain user-controlled: rex-agents does not strip manually supplied `HUB_NAME` values.

## chief client rules (v0.1.0-pre.9)

Both `hub mcp` and ordinary CLI commands resolve a name in this order: `--as`, `HUB_NAME`, then `blocks[$REX_BLOCK]` in the map. Empty explicit values count as absent. This describes the consumer, not additional validation performed by rex-agents.

The map is accepted only when:

- It is a regular, user-owned file with no group/other mode bits; symlinks are refused.
- It is at most 1,000,000 bytes and its inode, size and modification time remain unchanged across reading.
- Its JSON has `version: 1` and an integer `saved_at` no more than 600 seconds old or 60 seconds in the future.
- It contains the current block, a valid hub name and listed process IDs.
- A listed PID is an ancestor of the client, and every intervening process is a recognised shell or launcher. A nested agent cannot take its parent's pane name.

Refusals include a one-line reason. Without a usable name, `hub mcp` fails; ordinary CLI commands fall back to `cli-$USER`, quietly when no map exists. Lookup checks file metadata, reads the map, obtains the UID with `id -u`, and uses at most one `ps` ancestry snapshot. It does not query Rex.

The pre.9 client reads the fixed default path `~/.local/state/rex-agents/names.json`, **not** rex-agents' state-directory overrides. Keep that in mind when setting `XDG_STATE_HOME` or testing isolated instances.
