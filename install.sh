#!/bin/bash
# Link this repo into the Omarchy user plugin directory and enable the widget
# to the left of the Bluetooth icon.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
id=$(jq -r .id "$here/manifest.json")
plugins_dir="$HOME/.config/omarchy/plugins"

for bin in openlogi openlogi-desktop; do
  command -v "$bin" >/dev/null || echo "install.sh: warning: $bin not on PATH (install openlogi-bin)" >&2
done

mkdir -p "$plugins_dir"
if [[ -e $plugins_dir/$id && ! -L $plugins_dir/$id ]]; then
  echo "install.sh: $plugins_dir/$id exists and is not a symlink; remove it first" >&2
  exit 1
fi
ln -sfn "$here" "$plugins_dir/$id"

# Validate against the real path: the validator refuses symlinks.
omarchy plugin validate "$here"
omarchy-shell shell rescanPlugins >/dev/null

if grep -q "\"$id\"" "$HOME/.config/omarchy/shell.json"; then
  echo "$id already enabled"
else
  omarchy plugin enable "$id" right --before omarchy.bluetooth
fi
echo "installed $id -> $plugins_dir/$id"
