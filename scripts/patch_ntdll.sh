#!/bin/sh
# Fallback ntdll.dll patcher invoking NotProton/ntdll-patch when a pre-staged
# NotProton CrossOver 26.3 ntdll.dll is not available in ~/Library/Application Support/notproton/bridge.
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
NOTPROTON_DIR="${NOTPROTON_DIR:-$PROJECT_DIR/../NotProton}"
PATCH_DIR="$NOTPROTON_DIR/ntdll-patch"

TARGET_RUNTIME="${1:-}"
if [ -z "$TARGET_RUNTIME" ] || [ ! -d "$TARGET_RUNTIME/lib/wine" ]; then
  echo "Usage: $0 <staged_recall_runtime_dir>" >&2
  exit 1
fi

if [ ! -f "$PATCH_DIR/apply.py" ] || [ ! -x "$PATCH_DIR/build.sh" ]; then
  echo "Error: NotProton ntdll-patch tools not found at $PATCH_DIR (set NOTPROTON_DIR=/path/to/NotProton)." >&2
  exit 1
fi

patch_arch() {
  arch="$1"
  builder="$2"
  payload="$3"
  target="$TARGET_RUNTIME/lib/wine/$arch/ntdll.dll"
  [ -f "$target" ] || return 0
  echo "==> Building $arch detour payload and patching $target"
  (
    cd "$PATCH_DIR"
    ./"$builder" "$target" cx26
    python3 apply.py "$target" "$target.patched" "$PATCH_DIR/$payload"
  )
  mv -f "$target.patched" "$target"
  echo "    OK: patched $target"
}

patch_arch x86_64-windows build.sh   detour2-cx26.bin
patch_arch i386-windows   build32.sh detour32-cx26.bin
