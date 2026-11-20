#!/bin/sh
# Stages Recall's Wine + DXMT runtime (from a Recall .dmg, Recall.app,
# runtime.tar.gz, or unpacked runtime directory), wires NotProton's Steamworks
# bridge (ntdll.dll + lsteamclient), and installs the notrecall-proton Steam
# compatibility tool.
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

RUNTIME_SRC=""
HELPERS_SRC=""
RECALL_TEAM_ID="${RECALL_TEAM_ID:-}"
NP_SUPPORT="${NOTPROTON_SUPPORT:-$HOME/Library/Application Support/notproton}"
NR_SUPPORT="$HOME/Library/Application Support/notrecall"
STEAM_COMPAT_DIR="$HOME/Library/Application Support/Steam/compatibilitytools.d"
TOOL_DST="$STEAM_COMPAT_DIR/notrecall-proton"
LEGACY_PLUGIN_DST="$NP_SUPPORT/plugins/50-notrecall.conf"
DRY_RUN=0
RUNTIME_ONLY=0
FORCE_PATCH_NTDLL=0
SKIP_VERIFY=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --runtime <path>  Path to Recall .dmg, Recall.app, runtime.tar.gz, or unpacked runtime directory
  --helpers <dir>   Path to Recall helper binaries (ow2-pipeline/portable-pipeline, pipeline-prepare, pipeline-warm)
  --runtime-only    Update only the staged runtime, Recall helpers, and Steamworks bridge (leaves tool/plugin/prefixes untouched)
  --patch-ntdll     Always patch Recall's own ntdll.dll via scripts/patch_ntdll.sh instead of copying NotProton's 26.3 ntdll.dll
  --skip-verify     Skip codesign verification on Recall.app (for unsigned local/dev builds only)
  --dry-run         Print actions without modifying ~/Library/Application Support
  -h, --help        Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime)
      [ "$#" -ge 2 ] || { echo "Error: $1 requires a path argument" >&2; usage >&2; exit 1; }
      RUNTIME_SRC="$2"; shift 2 ;;
    --helpers)
      [ "$#" -ge 2 ] || { echo "Error: $1 requires a directory argument" >&2; usage >&2; exit 1; }
      HELPERS_SRC="$2"; shift 2 ;;
    --runtime-only) RUNTIME_ONLY=1; shift ;;
    --patch-ntdll)  FORCE_PATCH_NTDLL=1; shift ;;
    --skip-verify)  SKIP_VERIFY=1; shift ;;
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

