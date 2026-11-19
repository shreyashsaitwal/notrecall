#!/bin/sh
# Stages Recall's Wine + DXMT runtime, wires NotProton's Steamworks bridge
# (ntdll.dll + lsteamclient), and installs the notrecall-proton Steam
# compatibility tool and NotProton UI plugin.
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

RUNTIME_SRC=""
HELPERS_SRC=""
NP_SUPPORT="${NOTPROTON_SUPPORT:-$HOME/Library/Application Support/notproton}"
NR_SUPPORT="$HOME/Library/Application Support/notrecall"
STEAM_COMPAT_DIR="$HOME/Library/Application Support/Steam/compatibilitytools.d"
TOOL_DST="$STEAM_COMPAT_DIR/notrecall-proton"
PLUGIN_DST="$NP_SUPPORT/plugins/50-notrecall.conf"
DRY_RUN=0
RUNTIME_ONLY=0
FORCE_PATCH_NTDLL=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --runtime <path>  Path to Recall runtime directory or runtime.tar.gz archive
  --helpers <dir>   Path to Recall helper binaries (portable-pipeline, pipeline-prepare, pipeline-warm)
  --runtime-only    Update only the staged runtime + Steamworks bridge (leaves tool/plugin/prefixes untouched)
  --patch-ntdll     Always patch Recall's own ntdll.dll via scripts/patch_ntdll.sh instead of copying NotProton's 26.3 ntdll.dll
  --dry-run         Print actions without modifying ~/Library/Application Support
  -h, --help        Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime)      RUNTIME_SRC="${2:-}"; shift 2 ;;
    --helpers)      HELPERS_SRC="${2:-}"; shift 2 ;;
    --runtime-only) RUNTIME_ONLY=1; shift ;;
    --patch-ntdll)  FORCE_PATCH_NTDLL=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

