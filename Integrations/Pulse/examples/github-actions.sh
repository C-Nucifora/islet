#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)

exec swift run \
  --package-path "$repository_root/Integrations/Pulse/GitHubActionsProvider" \
  islet-github-actions watch \
  --pulse-cli "$repository_root/Tools/islet-pulse.swift" \
  "$@"
