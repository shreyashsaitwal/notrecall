#!/bin/sh
# Packages NotRecall as a self-contained macOS .app bundle (build/NotRecall.app)
# and optional release DMG (build/NotRecall.dmg) + versioned runtime archive.
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/build}"
APP_BUNDLE="$OUT_DIR/NotRecall.app"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
IDENTITY="${IDENTITY:--}"
RUNTIME_ARCHIVE="${RUNTIME_ARCHIVE:-$OUT_DIR/runtime.tar.gz}"
APP_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-only)        APP_ONLY=1; shift ;;
    --runtime-archive)
      [ "$#" -ge 2 ] || { echo "Error: $1 requires a path argument" >&2; exit 1; }
      RUNTIME_ARCHIVE="$2"; shift 2 ;;
    --version)
      [ "$#" -ge 2 ] || { echo "Error: $1 requires a version argument" >&2; exit 1; }
      APP_VERSION="$2"; shift 2 ;;
    --identity)
      [ "$#" -ge 2 ] || { echo "Error: $1 requires an identity argument" >&2; exit 1; }
      IDENTITY="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"

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
cp -f "$SWIFT_BIN_DIR/NotRecallApp" "$OUT_DIR/NotRecallApp"

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RES_DIR="$APP_BUNDLE/Contents/Resources"
mkdir -p "$MACOS_DIR" "$RES_DIR/compat" "$RES_DIR/plugins" "$RES_DIR/scripts" "$RES_DIR/helpers"

cp -f "$OUT_DIR/NotRecallApp" "$MACOS_DIR/NotRecallApp"
chmod 755 "$MACOS_DIR/NotRecallApp"

# Embed compatibility tool, NotProton plugin, and installer scripts.
cp -f "$PROJECT_DIR/compat/compatibilitytool.vdf" "$RES_DIR/compat/"
cp -f "$PROJECT_DIR/compat/toolmanifest.vdf"      "$RES_DIR/compat/"
cp -f "$PROJECT_DIR/compat/run"                   "$RES_DIR/compat/"
chmod 755 "$RES_DIR/compat/run"

cp -f "$PROJECT_DIR/plugins/50-notrecall.conf"    "$RES_DIR/plugins/"

for s in install.sh uninstall.sh pipeline_hook.sh patch_ntdll.sh; do
  cp -f "$PROJECT_DIR/scripts/$s" "$RES_DIR/scripts/$s"
  chmod 755 "$RES_DIR/scripts/$s"
done

# Embed built shader pipeline helpers if present.
if [ -d "$OUT_DIR/helpers" ]; then
  for h in portable-pipeline pipeline-prepare pipeline-warm libpipeline_prepare.dylib; do
    if [ -f "$OUT_DIR/helpers/$h" ]; then
      cp -f "$OUT_DIR/helpers/$h" "$RES_DIR/helpers/$h"
      chmod 755 "$RES_DIR/helpers/$h"
    fi
  done
fi

# Embed self-contained Recall runtime archive if built/provided.
if [ -f "$RUNTIME_ARCHIVE" ]; then
  echo "    Embedding runtime archive: $RUNTIME_ARCHIVE"
  cp -c "$RUNTIME_ARCHIVE" "$RES_DIR/runtime.tar.gz" 2>/dev/null || cp -f "$RUNTIME_ARCHIVE" "$RES_DIR/runtime.tar.gz"
  /usr/bin/shasum -a 256 "$RES_DIR/runtime.tar.gz" | cut -d' ' -f1 > "$RES_DIR/runtime.sha256"
else
  echo "    Note: $RUNTIME_ARCHIVE not present; NotRecall.app will still work with --runtime or auto-discovered Recall runtimes."
fi

# Bundle Recall license notices if submodule is present.
if [ -d "$PROJECT_DIR/recall/licenses" ]; then
  mkdir -p "$RES_DIR/licenses/recall"
  cp -R "$PROJECT_DIR/recall/licenses/." "$RES_DIR/licenses/recall/"
fi

# Generate AppIcon.icns from Recall's icon helper if available.
if [ -f "$PROJECT_DIR/recall/app/Resources/AppIcon.png" ] && [ -f "$PROJECT_DIR/recall/scripts/app_icon.swift" ]; then
  iconset="$OUT_DIR/AppIcon.iconset"
  rm -rf "$iconset"
  if /usr/bin/swift "$PROJECT_DIR/recall/scripts/app_icon.swift" "$PROJECT_DIR/recall/app/Resources/AppIcon.png" "$iconset" >/dev/null 2>&1; then
    /usr/bin/iconutil -c icns "$iconset" -o "$RES_DIR/AppIcon.icns" >/dev/null 2>&1 || true
  fi
  rm -rf "$iconset"
fi

icon_plist=""
[ -f "$RES_DIR/AppIcon.icns" ] && icon_plist="  <key>CFBundleIconFile</key><string>AppIcon</string>"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.notrecall.app</string>
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

# Sign nested Mach-O helpers inside-out before signing the app bundle (avoid deprecated --deep).
for h in libpipeline_prepare.dylib pipeline-prepare pipeline-warm portable-pipeline; do
  if [ -f "$RES_DIR/helpers/$h" ]; then
    sign_item "$RES_DIR/helpers/$h"
  fi
done
sign_item "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
echo "    OK: $APP_BUNDLE"

if [ "$APP_ONLY" -eq 1 ]; then
  exit 0
fi

# Package distributable .zip (works everywhere) and drag-to-Applications .dmg (when hdiutil is available).
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
# Prefer macOS 27's `diskutil image create from` (replaces deprecated `hdiutil create`),
# falling back to `hdiutil create` on older macOS releases.
if /usr/sbin/diskutil image create from "$DMG_STAGE" --volumeName "NotRecall" --format UDZO "$DMG_PATH" >/dev/null 2>&1 \
  || /usr/bin/hdiutil create -volname "NotRecall" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null 2>&1; then
  (cd "$OUT_DIR" && /usr/bin/shasum -a 256 "NotRecall-$APP_VERSION.dmg" > "NotRecall-$APP_VERSION.dmg.sha256")
  echo "    OK: $DMG_PATH"
else
  rm -f "$DMG_PATH"
  echo "    Note: disk image creation unavailable in this environment (run 'make package' from Terminal to also produce $DMG_PATH)."
fi
rm -rf "$DMG_STAGE"
