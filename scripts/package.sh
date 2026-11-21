#!/bin/sh
# Packages NotRecall as a self-contained macOS .app bundle (build/NotRecall.app)
# with its bundled Wine + DXMT runtime and shader pipeline helpers, plus
# optional release ZIP + DMG (+ SHA-256).
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/build}"
APP_BUNDLE="$OUT_DIR/NotRecall.app"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
IDENTITY="${IDENTITY:--}"
APP_ONLY=0
STRICT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-only) APP_ONLY=1; shift ;;
    --strict)   STRICT=1; shift ;;
    --version)
      [ "$#" -ge 2 ] || { echo "Error: $1 requires a version argument" >&2; exit 1; }
      APP_VERSION="$2"; shift 2 ;;
    --identity)
      [ "$#" -ge 2 ] || { echo "Error: $1 requires an identity argument" >&2; exit 1; }
      IDENTITY="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SWIFT_ERR_LOG=""
ICONSET_DIR=""
DMG_STAGE=""
cleanup_package_tmp() {
  [ -z "$SWIFT_ERR_LOG" ] || rm -f "$SWIFT_ERR_LOG" 2>/dev/null || true
  [ -z "$ICONSET_DIR" ]   || rm -rf "$ICONSET_DIR" 2>/dev/null || true
  [ -z "$DMG_STAGE" ]     || rm -rf "$DMG_STAGE" 2>/dev/null || true
}
trap cleanup_package_tmp EXIT

mkdir -p "$OUT_DIR/helpers"

# Build notrecall-sysinfo if missing or older than its source.
SYSINFO_SRC="$PROJECT_DIR/scripts/notrecall_sysinfo.m"
SYSINFO_BIN="$OUT_DIR/helpers/notrecall-sysinfo"
if [ -f "$SYSINFO_SRC" ] && { [ ! -x "$SYSINFO_BIN" ] || [ "$SYSINFO_SRC" -nt "$SYSINFO_BIN" ]; }; then
  echo "==> Compiling notrecall-sysinfo -> $SYSINFO_BIN"
  /usr/bin/clang -arch arm64 -mmacosx-version-min=14.0 -fobjc-arc -O2 \
    "$SYSINFO_SRC" \
    -framework Foundation -framework CoreGraphics -framework CoreAudio \
    -framework IOKit -framework Metal \
    -o "$SYSINFO_BIN"
  /usr/bin/strip -S -x "$SYSINFO_BIN" 2>/dev/null || true
  chmod 755 "$SYSINFO_BIN"
fi

echo "==> Compiling NotRecallApp SwiftUI binary"
SWIFT_BUILD_DIR="$OUT_DIR/.swift-build"
SWIFT_ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/notrecall-swift-build.XXXXXX")
SWIFT_SANDBOX_FLAGS=""
if ! xcrun swift build --package-path "$PROJECT_DIR/app" -c release --arch arm64 --scratch-path "$SWIFT_BUILD_DIR" 2>"$SWIFT_ERR_LOG"; then
  if grep -qE 'sandbox_apply|Operation not permitted' "$SWIFT_ERR_LOG" 2>/dev/null; then
    SWIFT_SANDBOX_FLAGS="--disable-sandbox"
    xcrun swift build $SWIFT_SANDBOX_FLAGS --package-path "$PROJECT_DIR/app" -c release --arch arm64 --scratch-path "$SWIFT_BUILD_DIR"
  else
    cat "$SWIFT_ERR_LOG" >&2
    rm -f "$SWIFT_ERR_LOG"
    exit 1
  fi
fi
rm -f "$SWIFT_ERR_LOG"
# shellcheck disable=SC2086
SWIFT_BIN_DIR=$(xcrun swift build $SWIFT_SANDBOX_FLAGS --package-path "$PROJECT_DIR/app" -c release --arch arm64 --scratch-path "$SWIFT_BUILD_DIR" --show-bin-path)

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RES_DIR="$APP_BUNDLE/Contents/Resources"
mkdir -p "$MACOS_DIR" "$RES_DIR/compat" "$RES_DIR/plugins" "$RES_DIR/scripts" "$RES_DIR/helpers"

cp -f "$SWIFT_BIN_DIR/NotRecallApp" "$MACOS_DIR/NotRecallApp"
chmod 755 "$MACOS_DIR/NotRecallApp"

# Embed compatibility tool and helper scripts.
cp -f "$PROJECT_DIR/compat/compatibilitytool.vdf" "$RES_DIR/compat/"
cp -f "$PROJECT_DIR/compat/toolmanifest.vdf"      "$RES_DIR/compat/"
cp -f "$PROJECT_DIR/compat/run"                   "$RES_DIR/compat/"
chmod 755 "$RES_DIR/compat/run"

if [ -f "$PROJECT_DIR/plugins/notrecall.conf" ]; then
  cp -f "$PROJECT_DIR/plugins/notrecall.conf" "$RES_DIR/plugins/notrecall.conf"
fi

cp -f "$PROJECT_DIR/scripts/pipeline_hook.sh" "$RES_DIR/scripts/pipeline_hook.sh"
chmod 755 "$RES_DIR/scripts/pipeline_hook.sh"

