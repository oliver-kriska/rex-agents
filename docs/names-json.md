# Hub names and names.json

Hub integration is optional. Add `hub = true` inside `~/.config/rex/rex-agents.local.lua`'s returned table; edits apply on the next watcher save and palette action. This does not install a hub. **chief** is a separate message-hub tool with a client that consumes this map; rex-agents works without it.

## Name assignment

By default, `names.json` is the only source of generated hub names for new launches. Revive, template-open and start-pending do not add `HUB_NAME`. Set `hub_env = true` alongside `hub = true` to restore the old prefix on Claude Code, interactive Amp and Amp runner commands. Amp orb providers and viewers receive no generated prefix. Existing or manually supplied `HUB_NAME` values remain recognised; already-running agents keep their environment.

In prefix-free panes, nested Claude/Amp agents and teammates no longer inherit the pane's environment name. With chief's ancestry-aware client they use its `<folder>-<harness>` fallback. This depends on the chief client, not just this producer; test the two together before migrating. Existing prefixed panes must be relaunched without an inherited/manual `HUB_NAME` to get this behavior.

Saves assign unique names among live agent panes **on the inspected Rex server**, not across servers. Priority:

1. Valid, unique existing `HUB_NAME`.
2. Previously saved name for that pane.
3. User-set Claude Code session name.
4. Non-generic pane label.
5. `<session>-<kind>-<last 6 block ID characters>`.

Collisions try a session prefix, then a generated name or numeric suffix. Renaming a conversation does not replace a saved name. Names match `[A-Za-z0-9][A-Za-z0-9._-]*` and contain at most 64 characters.

Status adds a hub column. When a running agent carries `HUB_NAME`, `ok` means it matches the saved name and `runs as NAME` means it differs. Otherwise, with `hub_env = false`, `ok` requires the same name and a live agent PID in that block's `names.json` entry. Missing entries show `not published`, mismatched PIDs show `published for another process`, and mismatched names show `published as NAME`. With `hub_env = true`, an agent lacking the environment name still shows `restart pending`. Verify warns about these mismatches; both commands display `hub_env` next to any `resume_prompt` setting. Name validation is enabled only with hub integration.

## Producer contract: version 1

Each enabled save writes an atomic, mode-600 `~/.local/state/rex-agents/names.json`. The state-directory overrides also affect its location.

Revive, template-open and start-pending also publish a newly launched agent's PID as soon as its foreground process is recognised, without waiting for the watcher or a conversation file. The detected relaunched Claude child is included too. The startup path polls every 0.2 s with a nine-second wall-clock budget after typing Enter, caps subprocess timeouts to the remaining budget, and targets publication within **10 s per launched pane**. If it cannot confirm/publish, it reports a warning and continues; the watcher still saves 20 s after the first process event and every 120 s. Held commands and hub-disabled launches do not poll.

This is a bounded best-effort startup path, not a guarantee that a failed or indefinitely slow agent starts. Rex IPC and OS scheduling can also stall beyond the polling budget. A consumer should allow at least the 10 s target and retain a retry/reconnect path, rather than assuming a row must exist on its first read. Entries can lag exits until the watcher reconciles them; always validate PID ancestry.

Full scans discover processes **outside** `names.lock`. Only the final read/merge/write of `panes.json` and `names.json` is locked. Startup publication also saves the new pane's restore metadata, so an older scan cannot erase it. Under the lock, a scan re-reads current state and retains live entries published since its start (including the same timestamp second). Matching kind, hub name and an overlapping PID identify the same running agent: its PID lists are unioned. A replacement process does not inherit the old process's PIDs. Unseen, newly published live blocks are retained too.

A busy commit is skipped; startup polling retries within its budget. Both `names.lock` and `labelled-start.lock` record the owner's PID and process start time in `owner.json`. After two minutes, a lock can be reclaimed only if that process has exited or the PID now belongs to a different process. Locks without an owner file retain the two-minute expiry; an unreadable/malformed owner or unavailable process check is left alone. Each state JSON file is atomically replaced and mode 600; the two files are not a single filesystem transaction. Consumers must continue validating PID ancestry, particularly now that the launch prefix defaults off.

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

`saved_at` is a Unix timestamp in seconds. A block may also have `published_at`, the Unix-second timestamp of its startup publication; this producer merge watermark survives subsequent scans of the same running agent. Readers may ignore it. `session_id` identifies the **Rex session**, not a Claude conversation. Only recognised running `claude`, `amp` and `amp-runner` panes are published; exited entries can remain until the next full scan. `pids` includes the foreground process and, when found, the relaunched Claude descendant (searched up to two levels down).

Disabling hub integration removes the map on the next successful save and stops generated prefixes, metadata, columns and validation. Explicit commands/inherited environments remain user-controlled: rex-agents does not strip manually supplied `HUB_NAME` values.

## Optional resume prompt

`resume_prompt` is off by default. It is a temporary workaround for resumed Claude conversations whose background `hub next` waiter did not restart; remove it once chief's hook-based recovery is available. It **costs one model turn per restored Claude session**, and is a request to the agent, not a guarantee that a waiter starts.

Example settings (not enabled by installation):

```lua
hub = true,
resume_prompt = "Session restored after a Rex restart. Check your hub inbox and restart your hub waiter.",
```

The prompt is appended as one shell-quoted positional argument only for a named Claude agent with `hub = true` and a `--resume ID` launch: revive or template-open in continue mode. Fresh launches, Amp, other programs and already-running panes receive no prompt. Saved restore arguments and generated templates omit it, so repeated save/restore cycles do not accumulate prompts. `revive --dry-run` shows the complete command; `status` and `verify` display the configured prompt for future eligible restores. A tab staged with `tab-to-session`/`start-pending` does not get this stopgap.

Checked against Claude Code 2.1.329 `--help`: `[prompt]` is a positional argument, interactive mode is the default, and `--resume` accepts a session ID. No `-p` is added. Tests use fake agents to verify exact argv and quoting; they do not run a real conversation or prove that Claude follows the request.

## chief client rules (v0.1.0-pre.11)

Both `hub mcp` and ordinary CLI commands resolve a name in this order: `--as`, `HUB_NAME`, then `blocks[$REX_BLOCK]` in the map. Empty explicit values count as absent. This describes the consumer, not additional validation performed by rex-agents.

The map is accepted only when:

- It is a regular, user-owned file with no group/other mode bits; symlinks are refused.
- It is at most 1,000,000 bytes and its inode, size and modification time remain unchanged across reading.
- Its JSON has `version: 1` and an integer `saved_at` no more than 600 seconds old or 60 seconds in the future.
- It contains the current block, a valid hub name and listed process IDs.
- A listed PID is an ancestor of the client, with only recognised shells/launchers or the harness's own recognised child in between. A nested agent cannot take its parent's pane name.

For a new agent awaiting publication, the client polls for up to 12 seconds (500 ms between attempts). Unsafe/stale maps are refused without waiting. If no pane name is usable, a recognised agent gets a hub-assigned `<folder>-<harness>` name, with numeric suffixes for collisions. An agent that already took a folder name keeps it for that process lifetime even if a pane name appears later. Outside a recognised agent, ordinary CLI commands fall back to `cli-$USER` and `hub mcp` requires an explicit name. The client does not query Rex.

The pre.11 client reads the fixed default path `~/.local/state/rex-agents/names.json`, **not** rex-agents' state-directory overrides. Keep that in mind when setting `XDG_STATE_HOME` or testing isolated instances. Older clients without this wait/fallback behavior should keep `hub_env = true` until upgraded.