run_cmd() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# 1. Auto-discover Recall runtime (prefer NotRecall's own bundled runtime.tar.gz first).
find_recall_runtime() {
  for bundled in \
    "$PROJECT_DIR/runtime.tar.gz" \
    "$PROJECT_DIR/build/runtime.tar.gz"; do
    if [ -f "$bundled" ]; then
      printf '%s' "$bundled"
      return 0
    fi
  done
  ow_root="$HOME/Library/Application Support/Overwatch2Mac"
  if [ -d "$ow_root/runtimes" ]; then
    # Prefer newest version directory under Overwatch2Mac/runtimes/<ver>.
    best_candidate=""
    best_mtime=-1
    for candidate in "$ow_root/runtimes"/*; do
      [ -d "$candidate" ] || continue
      if [ -x "$candidate/bin/wine" ] && [ -d "$candidate/lib/wine/x86_64-unix" ]; then
        mtime=$(/usr/bin/stat -f '%m' -- "$candidate" 2>/dev/null) || mtime=0
        if [ "$mtime" -gt "$best_mtime" ]; then
          best_mtime="$mtime"
          best_candidate="$candidate"
        fi
      fi
    done
    if [ -n "$best_candidate" ]; then
      printf '%s' "$best_candidate"
      return 0
    fi
  fi
  for candidate in \
    "$ow_root/runtime/current" \
    "$ow_root/runtime" \
    "/Applications/Recall.app/Contents/Resources/runtime"; do
    if [ -x "$candidate/bin/wine" ] && [ -d "$candidate/lib/wine/x86_64-unix" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  for archive in \
    "/Applications/Recall.app/Contents/Resources/runtime.tar.gz" \
    "$HOME/Applications/Recall.app/Contents/Resources/runtime.tar.gz"; do
    if [ -f "$archive" ]; then
      printf '%s' "$archive"
      return 0
    fi
  done
  return 1
}

if [ -z "$RUNTIME_SRC" ]; then
  RUNTIME_SRC=$(find_recall_runtime || true)
fi

RUNTIME_IS_ARCHIVE=0
case "$RUNTIME_SRC" in
  *.tar.gz|*.tgz)
    [ -f "$RUNTIME_SRC" ] && RUNTIME_IS_ARCHIVE=1
    ;;
esac

if [ -z "$RUNTIME_SRC" ] || { [ "$RUNTIME_IS_ARCHIVE" -eq 0 ] && [ ! -x "$RUNTIME_SRC/bin/wine" ]; }; then
  echo "Error: Could not locate a Recall runtime (expected bundled runtime.tar.gz or bin/wine)." >&2
  echo "Run 'make build-runtime' to build from ./recall, or pass --runtime /path/to/runtime.tar.gz." >&2
  exit 1
fi

# 2. Auto-discover Recall shader pipeline helpers per binary (preferring
# NotRecall's own bundled helpers inside Contents/Resources/helpers or build/helpers).
find_helper_bin() {
  bin_name="$1"
  search_dirs="$HELPERS_SRC|$PROJECT_DIR/helpers|$PROJECT_DIR/build/helpers|/Applications/Recall.app/Contents/Helpers|/Applications/Recall.app/Contents/MacOS|$HOME/Applications/Recall.app/Contents/Helpers|$RUNTIME_SRC/../helpers"
  old_ifs=$IFS; IFS='|'
  for candidate in $search_dirs; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate/$bin_name" ]; then
      IFS=$old_ifs
      printf '%s' "$candidate/$bin_name"
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

# 3. Verify NotProton's Steamworks bridge is available.
BRIDGE_SRC="$NP_SUPPORT/bridge"
if [ ! -d "$BRIDGE_SRC" ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "Error: NotProton bridge not found at $BRIDGE_SRC." >&2
  echo "Open NotProton and click Install first so its Steamworks bridge is staged." >&2
  exit 1
fi

echo "==> Staging Recall runtime from: $RUNTIME_SRC"
run_cmd mkdir -p "$NR_SUPPORT" "$NR_SUPPORT/helpers" "$TOOL_DST" "$NP_SUPPORT/plugins"
if [ -d "$NR_SUPPORT/runtime" ]; then
  run_cmd rm -rf "$NR_SUPPORT/runtime"
fi
if [ "$RUNTIME_IS_ARCHIVE" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] mkdir -p \"$NR_SUPPORT/runtime\" && tar -xzf \"$RUNTIME_SRC\" -C \"$NR_SUPPORT/runtime\""
  else
    mkdir -p "$NR_SUPPORT/runtime"
    tar -xzf "$RUNTIME_SRC" -C "$NR_SUPPORT/runtime"
    if [ ! -x "$NR_SUPPORT/runtime/bin/wine" ]; then
      echo "Error: Extracted $RUNTIME_SRC did not contain bin/wine." >&2
      exit 1
    fi
  fi
else
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] cp -cR \"$RUNTIME_SRC\" \"$NR_SUPPORT/runtime\""
  else
    cp -cR "$RUNTIME_SRC" "$NR_SUPPORT/runtime" 2>/dev/null || cp -R "$RUNTIME_SRC" "$NR_SUPPORT/runtime"
  fi
fi

# 4. Install lsteamclient and patched ntdll.dll into the staged Recall runtime.
# Recall's wine-ntdll-syscall-log.patch only modifies ntdll.so (Unix side); its
# ntdll.dll is unmodified CrossOver 26.3.0, so NotProton's CrossOver 26.3 patched
# ntdll.dll pairs cleanly with Recall's ntdll.so.
echo "==> Wiring NotProton Steamworks bridge into staged Recall runtime"
if [ "$DRY_RUN" -eq 0 ]; then
  [ -f "$BRIDGE_SRC/x86_64-windows/lsteamclient.dll" ] && \
    cp -fp "$BRIDGE_SRC/x86_64-windows/lsteamclient.dll" "$NR_SUPPORT/runtime/lib/wine/x86_64-windows/"
  [ -f "$BRIDGE_SRC/lsteamclient.dll" ] && \
    cp -fp "$BRIDGE_SRC/lsteamclient.dll" "$NR_SUPPORT/runtime/lib/wine/x86_64-windows/"
  [ -f "$BRIDGE_SRC/i386-windows/lsteamclient.dll" ] && [ -d "$NR_SUPPORT/runtime/lib/wine/i386-windows" ] && \
    cp -fp "$BRIDGE_SRC/i386-windows/lsteamclient.dll" "$NR_SUPPORT/runtime/lib/wine/i386-windows/"
  [ -f "$BRIDGE_SRC/x86_64-unix/lsteamclient.so" ] && \
    cp -fp "$BRIDGE_SRC/x86_64-unix/lsteamclient.so" "$NR_SUPPORT/runtime/lib/wine/x86_64-unix/"

  patched_ntdll_dir=""
  if [ "$FORCE_PATCH_NTDLL" -eq 0 ]; then
    for d in "$BRIDGE_SRC"/wine/26.3*; do
      if [ -f "$d/x86_64-windows/ntdll.dll" ]; then
        patched_ntdll_dir="$d"
        break
      fi
    done
  fi
  if [ -n "$patched_ntdll_dir" ]; then
    echo "    Using NotProton patched CrossOver 26.3 ntdll.dll from: $patched_ntdll_dir"
    cp -fp "$patched_ntdll_dir/x86_64-windows/ntdll.dll" "$NR_SUPPORT/runtime/lib/wine/x86_64-windows/ntdll.dll"
    if [ -f "$patched_ntdll_dir/i386-windows/ntdll.dll" ] && [ -d "$NR_SUPPORT/runtime/lib/wine/i386-windows" ]; then
      cp -fp "$patched_ntdll_dir/i386-windows/ntdll.dll" "$NR_SUPPORT/runtime/lib/wine/i386-windows/ntdll.dll"
    fi
  elif [ -x "$SCRIPT_DIR/patch_ntdll.sh" ]; then
    if [ "$FORCE_PATCH_NTDLL" -eq 1 ]; then
      echo "    --patch-ntdll requested: patching Recall's own ntdll.dll via scripts/patch_ntdll.sh..."
    else
      echo "    No pre-staged 26.3 ntdll.dll in $BRIDGE_SRC/wine/26.3*; trying scripts/patch_ntdll.sh..."
    fi
    if ! "$SCRIPT_DIR/patch_ntdll.sh" "$NR_SUPPORT/runtime"; then
      echo "Error: Could not patch ntdll.dll via scripts/patch_ntdll.sh." >&2
      echo "Set up CrossOver 26.3 in NotProton (so bridge/wine/26.3* exists) or install mingw-w64 + NotProton/ntdll-patch." >&2
      exit 1
    fi
  else
    echo "Error: No CrossOver 26.3 patched ntdll.dll found under $BRIDGE_SRC/wine/26.3* and patch_ntdll.sh unavailable." >&2
    exit 1
  fi
else
  if [ "$FORCE_PATCH_NTDLL" -eq 1 ]; then
    echo "[dry-run] copy lsteamclient.{dll,so} and patch Recall's own ntdll.dll via scripts/patch_ntdll.sh"
  else
    echo "[dry-run] copy lsteamclient.{dll,so} and patched 26.3 ntdll.dll (or fallback via patch_ntdll.sh)"
  fi
fi

if [ "$RUNTIME_ONLY" -eq 1 ]; then
  echo ""
  echo "Done! Updated NotRecall runtime only (Steam prefixes, shader caches, and plugin untouched)."
  exit 0
fi

# 5. Stage pipeline hook and optional Recall offline shader precompilation helpers.
echo "==> Installing shader pipeline helpers"
run_cmd cp -f "$PROJECT_DIR/scripts/pipeline_hook.sh" "$NR_SUPPORT/helpers/pipeline_hook.sh"
run_cmd chmod 755 "$NR_SUPPORT/helpers/pipeline_hook.sh"
staged_helpers=0
missing_helpers=""
for bin in portable-pipeline pipeline-prepare pipeline-warm libpipeline_prepare.dylib; do
  found_bin=$(find_helper_bin "$bin" || true)
  if [ -n "$found_bin" ]; then
    echo "    Staging $bin from: $found_bin"
    run_cmd cp -f "$found_bin" "$NR_SUPPORT/helpers/$bin"
    run_cmd chmod 755 "$NR_SUPPORT/helpers/$bin"
    staged_helpers=$((staged_helpers + 1))
  elif [ "$bin" != "libpipeline_prepare.dylib" ]; then
    missing_helpers="$missing_helpers $bin"
  fi
done
if [ "$staged_helpers" -eq 0 ]; then
  echo "    Note: portable-pipeline helper not found (in-game DXMT shader caching still works; pass --helpers to enable offline precompilation)."
elif [ -n "$missing_helpers" ]; then
  echo "    Warning: missing companion helper(s):$missing_helpers" >&2
  echo "    Copy pipeline-prepare and pipeline-warm from Recall.app/Contents/Helpers for full offline precompilation & warming." >&2
fi

# 6. Install Steam compatibility tool bundle and NotProton UI plugin.
echo "==> Installing Steam compatibility tool to: $TOOL_DST"
run_cmd cp -f "$PROJECT_DIR/compat/compatibilitytool.vdf" "$TOOL_DST/compatibilitytool.vdf"
run_cmd cp -f "$PROJECT_DIR/compat/toolmanifest.vdf" "$TOOL_DST/toolmanifest.vdf"
run_cmd cp -f "$PROJECT_DIR/compat/run" "$TOOL_DST/run"
run_cmd chmod 755 "$TOOL_DST/run"

echo "==> Installing NotProton plugin descriptor to: $PLUGIN_DST"
run_cmd cp -f "$PROJECT_DIR/plugins/50-notrecall.conf" "$PLUGIN_DST"

echo ""
echo "Done! Restart Steam, then select 'NotRecall (Recall Wine + DXMT)' under:"
echo "  Game -> Properties -> Compatibility -> Force the use of a specific Steam Play compatibility tool"
