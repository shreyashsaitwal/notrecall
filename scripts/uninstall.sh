#!/bin/sh
# Removes the notrecall-proton Steam compatibility tool, NotProton plugin,
# and staged runtime without deleting any Steam game prefixes or saves.
set -e

NP_SUPPORT="${NOTPROTON_SUPPORT:-$HOME/Library/Application Support/notproton}"
NR_SUPPORT="$HOME/Library/Application Support/notrecall"
TOOL_DST="$HOME/Library/Application Support/Steam/compatibilitytools.d/notrecall-proton"
PLUGIN_DST="$NP_SUPPORT/plugins/50-notrecall.conf"

echo "==> Removing Steam compatibility tool: $TOOL_DST"
rm -rf "$TOOL_DST"

echo "==> Removing NotProton plugin: $PLUGIN_DST"
rm -f "$PLUGIN_DST"

echo "==> Removing staged runtime & launchers: $NR_SUPPORT"
rm -rf "$NR_SUPPORT"

echo "Uninstall complete. Restart Steam to refresh the compatibility tool list."