# Embed native helpers (sysinfo + shader pipeline optimizer helpers).
for helper in notrecall-sysinfo ow2-pipeline libpipeline_prepare.dylib pipeline-prepare pipeline-warm; do
  if [ -f "$OUT_DIR/helpers/$helper" ]; then
    cp -f "$OUT_DIR/helpers/$helper" "$RES_DIR/helpers/$helper"
    chmod 755 "$RES_DIR/helpers/$helper"
  elif [ "$STRICT" -eq 1 ]; then
    echo "Error: required bundled helper missing at $OUT_DIR/helpers/$helper (run 'make build-runtime' first)" >&2
    exit 1
  fi
done

# Embed self-contained Wine + DXMT runtime archive and manifest.
RUNTIME_TAR="$OUT_DIR/runtime/runtime.tar.gz"
RUNTIME_META="$OUT_DIR/runtime/bundled-runtime.json"
if [ -f "$RUNTIME_TAR" ]; then
  cp -c "$RUNTIME_TAR" "$RES_DIR/runtime.tar.gz" 2>/dev/null || cp -f "$RUNTIME_TAR" "$RES_DIR/runtime.tar.gz"
  if [ -f "$RUNTIME_META" ]; then
    cp -f "$RUNTIME_META" "$RES_DIR/bundled-runtime.json"
  fi
elif [ "$STRICT" -eq 1 ]; then
  echo "Error: bundled runtime archive missing at $RUNTIME_TAR (run 'make build-runtime' first)" >&2
  exit 1
fi

if [ -f "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" ]; then
  cp -f "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$RES_DIR/THIRD_PARTY_NOTICES.md"
fi

# Generate AppIcon.icns if app/Resources/AppIcon.png is provided.
APP_ICON_PNG="$PROJECT_DIR/app/Resources/AppIcon.png"
if [ -f "$APP_ICON_PNG" ]; then
  ICONSET_DIR="$OUT_DIR/AppIcon.iconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  for sz in 16 32 128 256 512; do
    sz2=$((sz * 2))
    /usr/bin/sips -z "$sz" "$sz" "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}.png" >/dev/null
    /usr/bin/sips -z "$sz2" "$sz2" "$APP_ICON_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$RES_DIR/AppIcon.icns"
  rm -rf "$ICONSET_DIR"
  ICONSET_DIR=""
fi

icon_plist=""
[ -f "$RES_DIR/AppIcon.icns" ] && icon_plist="  <key>CFBundleIconFile</key><string>AppIcon</string>"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.shreyash.notrecall</string>
  <key>CFBundleName</key><string>NotRecall</string>
  <key>CFBundleDisplayName</key><string>NotRecall</string>
  <key>CFBundleExecutable</key><string>NotRecallApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
$icon_plist
</dict>
</plist>
PLIST

echo "==> Signing $APP_BUNDLE (identity: $IDENTITY)"
sign_item() {
  if [ "$IDENTITY" != "-" ]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
  else
    /usr/bin/codesign --force --sign - "$1"
  fi
}

# Sign nested Mach-O helpers inside-out before signing the app bundle.
for helper in libpipeline_prepare.dylib notrecall-sysinfo ow2-pipeline pipeline-prepare pipeline-warm; do
  if [ -f "$RES_DIR/helpers/$helper" ]; then
    sign_item "$RES_DIR/helpers/$helper"
  fi
done
sign_item "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
echo "    OK: $APP_BUNDLE"

if [ "$APP_ONLY" -eq 1 ]; then
  exit 0
fi

ZIP_PATH="$OUT_DIR/NotRecall-$APP_VERSION.zip"
rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
echo "==> Creating ZIP archive: $ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
(cd "$OUT_DIR" && /usr/bin/shasum -a 256 "NotRecall-$APP_VERSION.zip" > "NotRecall-$APP_VERSION.zip.sha256")
echo "    OK: $ZIP_PATH"

DMG_PATH="$OUT_DIR/NotRecall-$APP_VERSION.dmg"
DMG_STAGE="$OUT_DIR/.dmg-stage"
rm -rf "$DMG_STAGE" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$DMG_STAGE"
cp -cR "$APP_BUNDLE" "$DMG_STAGE/NotRecall.app" 2>/dev/null || cp -R "$APP_BUNDLE" "$DMG_STAGE/NotRecall.app"
ln -s /Applications "$DMG_STAGE/Applications"

echo "==> Creating DMG: $DMG_PATH"
if /usr/sbin/diskutil image create from "$DMG_STAGE" --volumeName "NotRecall" --format UDZO "$DMG_PATH" >/dev/null 2>&1 \
  || /usr/bin/hdiutil create -volname "NotRecall" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null 2>&1; then
  (cd "$OUT_DIR" && /usr/bin/shasum -a 256 "NotRecall-$APP_VERSION.dmg" > "NotRecall-$APP_VERSION.dmg.sha256")
  echo "    OK: $DMG_PATH"
else
  rm -f "$DMG_PATH"
  if [ "$STRICT" -eq 1 ]; then
    echo "Error: disk image creation failed in --strict mode." >&2
    rm -rf "$DMG_STAGE"
    exit 1
  fi
  echo "    Note: disk image creation unavailable in this environment (run 'make package' from Terminal to also produce $DMG_PATH)."
fi
rm -rf "$DMG_STAGE"
