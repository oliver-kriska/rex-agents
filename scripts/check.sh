#!/bin/sh
# The same non-interactive checks run locally and in CI. No live Rex access.
set -eu
cd "$(dirname "$0")/.."

git ls-files -z '*.sh' bin/rex-agents | xargs -0 shellcheck
luacheck rex-agents tests/*.lua examples/*.lua
actionlint

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export REX_AGENTS_CONFIG="$T/no-config.lua"
unset LUA_INIT LUA_INIT_5_4 LUA_PATH_5_4
lua_version=$(lua -e 'io.write((_VERSION:gsub("Lua ", "")))')
rocks=$(mise where http:luacheck)
export LUA_PATH="$rocks/share/lua/$lua_version/?.lua;;"
lua tests/unit-runner.lua
sh tests/setup.sh

export HOMEBREW_NO_AUTO_UPDATE=1
brew style Formula/rex-agents.rb
brew ruby tests/formula.rb
printf '%s\n' 'All local/CI checks passed. Run Rex e2e separately before release.'
