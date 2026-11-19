#!/bin/sh
# Builds Recall's Wine + DXMT runtime from the in-tree ./recall submodule into
# build/runtime.tar.gz (plus SHA-256), using Recall's pinned Phase 2 pipeline.
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
RECALL_DIR="${RECALL_DIR:-$PROJECT_DIR/recall}"
WORK_DIR="${WORK_DIR:-$PROJECT_DIR/build/phase-2}"
TOOLCHAINS="${TOOLCHAINS:-$RECALL_DIR/runtime/toolchains}"
SIGNING_DIR="${SIGNING_DIR:-$RECALL_DIR/runtime/signing/recall-nvngx}"
VERSION="${VERSION:-notrecall-$(git -C "$RECALL_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)}"
IDENTITY="${IDENTITY:--}"
JOBS="${JOBS:-4}"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/build}"

usage() {
  cat <<USAGE
Usage: $0 [options]

Builds Wine + patched DXMT from the in-tree ./recall submodule into build/runtime.tar.gz.

Options:
  --workspace <dir>    Build workspace (must end in /phase-2; default: build/phase-2)
  --toolchains <dir>   Recall toolchains dir (llvm-mingw, bison, python/meson, clang+llvm-15)
  --version <ver>      Runtime version tag (default: $VERSION)
  --identity <id>      codesign identity (default: ad-hoc '-')
  --jobs <1-4>         Parallel build jobs (default: $JOBS)
  -h, --help           Show this help

Prerequisites (Recall Phase 2 source build):
  1. Xcode Command Line Tools (uses active SDK via xcrun --show-sdk-path)
  2. Recall toolchains in --toolchains (llvm-mingw-20251216-ucrt-macos-universal,
     bison, python/bin/meson, clang+llvm-15.0.7-x86_64-apple-darwin21.0)
  3. Apple GPTK libd3dshared.dylib staged in <workspace>/apple-original/redist/lib/external/
  4. ~12 GiB free disk space
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)  WORK_DIR="${2:-}"; shift 2 ;;
    --toolchains) TOOLCHAINS="${2:-}"; shift 2 ;;
    --version)    VERSION="${2:-}"; shift 2 ;;
    --identity)   IDENTITY="${2:-}"; shift 2 ;;
    --jobs)       JOBS="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ ! -f "$RECALL_DIR/scripts/build_portable_runtime.py" ]; then
  echo "Error: Recall submodule not initialized at $RECALL_DIR (run: git submodule update --init)." >&2
  exit 1
fi

# Verify prerequisites upfront so we fail fast with actionable guidance.
missing=""
[ -d "$TOOLCHAINS/llvm-mingw-20251216-ucrt-macos-universal/bin" ] || missing="$missing llvm-mingw"
[ -x "$TOOLCHAINS/python/bin/meson" ] || missing="$missing meson"
[ -d "$TOOLCHAINS/clang+llvm-15.0.7-x86_64-apple-darwin21.0" ] || missing="$missing clang+llvm-15"
[ -f "$WORK_DIR/apple-original/redist/lib/external/libd3dshared.dylib" ] || missing="$missing apple-gptk(libd3dshared.dylib)"

if [ -n "$missing" ]; then
  echo "Error: Missing Recall Phase 2 build prerequisites:$missing" >&2
  echo "  Toolchains dir: $TOOLCHAINS" >&2
  echo "  Workspace dir:  $WORK_DIR" >&2
  echo "See recall/docs/DEVELOPMENT.md for toolchain setup, or place a prebuilt" >&2
  echo "runtime.tar.gz at $OUT_DIR/runtime.tar.gz before running 'make package'." >&2
  exit 1
fi

mkdir -p "$WORK_DIR" "$OUT_DIR"

# Resolve the active macOS SDK (e.g. MacOSX27.2.sdk on macOS 27) so builds use
# the host's current Xcode/CLT SDK instead of Recall's hardcoded MacOSX26.5.sdk.
ACTIVE_SDK="${SDKROOT:-$(/usr/bin/xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)}"

