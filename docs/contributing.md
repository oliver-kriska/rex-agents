# Contributing and verification

Keep extension code compatible with Rex's Lua 5.1 environment. Use `rex.exec`, not `io.popen` or `os.execute`; the standalone test adapter is the exception. Include regression tests and accurate CLI/config docs. Report minimal reproductions and tool versions, with sensitive commands, paths and conversation IDs removed.

## Local checks and CI

On macOS, install [mise](https://mise.jdx.dev/) 2026.11.9 or newer, Xcode Command Line Tools (`cc`/`make`), and Homebrew for formula checks. From the checkout:

```sh
mise install
make check
```

`make check` selects pinned tools via `mise exec`; shell activation is unnecessary. It runs ShellCheck, Luacheck (Lua 5.1 globals), actionlint, unit tests, isolated setup/uninstall tests, Homebrew style and the packaging test. It does not load the real watcher, access live Rex sessions, change taps or install rex-agents.

CI installs/caches these tools using SHA-pinned `jdx/mise-action`, then calls the same command. A strict Homebrew metadata audit runs separately in a disposable CI tap. Neither that audit nor the packaging test fetches the release tarball or proves its checksum; the [release install check](../RELEASING.md#4-test-the-stable-formula) does.

## Tool versions

- `.tool-versions`: Lua **5.4.9**, ShellCheck **0.11.0**, actionlint **1.7.12**. The `aqua:` names select prebuilt binaries through mise; plain asdf needs equivalent plugins.
- `mise.toml`: source archives and SHA-256 digests for Luacheck **1.2.0** (no macOS binary) and LuaRocks **3.13.0**. Also pins argparse **0.7.1-1**, LuaFileSystem **1.8.0-1** and test-only dkjson **2.8-2**. Installation options need TOML rather than version-only rows.
- Lua builds from source. A first install needs a C compiler and network. The Lua plugin's optional LuaRocks copy is not used by these checks.
- `.miserc.toml` stops parent-directory config discovery; a parent `.tool-versions` cannot supply project tools. User-global mise settings still apply.

Dependabot groups weekly GitHub Actions updates, not these pins or CI's mise version. See [updating development tools](../RELEASING.md#updating-development-tools) for deliberate version/checksum bumps and fresh-install validation.

## Rex integration tests

Never test against a live work session. Run separately with `cc`, `jq`, `python3`, **fzf** and a Rex binary:

```sh
REX_BIN=/path/to/rex tests/e2e.sh
```

Tested versions are **0.1.0-preview.18 (API 13)**, **preview.20 (API 16)**, **preview.21 (API 18)** and **preview.23 (API 19)**. Confirm each binary with `version` first. CI does not download Rex: no unattended, version-pinned distribution is configured.

E2e starts private throwaway servers, pins every client with `--autostart=false -S`, and stops only verified test-owned PIDs with SIGTERM. It runs fake Claude/Amp programs, not real accounts, and runs the unit suite inside Rex. Cases cover save/restart/revive, actual fzf selection/cancellation, service selection, templates, readiness, duplicate guards and hub opt-in/out.

Native prompt tests cover every fallback reason using registered actions. E2e verifies the real `no_client` fallback on preview.21, missing-UI fallback on older servers, `--only`, mode-600 last-used state, and immediate PID publication through revive/template-open/start-pending. Timing includes CLI invocation and verification overhead, with delayed launches, relaunched children, absent conversation metadata, timeout and concurrent-save cases.

Before release, manually test on a compatible app connected **only to a test server**: native multi-select/empty selection, filtering, Escape, template Continue/Fresh, save-name editing/cancellation, and park Keep/Close with a busy-turn warning. Inspect layout and keyboard navigation. Headless tests cannot verify the app's rendering; no working session is needed or appropriate for this check.

Explicit `-S` avoids preview.18's fallback to the home server when an environment-selected endpoint is unavailable (fixed upstream in preview.19). On preview.20, start-pending's `write` works on newly created blocks despite their ownership state.

Setup tests use a disposable HOME **and stub launchctl and Rex**. Changing HOME alone does not isolate launchd. Do not run real setup, watcher bootstrap, or uninstall against your user launchd domain for tests.

## Test environment overrides

| Variable | Override |
| --- | --- |
| `REX_AGENTS_STATE` | State directory. |
| `REX_AGENTS_TEMPLATES` | Template directory. |
| `REX_AGENTS_CLAUDE_SESSIONS` | Claude session-file directory. |
| `REX_AGENTS_CONFIG` | Local Lua settings file. |
| `REX_AGENTS_SERVER` | Explicit Rex endpoint, ahead of `REX_SERVER`. |
| `REX_AGENTS_REX` | Rex executable. |
| `REX_AGENTS_WATCH_LABEL` | Watcher label; `-` disables launchd inspection. |
| `REX_AGENTS_NOTIFY_CMD` | Notification replacement, invoked as `CMD TITLE TEXT`. |
| `REX_AGENTS_STABLE_ROOT` | Homebrew supplies its stable opt path to setup. |

Use private directories for all test state; do not copy real credentials or settings. Live application restart, real agent compatibility and Homebrew release installation are separate checks, not claims made by the fake-agent suite.
