#!/bin/sh
set -eu

usage() {
  printf '%s\n' "usage: $0 [--verify-importability]" >&2
  exit 64
}

verify_importability=false
case "${1-}" in
  '') ;;
  --verify-importability) verify_importability=true ;;
  *) usage ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
kit="$root/Integrations/Pulse/shortcuts"
guide="$kit/README.md"
test -f "$guide"

for name in 01-transient-event 02-progress-task 03-failed-task 04-guarded-completion 05-focus-profile 06-focus-timer; do
  source="$kit/sources/$name.wflow"
  test -s "$source"
  test ! -e "$kit/$name.shortcut"
  plutil -lint "$source" >/dev/null
  asset_url="https://github.com/C-Nucifora/islet/releases/latest/download/$name.shortcut"
  grep -Fq "$asset_url" "$guide"
  grep -Fq "$asset_url" "$root/Integrations/Pulse/providers.json"
done

grep -Fq 'Stable identifiers' "$guide"
grep -Fq 'Troubleshooting' "$guide"
plutil -extract WFWorkflowActions xml1 -o - \
  "$kit/sources/04-guarded-completion.wflow" | grep -Fq '<key>expirySeconds</key>'

if ! "$verify_importability"; then
  exit 0
fi

command -v shortcuts >/dev/null
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/islet-shortcuts.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

for source in "$kit"/sources/*.wflow; do
  name=$(basename "$source" .wflow)
  shortcuts sign --mode anyone --input "$source" --output "$temporary_directory/$name.shortcut"
  test -s "$temporary_directory/$name.shortcut"
done
