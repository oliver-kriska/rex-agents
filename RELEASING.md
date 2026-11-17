# Releasing rex-agents

The repository is both source code and a Homebrew tap. A release tag selects the source
archive; the formula on `main` supplies its checksum. For v0.1.0 the formula already names
the tag, but its all-zero SHA-256 is a **release blocker**, not a usable checksum.

These are maintainer steps, not an automatic release script. Tags, pushes, releases and
installation require the maintainer's approval. Do not run setup or tests against a live Rex
session as part of packaging validation.

## 1. Check the release candidate

- Run the tests and linters listed in [README.md](README.md#contributing-and-tests).
- Run `tests/e2e.sh` separately with the preview.18 and preview.20 binaries using `REX_BIN`.
  Confirm each binary with its `version` command first.
- Wait for the candidate's GitHub Actions run to pass. E2e is local-only; CI does not install Rex.
- Review the changelog and the release diff for private paths, state files and credentials.
- For later releases, update the formula URL and changelog version before tagging.

## 2. Tag the reviewed source

From a clean checkout of the reviewed commit:

```sh
git tag -a v0.1.0 -m 'rex-agents v0.1.0'
git push origin v0.1.0
```

Do not move an existing published tag. The tagged formula may contain the checksum placeholder;
the formula that users install comes from the tap's `main` branch, updated in the next step.

## 3. Hash the actual GitHub tarball

```sh
archive=$(mktemp -t rex-agents-v0.1.0)
curl --fail --location --retry 3 \
  https://github.com/oliver-kriska/rex-agents/archive/refs/tags/v0.1.0.tar.gz \
  --output "$archive"
shasum -a 256 "$archive"
tar -tzf "$archive" | head
rm "$archive"
```

Use that digest to replace `sha256` in `Formula/rex-agents.rb`; remove its release-blocker
comment. Do not hash a locally generated `git archive`: its bytes need not match GitHub's.
Remove the temporary release-preparation notice from the README and mark the changelog entry
with the release date. Commit these as a follow-up on `main`, then push after review. Do not
retag the source commit to include the checksum: that would change the archive being hashed.

## 4. Test the stable formula

On a disposable macOS account or machine with Homebrew (not the live development setup):

```sh
brew tap oliver-kriska/rex-agents https://github.com/oliver-kriska/rex-agents
brew update
brew style oliver-kriska/rex-agents/rex-agents
brew audit --strict --formula oliver-kriska/rex-agents/rex-agents
brew install --build-from-source oliver-kriska/rex-agents/rex-agents
brew test oliver-kriska/rex-agents/rex-agents
rex-agents setup --help
```

If that formula is already installed on the disposable machine, use `brew reinstall
--build-from-source` instead. Check the installed wrapper points through `opt/rex-agents`,
not a fixed Cellar version. Installation alone must not load a watcher or alter Rex config.
Setup/uninstall behaviour is separately covered by `sh tests/setup.sh`, which stubs both
launchctl and Rex; changing HOME alone is not safe isolation for launchd.

The CI metadata audit and local `tests/formula.rb` packaging check do **not** fetch the
release tarball or prove its checksum. A successful build-from-source install is required
before announcing stable availability. Keep `head` in the formula for development installs.

## 5. Publish release notes

After the stable installation check passes, create the GitHub release for the existing tag
using the [changelog](CHANGELOG.md). Confirm the README's stable install commands work. No
bottles are required: the formula installs scripts and Lua modules without compilation.

## Updating development tools

Dependabot updates GitHub Actions only. Review tool releases and update their exact pins
in `.tool-versions` and `mise.toml` deliberately. To bump the registry-backed tools without
upgrading user-global tools or the checksum-pinned source archives:

```sh
mise upgrade --bump --pin --no-global lua aqua:koalaman/shellcheck aqua:rhysd/actionlint
```

For LuaRocks or Luacheck, update the version and checksum together in `mise.toml`, using the
digest of the upstream archive. Review the pinned argparse, LuaFileSystem and dkjson rock
versions there too. After changing Lua or rock dependencies, rebuild the source tools even
if their own versions did not change; their installed wrappers refer to the Lua build:

```sh
mise install --force http:luarocks http:luacheck
make check
```

Update the README's version list and the CI mise version when appropriate. Keep the minimum
mise version in `mise.toml` aligned with the config features used. Test a fresh checkout with
empty `MISE_DATA_DIR`, `MISE_CACHE_DIR` and `MISE_CONFIG_DIR` before merging tool updates,
then run Rex e2e on both supported versions. Homebrew's own formula lint/audit tooling follows
Homebrew, rather than a mise pin. No development-tool update changes the installed extension.
