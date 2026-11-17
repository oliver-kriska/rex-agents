#!/bin/sh
# Git-clone installs share the same setup as the Homebrew entrypoint.
exec /bin/sh "$(dirname "$0")/setup.sh" "$@"
