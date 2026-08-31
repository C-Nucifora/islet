#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || ! printf '%s' "$1" | grep -Eq '^[a-p]{32}$'; then
  echo "usage: $0 CHROME_EXTENSION_ID" >&2
  exit 64
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
host_path="$script_dir/native_host.py"
destination="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
manifest="$destination/dev.islet.pulse.chrome_downloads.json"

mkdir -p "$destination"
escaped_host=$(printf '%s' "$host_path" | sed 's/[\/&]/\\&/g')
sed -e "s/__HOST_PATH__/$escaped_host/" -e "s/__EXTENSION_ID__/$1/" \
  "$script_dir/native-host-manifest.json" > "$manifest"
chmod 600 "$manifest"
chmod 755 "$host_path"
echo "Installed $manifest"
