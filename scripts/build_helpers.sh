#!/bin/sh
# Builds Recall's native shader pipeline helpers from the in-tree ./recall submodule:
#   - portable-pipeline (always; patched to honor DXMT_PIPELINE_CACHE_NAMESPACE)
#   - libpipeline_prepare.dylib, pipeline-prepare, pipeline-warm (when DXMT source
#     is available in WORK_DIR/dxmt-source or DXMT_SOURCE)
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
if [ -z "${RECALL_DIR:-}" ]; then
  if [ -d "$PROJECT_DIR/recall" ]; then
    RECALL_DIR="$PROJECT_DIR/recall"
  else
    RECALL_DIR="$PROJECT_DIR/../recall"
  fi
fi
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/build/helpers}"
WORK_DIR="${WORK_DIR:-$PROJECT_DIR/build/phase-2}"
DXMT_SOURCE="${DXMT_SOURCE:-$WORK_DIR/dxmt-source}"

SRC_SWIFT="$RECALL_DIR/scripts/portable_pipeline.swift"
if [ ! -f "$SRC_SWIFT" ]; then
  echo "Error: Could not find $SRC_SWIFT (set RECALL_DIR=/path/to/recall)." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TMP_SWIFT=$(mktemp "$OUT_DIR/portable_pipeline.XXXXXX.swift")
trap 'rm -f "$TMP_SWIFT"' EXIT

# Allow DXMT_PIPELINE_CACHE_NAMESPACE override while defaulting to ow2-source-v1.
sed 's|let namespaceBuild = "ow2-source-v1"|let namespaceBuild = ProcessInfo.processInfo.environment["DXMT_PIPELINE_CACHE_NAMESPACE"] ?? "ow2-source-v1"|' \
  "$SRC_SWIFT" > "$TMP_SWIFT"

echo "==> Compiling portable-pipeline -> $OUT_DIR/portable-pipeline"
xcrun swiftc -O "$TMP_SWIFT" -o "$OUT_DIR/portable-pipeline" \
  -framework Foundation -framework CryptoKit -framework Metal
chmod 755 "$OUT_DIR/portable-pipeline"
echo "    OK: $OUT_DIR/portable-pipeline"

NATIVE_DIR="$DXMT_SOURCE/src/winemetal/unix"
if [ -f "$NATIVE_DIR/pipeline_cache.c" ] && [ -f "$NATIVE_DIR/pipeline_recipe.c" ]; then
  echo "==> Compiling libpipeline_prepare.dylib, pipeline-prepare, and pipeline-warm"
  /usr/bin/clang -arch x86_64 -mmacosx-version-min=14.0 -x objective-c -fblocks -fno-objc-arc \
    -DDXMT_PIPELINE_CACHE_OFFLINE_TOOL -O2 -dynamiclib \
    "$NATIVE_DIR/pipeline_recipe.c" "$NATIVE_DIR/pipeline_cache.c" \
    -framework Foundation -framework Metal -framework QuartzCore \
    -install_name @rpath/libpipeline_prepare.dylib \
    -o "$OUT_DIR/libpipeline_prepare.dylib"

  /usr/bin/clang -arch x86_64 -mmacosx-version-min=14.0 -x objective-c -fblocks -fobjc-arc \
    -DDXMT_PIPELINE_CACHE_OFFLINE_TOOL -O2 -I"$NATIVE_DIR" \
    "$RECALL_DIR/scripts/pipeline_prepare.m" -x none "$OUT_DIR/libpipeline_prepare.dylib" \
    -Wl,-rpath,@executable_path -framework Foundation -framework Metal \
    -o "$OUT_DIR/pipeline-prepare"

  /usr/bin/clang -arch x86_64 -mmacosx-version-min=14.0 -x objective-c -fblocks -fno-objc-arc \
    -O2 -I"$NATIVE_DIR" \
    "$RECALL_DIR/scripts/pipeline_warm.m" -x none "$OUT_DIR/libpipeline_prepare.dylib" \
    -Wl,-rpath,@executable_path -framework Foundation -framework Metal \
    -o "$OUT_DIR/pipeline-warm"

  /usr/bin/strip -S -x "$OUT_DIR/libpipeline_prepare.dylib" "$OUT_DIR/pipeline-prepare" "$OUT_DIR/pipeline-warm" 2>/dev/null || true
  chmod 755 "$OUT_DIR/libpipeline_prepare.dylib" "$OUT_DIR/pipeline-prepare" "$OUT_DIR/pipeline-warm"
  echo "    OK: $OUT_DIR/libpipeline_prepare.dylib, pipeline-prepare, pipeline-warm"
else
  echo "    Note: $NATIVE_DIR not prepared yet; skipping pipeline-prepare & pipeline-warm."
  echo "    Run: python3 $RECALL_DIR/scripts/build_portable_dxmt.py --workspace $WORK_DIR --source-only"
  echo "    then re-run 'make build-helpers' to compile all 3 shader helpers."
fi
