#!/bin/sh
# Removes the notrecall-proton Steam compatibility tool, staged runtime/settings,
# downloaded Recall DMG cache, and any legacy NotProton plugin without deleting
# Steam game prefixes or saves.
set -e

NP_SUPPORT="${NOTPROTON_SUPPORT:-$HOME/Library/Application Support/notproton}"
NR_SUPPORT="$HOME/Library/Application Support/notrecall"
NR_CACHE="$HOME/Library/Caches/notrecall"
TOOL_DST="$HOME/Library/Application Support/Steam/compatibilitytools.d/notrecall-proton"
LEGACY_PLUGIN_DST="$NP_SUPPORT/plugins/notrecall.conf"

echo "==> Removing Steam compatibility tool: $TOOL_DST"
rm -rf "$TOOL_DST"

if [ -e "$LEGACY_PLUGIN_DST" ] || [ -L "$LEGACY_PLUGIN_DST" ]; then
  echo "==> Removing legacy NotProton plugin: $LEGACY_PLUGIN_DST"
  rm -f "$LEGACY_PLUGIN_DST"
fi

echo "==> Removing staged runtime, launchers & settings: $NR_SUPPORT"
rm -rf "$NR_SUPPORT"

if [ -d "$NR_CACHE" ]; then
  echo "==> Removing downloaded Recall cache: $NR_CACHE"
  rm -rf "$NR_CACHE"
fi

echo "Uninstall complete. Restart Steam to refresh the compatibility tool list."