# 1. Auto-discover Recall runtime (preferring Recall.app bundles so runtime + helpers stay version-locked).
find_recall_runtime() {
  for app in \
    "/Applications/Recall.app" \
    "$HOME/Applications/Recall.app"; do
    if [ -f "$app/Contents/Resources/runtime.tar.gz" ] || [ -x "$app/Contents/Resources/runtime/bin/wine" ]; then
      printf '%s' "$app"
      return 0
    fi
  done
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
    "$ow_root/runtime"; do
    if [ -x "$candidate/bin/wine" ] && [ -d "$candidate/lib/wine/x86_64-unix" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

if [ -z "$RUNTIME_SRC" ]; then
  RUNTIME_SRC=$(find_recall_runtime || true)
fi

if [ -z "$RUNTIME_SRC" ]; then
  echo "Error: Could not locate a Recall release (.dmg, Recall.app, runtime.tar.gz, or bin/wine)." >&2
  echo "Open NotRecall.app to download the latest Recall release automatically, or pass --runtime /path/to/Recall.dmg." >&2
  exit 1
fi

DMG_MOUNT=""
STAGE_RUNTIME="$NR_SUPPORT/.runtime.staging.$$"
OLD_RUNTIME="$NR_SUPPORT/.runtime.old.$$"
cleanup_all() {
  if [ -n "$DMG_MOUNT" ] && [ -d "$DMG_MOUNT" ]; then
    /usr/bin/hdiutil detach -force "$DMG_MOUNT" >/dev/null 2>&1 || true
    rmdir "$DMG_MOUNT" 2>/dev/null || true
  fi
  rm -rf "$STAGE_RUNTIME" 2>/dev/null || true
  if [ -e "$NR_SUPPORT/runtime" ] && [ -e "$OLD_RUNTIME" ]; then
    rm -rf "$OLD_RUNTIME" 2>/dev/null || true
  fi
}
trap cleanup_all EXIT

RECALL_APP_SRC=""
RECALL_HELPERS_DIR=""
RECALL_APP_VERSION=""
RECALL_RUNTIME_VERSION=""
RECALL_EXPECTED_SHA=""

# Detect source type: .dmg, .app bundle, .tar.gz/.tgz archive, or unpacked directory.
case "$RUNTIME_SRC" in
  *.dmg|*.DMG)
    [ -f "$RUNTIME_SRC" ] || { echo "Error: DMG not found: $RUNTIME_SRC" >&2; exit 1; }
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] attach read-only DMG \"$RUNTIME_SRC\", verify Recall.app signature & release.json SHA-256, and extract runtime + helpers"
    else
      DMG_MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/notrecall-dmg.XXXXXX")
      echo "==> Mounting Recall DMG: $RUNTIME_SRC"
      /usr/bin/hdiutil attach -nobrowse -readonly -noverify -mountpoint "$DMG_MOUNT" "$RUNTIME_SRC" >/dev/null
      if [ -d "$DMG_MOUNT/Recall.app" ]; then
        RECALL_APP_SRC="$DMG_MOUNT/Recall.app"
      else
        for candidate_app in "$DMG_MOUNT"/*.app; do
          if [ -d "$candidate_app/Contents/Resources" ]; then
            RECALL_APP_SRC="$candidate_app"
            break
          fi
        done
      fi
      if [ -z "$RECALL_APP_SRC" ]; then
        echo "Error: No Recall.app bundle found inside $RUNTIME_SRC." >&2
        exit 1
      fi
    fi
    ;;
  *.app|*.app/)
    RECALL_APP_SRC="${RUNTIME_SRC%/}"
    [ -d "$RECALL_APP_SRC/Contents/Resources" ] || { echo "Error: Invalid app bundle: $RECALL_APP_SRC" >&2; exit 1; }
    ;;
esac

if [ -n "$RECALL_APP_SRC" ]; then
  if [ "$SKIP_VERIFY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "==> Verifying Recall.app code signature"
    if [ -n "$RECALL_TEAM_ID" ]; then
      /usr/bin/codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$RECALL_TEAM_ID\"" "$RECALL_APP_SRC"
    else
      /usr/bin/codesign --verify --deep --strict "$RECALL_APP_SRC"
    fi
  fi

  release_json="$RECALL_APP_SRC/Contents/Resources/release.json"
  if [ -f "$release_json" ]; then
    RECALL_APP_VERSION=$(/usr/bin/plutil -extract appVersion raw -o - "$release_json" 2>/dev/null || true)
    RECALL_RUNTIME_VERSION=$(/usr/bin/plutil -extract runtimeVersion raw -o - "$release_json" 2>/dev/null || true)
    RECALL_EXPECTED_SHA=$(/usr/bin/plutil -extract runtimeSHA256 raw -o - "$release_json" 2>/dev/null || true)
  fi

  if [ -f "$RECALL_APP_SRC/Contents/Resources/runtime.tar.gz" ]; then
    RUNTIME_SRC="$RECALL_APP_SRC/Contents/Resources/runtime.tar.gz"
  elif [ -x "$RECALL_APP_SRC/Contents/Resources/runtime/bin/wine" ]; then
    RUNTIME_SRC="$RECALL_APP_SRC/Contents/Resources/runtime"
  else
    echo "Error: $RECALL_APP_SRC does not contain Contents/Resources/runtime.tar.gz or runtime/bin/wine." >&2
    exit 1
  fi

  if [ -d "$RECALL_APP_SRC/Contents/Helpers" ]; then
    RECALL_HELPERS_DIR="$RECALL_APP_SRC/Contents/Helpers"
  fi
fi

RUNTIME_IS_ARCHIVE=0
case "$RUNTIME_SRC" in
  *.tar.gz|*.tgz)
    [ -f "$RUNTIME_SRC" ] && RUNTIME_IS_ARCHIVE=1
    ;;
  *.dmg|*.DMG)
    # Only reaches here in --dry-run mode.
    RUNTIME_IS_ARCHIVE=1
    ;;
esac

if [ "$DRY_RUN" -eq 0 ]; then
  if [ "$RUNTIME_IS_ARCHIVE" -eq 0 ] && [ ! -x "$RUNTIME_SRC/bin/wine" ]; then
    echo "Error: Runtime source $RUNTIME_SRC does not contain bin/wine." >&2
    exit 1
  fi
  if [ "$RUNTIME_IS_ARCHIVE" -eq 1 ] && [ -n "$RECALL_EXPECTED_SHA" ]; then
    echo "==> Verifying runtime.tar.gz SHA-256 against Recall release.json"
    actual_sha=$(/usr/bin/shasum -a 256 "$RUNTIME_SRC" | cut -d' ' -f1)
    if [ "$actual_sha" != "$RECALL_EXPECTED_SHA" ]; then
      echo "Error: runtime.tar.gz SHA-256 mismatch (expected $RECALL_EXPECTED_SHA, got $actual_sha)." >&2
      exit 1
    fi
  fi
fi

# 2. Helper discovery: map Recall's ow2-pipeline -> portable-pipeline and keep
# notrecall-sysinfo sourced from NotRecall's own bundle/build directory.
find_helper_bin() {
  bin_name="$1"
  if [ "$bin_name" = "notrecall-sysinfo" ]; then
    search_dirs="$HELPERS_SRC|$PROJECT_DIR/helpers|$PROJECT_DIR/build/helpers"
  else
    search_dirs="$RECALL_HELPERS_DIR|$HELPERS_SRC|$PROJECT_DIR/helpers|$PROJECT_DIR/build/helpers|/Applications/Recall.app/Contents/Helpers|/Applications/Recall.app/Contents/MacOS|$HOME/Applications/Recall.app/Contents/Helpers|$RUNTIME_SRC/../helpers"
  fi
  set -f
  old_ifs=$IFS; IFS='|'
  for candidate in $search_dirs; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate/$bin_name" ]; then
      IFS=$old_ifs
      set +f
      printf '%s' "$candidate/$bin_name"
      return 0
    fi
    # Recall ships portable_pipeline.swift as Contents/Helpers/ow2-pipeline.
    if [ "$bin_name" = "portable-pipeline" ] && [ -x "$candidate/ow2-pipeline" ]; then
      IFS=$old_ifs
      set +f
      printf '%s' "$candidate/ow2-pipeline"
      return 0
    fi
  done
  IFS=$old_ifs
  set +f
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
run_cmd mkdir -p "$NR_SUPPORT" "$NR_SUPPORT/helpers"
if [ "$RUNTIME_ONLY" -eq 0 ]; then
  run_cmd mkdir -p "$TOOL_DST"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$RUNTIME_IS_ARCHIVE" -eq 1 ]; then
    echo "[dry-run] extract \"$RUNTIME_SRC\" into staging dir, wire Steamworks bridge, and atomically replace \"$NR_SUPPORT/runtime\""
  else
    echo "[dry-run] copy \"$RUNTIME_SRC\" into staging dir, wire Steamworks bridge, and atomically replace \"$NR_SUPPORT/runtime\""
  fi
else
  rm -rf "$STAGE_RUNTIME"
  if [ "$RUNTIME_IS_ARCHIVE" -eq 1 ]; then
    mkdir -p "$STAGE_RUNTIME"
    tar -xzf "$RUNTIME_SRC" -C "$STAGE_RUNTIME"
  else
    cp -cR "$RUNTIME_SRC" "$STAGE_RUNTIME" 2>/dev/null || cp -R "$RUNTIME_SRC" "$STAGE_RUNTIME"
  fi
  if [ ! -x "$STAGE_RUNTIME/bin/wine" ] || [ ! -d "$STAGE_RUNTIME/lib/wine/x86_64-unix" ]; then
    echo "Error: Staged runtime from $RUNTIME_SRC did not contain bin/wine and lib/wine/x86_64-unix." >&2
    exit 1
  fi
fi

# 4. Install lsteamclient and patched ntdll.dll into the staged Recall runtime.
echo "==> Wiring NotProton Steamworks bridge into staged Recall runtime"
if [ "$DRY_RUN" -eq 0 ]; then
  copied_lsc_dll=0
  if [ -f "$BRIDGE_SRC/x86_64-windows/lsteamclient.dll" ]; then
    cp -fp "$BRIDGE_SRC/x86_64-windows/lsteamclient.dll" "$STAGE_RUNTIME/lib/wine/x86_64-windows/"
    copied_lsc_dll=1
  elif [ -f "$BRIDGE_SRC/lsteamclient.dll" ]; then
    cp -fp "$BRIDGE_SRC/lsteamclient.dll" "$STAGE_RUNTIME/lib/wine/x86_64-windows/"
    copied_lsc_dll=1
  fi
  if [ -f "$BRIDGE_SRC/i386-windows/lsteamclient.dll" ] && [ -d "$STAGE_RUNTIME/lib/wine/i386-windows" ]; then
    cp -fp "$BRIDGE_SRC/i386-windows/lsteamclient.dll" "$STAGE_RUNTIME/lib/wine/i386-windows/"
  fi
  copied_lsc_so=0
  if [ -f "$BRIDGE_SRC/x86_64-unix/lsteamclient.so" ]; then
    cp -fp "$BRIDGE_SRC/x86_64-unix/lsteamclient.so" "$STAGE_RUNTIME/lib/wine/x86_64-unix/"
    copied_lsc_so=1
  fi
  if [ "$copied_lsc_dll" -ne 1 ] || [ "$copied_lsc_so" -ne 1 ]; then
    echo "Error: NotProton bridge at $BRIDGE_SRC is missing lsteamclient.dll or x86_64-unix/lsteamclient.so." >&2
    exit 1
  fi

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
    cp -fp "$patched_ntdll_dir/x86_64-windows/ntdll.dll" "$STAGE_RUNTIME/lib/wine/x86_64-windows/ntdll.dll"
    if [ -f "$patched_ntdll_dir/i386-windows/ntdll.dll" ] && [ -d "$STAGE_RUNTIME/lib/wine/i386-windows" ]; then
      cp -fp "$patched_ntdll_dir/i386-windows/ntdll.dll" "$STAGE_RUNTIME/lib/wine/i386-windows/ntdll.dll"
    fi
  elif [ -x "$SCRIPT_DIR/patch_ntdll.sh" ]; then
    if [ "$FORCE_PATCH_NTDLL" -eq 1 ]; then
      echo "    --patch-ntdll requested: patching Recall's own ntdll.dll via scripts/patch_ntdll.sh..."
    else
      echo "    No pre-staged 26.3 ntdll.dll in $BRIDGE_SRC/wine/26.3*; trying scripts/patch_ntdll.sh..."
    fi
    if ! "$SCRIPT_DIR/patch_ntdll.sh" "$STAGE_RUNTIME"; then
      echo "Error: Could not patch ntdll.dll via scripts/patch_ntdll.sh." >&2
      echo "Set up CrossOver 26.3 in NotProton (so bridge/wine/26.3* exists) or install mingw-w64 + NotProton/ntdll-patch." >&2
      exit 1
    fi
  else
    echo "Error: No CrossOver 26.3 patched ntdll.dll found under $BRIDGE_SRC/wine/26.3* and patch_ntdll.sh unavailable." >&2
    exit 1
  fi

  # Atomically swap staged runtime into place so failures never destroy a working install.
  rm -rf "$OLD_RUNTIME"
  if [ -e "$NR_SUPPORT/runtime" ]; then
    mv "$NR_SUPPORT/runtime" "$OLD_RUNTIME"
  fi
  if mv "$STAGE_RUNTIME" "$NR_SUPPORT/runtime"; then
    rm -rf "$OLD_RUNTIME" 2>/dev/null || true
  else
    [ ! -e "$OLD_RUNTIME" ] || mv "$OLD_RUNTIME" "$NR_SUPPORT/runtime" || true
    exit 1
  fi

  # Record the installed Recall release metadata & copy licenses when extracted from Recall.app.
  if [ -n "$RECALL_APP_SRC" ]; then
    if [ -f "$RECALL_APP_SRC/Contents/Resources/release.json" ]; then
      cp -f "$RECALL_APP_SRC/Contents/Resources/release.json" "$NR_SUPPORT/recall-release.json.tmp.$$" && \
        mv -f "$NR_SUPPORT/recall-release.json.tmp.$$" "$NR_SUPPORT/recall-release.json"
    elif [ -n "$RECALL_APP_VERSION" ]; then
      printf '{"appVersion":"%s","runtimeVersion":"%s"}\n' "$RECALL_APP_VERSION" "$RECALL_RUNTIME_VERSION" > "$NR_SUPPORT/recall-release.json.tmp.$$" && \
        mv -f "$NR_SUPPORT/recall-release.json.tmp.$$" "$NR_SUPPORT/recall-release.json"
    else
      rm -f "$NR_SUPPORT/recall-release.json"
    fi
    if [ -d "$RECALL_APP_SRC/Contents/Resources/Licenses" ]; then
      rm -rf "$NR_SUPPORT/licenses/recall"
      mkdir -p "$NR_SUPPORT/licenses/recall"
      cp -R "$RECALL_APP_SRC/Contents/Resources/Licenses/." "$NR_SUPPORT/licenses/recall/"
      for notice in PROJECT-LICENSE.txt NOTICE.txt; do
        [ -f "$RECALL_APP_SRC/Contents/Resources/$notice" ] && cp -f "$RECALL_APP_SRC/Contents/Resources/$notice" "$NR_SUPPORT/licenses/recall/$notice"
      done
    fi
  else
    rm -f "$NR_SUPPORT/recall-release.json"
  fi
else
  if [ "$FORCE_PATCH_NTDLL" -eq 1 ]; then
    echo "[dry-run] copy lsteamclient.{dll,so} and patch Recall's own ntdll.dll via scripts/patch_ntdll.sh"
  else
    echo "[dry-run] copy lsteamclient.{dll,so} and patched 26.3 ntdll.dll (or fallback via patch_ntdll.sh)"
  fi
fi

# 5. Stage Recall shader helpers (always refreshed with runtime updates so they stay
# ABI-locked to DXMT) and NotRecall's own helpers (pipeline_hook.sh, notrecall-sysinfo).
stage_recall_helpers() {
  echo "==> Installing shader pipeline helpers"
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
    echo "    Note: portable-pipeline helper not found (in-game DXMT shader caching still works; pass --helpers or use a Recall .dmg/.app to enable offline precompilation)."
  elif [ -n "$missing_helpers" ]; then
    echo "    Warning: missing companion helper(s):$missing_helpers" >&2
    echo "    Use a Recall .dmg or Recall.app for full offline precompilation & warming." >&2
  fi
}

if [ "$RUNTIME_ONLY" -eq 1 ]; then
  if [ -n "$RECALL_HELPERS_DIR" ] || [ -n "$HELPERS_SRC" ]; then
    stage_recall_helpers
  fi
  echo ""
  echo "Done! Updated NotRecall runtime${RECALL_APP_VERSION:+ (Recall $RECALL_APP_VERSION)} only (Steam prefixes, shader caches, and plugin untouched)."
  exit 0
fi

stage_recall_helpers
run_cmd cp -f "$PROJECT_DIR/scripts/pipeline_hook.sh" "$NR_SUPPORT/helpers/pipeline_hook.sh"
run_cmd chmod 755 "$NR_SUPPORT/helpers/pipeline_hook.sh"
sysinfo_bin=$(find_helper_bin "notrecall-sysinfo" || true)
if [ -n "$sysinfo_bin" ]; then
  echo "    Staging notrecall-sysinfo from: $sysinfo_bin"
  run_cmd cp -f "$sysinfo_bin" "$NR_SUPPORT/helpers/notrecall-sysinfo"
  run_cmd chmod 755 "$NR_SUPPORT/helpers/notrecall-sysinfo"
fi

# 6. Install Steam compatibility tool bundle and remove any legacy NotProton plugin.
echo "==> Installing Steam compatibility tool to: $TOOL_DST"
run_cmd cp -f "$PROJECT_DIR/compat/compatibilitytool.vdf" "$TOOL_DST/compatibilitytool.vdf"
run_cmd cp -f "$PROJECT_DIR/compat/toolmanifest.vdf" "$TOOL_DST/toolmanifest.vdf"
run_cmd cp -f "$PROJECT_DIR/compat/run" "$TOOL_DST/run"
run_cmd chmod 755 "$TOOL_DST/run"

if [ -f "$LEGACY_PLUGIN_DST" ]; then
  echo "==> Removing legacy NotProton plugin: $LEGACY_PLUGIN_DST"
  run_cmd rm -f "$LEGACY_PLUGIN_DST"
fi

echo ""
echo "Done!${RECALL_APP_VERSION:+ Installed Recall $RECALL_APP_VERSION runtime.} Restart Steam, then select 'NotRecall (Recall Wine + DXMT)' under:"
echo "  Game -> Properties -> Compatibility -> Force the use of a specific Steam Play compatibility tool"
echo "Configure MetalFX, Metal HUD, mouse mode, and other options directly in NotRecall.app (leave Steam Launch Options blank)."