# Strip macOS browser quarantine from downloaded toolchains so Gatekeeper never
# hangs clang/llvm-mingw during configure (avoid symlinks like python/ and bison).
/usr/bin/xattr -d com.apple.quarantine \
  "$TOOLCHAINS"/llvm-mingw-*/bin/* "$TOOLCHAINS"/llvm-mingw-*/lib/* \
  "$TOOLCHAINS"/clang+llvm-*/bin/* "$TOOLCHAINS"/clang+llvm-*/lib/* 2>/dev/null || true

# On macOS 27 / Xcode 27 CLT, /Library/Developer/CommandLineTools/usr/lib/libxcrun.dylib
# is arm64-only, so invoking /usr/bin/clang (the xcrun shim) under `arch -x86_64` fails.
# Invoking CLT binaries directly from /Library/Developer/CommandLineTools/usr/bin
# bypasses xcrun and substitutes the active SDK while keeping ./recall unmodified.
run_recall_py() {
  py_script="$1"
  shift
  NOTRECALL_ACTIVE_SDK="$ACTIVE_SDK" NOTRECALL_APPLE_SHA="$APPLE_SHA" python3 - "$py_script" "$@" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text()
clt = "/Library/Developer/CommandLineTools/usr/bin"
sdk = os.environ["NOTRECALL_ACTIVE_SDK"]
apple_sha = os.environ.get("NOTRECALL_APPLE_SHA", "")
src = src.replace("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk", sdk)
if apple_sha:
    src = src.replace("5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995", apple_sha)
src = src.replace("/usr/bin/clang", clt + "/clang")
src = src.replace(":/usr/bin:/bin", ":" + clt + ":/usr/bin:/bin")
src = src.replace("'/usr/bin', '/bin'", "'" + clt + "', '/usr/bin', '/bin'")
sys.path.insert(0, str(p.parent))
sys.argv = [str(p)] + sys.argv[2:]
exec(compile(src, str(p), "exec"), {"__name__": "__main__", "__file__": str(p)})
PY
}

APPLE_SHA=$(/usr/bin/shasum -a 256 "$WORK_DIR/apple-original/redist/lib/external/libd3dshared.dylib" | cut -d' ' -f1)

echo "==> [1/5] Fetching pinned Wine & native dependency sources"
run_recall_py "$RECALL_DIR/scripts/build_portable_runtime.py" --workspace "$WORK_DIR" --download-only

if [ -f "$WORK_DIR/native-build-proof.json" ]; then
  echo "==> [2/5] Native dependencies already built (skipping; remove native-build-proof.json to rebuild)"
else
  echo "==> [2/5] Building native dependencies (pkgconf, gmp, nettle, gnutls, inotify, SDL2, MoltenVK)"
  run_recall_py "$RECALL_DIR/scripts/build_portable_dependencies.py" --workspace "$WORK_DIR" --jobs "$JOBS"
fi

if [ -f "$WORK_DIR/wine-build-proof.json" ]; then
  echo "==> [3/5] Wine already built (skipping; remove wine-build-proof.json to rebuild)"
else
  # Layered Wine patches (e.g. wine-winemac-activation on top of wine-v1-canvas)
  # cannot be reverse-checked on retry; re-extract wine cleanly from cached tarball.
  if [ -d "$WORK_DIR/sources/wine" ]; then
    echo "    Cleaning partial wine source tree before re-applying patches..."
    rm -rf "$WORK_DIR/sources/wine"
  fi
  echo "==> [3/5] Building patched CrossOver 26.3.0 Wine from recall submodule"
  run_recall_py "$RECALL_DIR/scripts/build_portable_runtime.py" \
    --workspace "$WORK_DIR" --toolchains "$TOOLCHAINS" --jobs "$JOBS"
fi

if [ -f "$WORK_DIR/dxmt-build-proof.json" ]; then
  echo "==> [4/5] DXMT already built (skipping; remove dxmt-build-proof.json to rebuild)"
else
  echo "==> [4/5] Building patched DXMT + signed nvngx.dll"
  if [ ! -f "$SIGNING_DIR/recall.key" ]; then
    echo "    Creating local PE signing certificate in $SIGNING_DIR"
    python3 "$RECALL_DIR/scripts/sign_pe.py" create-certificate "$SIGNING_DIR"
  fi
  # Layered DXMT patches cannot be reverse-checked on retry; reset cached checkout cleanly.
  if [ -d "$WORK_DIR/dxmt-source/.git" ]; then
    git -C "$WORK_DIR/dxmt-source" reset --hard HEAD >/dev/null
    git -C "$WORK_DIR/dxmt-source" clean -fd >/dev/null
  fi
  run_recall_py "$RECALL_DIR/scripts/build_portable_dxmt.py" \
    --workspace "$WORK_DIR" --toolchains "$TOOLCHAINS" --jobs "$JOBS"
fi

ARCHIVE="$WORK_DIR/artifacts/$VERSION.tar.gz"
if [ -f "$ARCHIVE" ]; then
  echo "==> [5/5] Runtime archive already assembled ($VERSION; remove $ARCHIVE to re-assemble)"
else
  if [ -d "$WORK_DIR/artifacts/$VERSION" ]; then
    echo "    Cleaning partial artifact directory before re-assembling..."
    rm -rf "$WORK_DIR/artifacts/$VERSION"
  fi
  echo "==> [5/5] Assembling & signing runtime archive ($VERSION)"
  run_recall_py "$RECALL_DIR/scripts/assemble_portable_runtime.py" \
    --workspace "$WORK_DIR" --version "$VERSION" --identity "$IDENTITY"
fi

cp -f "$ARCHIVE" "$OUT_DIR/runtime.tar.gz"
cp -f "$ARCHIVE" "$OUT_DIR/notrecall-runtime-$VERSION.tar.gz"
(cd "$OUT_DIR" && /usr/bin/shasum -a 256 "notrecall-runtime-$VERSION.tar.gz" > "notrecall-runtime-$VERSION.tar.gz.sha256")

echo ""
echo "==> Built self-contained runtime:"
echo "    $OUT_DIR/runtime.tar.gz"
echo "    $OUT_DIR/notrecall-runtime-$VERSION.tar.gz"
echo "    $OUT_DIR/notrecall-runtime-$VERSION.tar.gz.sha256"
