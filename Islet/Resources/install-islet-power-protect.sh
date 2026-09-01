#!/bin/zsh

set -eu

if [[ "$#" -ne 2 ]]; then
  echo "Usage: install-islet-power-protect.sh HELPER SUDOERS" >&2
  exit 64
fi

readonly helper_source="$1"
readonly sudoers_source="$2"
readonly helper_destination="/usr/local/libexec/islet-power-protect"
readonly sudoers_destination="/etc/sudoers.d/islet-power-protect"

if [[ ! -f "$helper_source" || ! -f "$sudoers_source" ]]; then
  echo "Power Protect installation files are missing." >&2
  exit 1
fi

/usr/sbin/visudo -cf "$sudoers_source" >/dev/null
/usr/bin/install -d -o root -g wheel -m 0755 /usr/local/libexec
/usr/bin/install -o root -g wheel -m 0755 "$helper_source" "$helper_destination"
/usr/bin/install -o root -g wheel -m 0440 "$sudoers_source" "$sudoers_destination"
/usr/sbin/visudo -cf "$sudoers_destination" >/dev/null
