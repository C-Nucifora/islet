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
  shortcut="$kit/$name.shortcut"
  test -s "$source"
  test -s "$shortcut"
  plutil -lint "$source" >/dev/null
  grep -Fq "$name.shortcut" "$guide"
  grep -Fq "$name.shortcut" "$root/Integrations/Pulse/providers.json"
done

grep -Fq 'Stable identifiers' "$guide"
grep -Fq 'Troubleshooting' "$guide"

if ! "$verify_importability"; then
  exit 0
fi

command -v shortcuts >/dev/null
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/islet-shortcuts.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

for source in "$kit"/sources/*.wflow; do
  name=$(basename "$source" .wflow)
  shortcuts sign --mode anyone --input "$source" --output "$temporary_directory/$name.shortcut"
  shortcuts sign --mode anyone --input "$kit/$name.shortcut" --output "$temporary_directory/$name-resigned.shortcut"
done
