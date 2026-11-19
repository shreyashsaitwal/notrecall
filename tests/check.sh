#!/bin/sh
# Validates shell syntax, VDF manifests, and NotProton plugin schema compliance.
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
NOTPROTON_DIR="${NOTPROTON_DIR:-$PROJECT_DIR/../NotProton}"

echo "==> Checking POSIX shell syntax (sh -n)"
for f in \
  "$PROJECT_DIR/compat/run" \
  "$PROJECT_DIR/scripts/pipeline_hook.sh" \
  "$PROJECT_DIR/scripts/install.sh" \
  "$PROJECT_DIR/scripts/uninstall.sh" \
  "$PROJECT_DIR/scripts/build_runtime.sh" \
  "$PROJECT_DIR/scripts/build_helpers.sh" \
  "$PROJECT_DIR/scripts/patch_ntdll.sh" \
  "$PROJECT_DIR/scripts/package.sh" \
  "$PROJECT_DIR/tests/check.sh"; do
  sh -n "$f"
  echo "    OK: ${f#"$PROJECT_DIR/"}"
done

echo "==> Checking Steam VDF manifests"
grep -q '"notrecall-proton"' "$PROJECT_DIR/compat/compatibilitytool.vdf"
grep -q '"from_oslist" "windows"' "$PROJECT_DIR/compat/compatibilitytool.vdf"
grep -q '"to_oslist" "macos"' "$PROJECT_DIR/compat/compatibilitytool.vdf"
grep -q '"commandline" "/run %verb%"' "$PROJECT_DIR/compat/toolmanifest.vdf"
echo "    OK: compatibilitytool.vdf & toolmanifest.vdf"

echo "==> Validating plugins/50-notrecall.conf against NotProton's plugin parser"
if [ -f "$NOTPROTON_DIR/dylib/feats/compat_run.sh" ]; then
  # Extract np_conf_normalise directly from NotProton's compat_run.sh and run it on our plugin dir.
  tmp_validator=$(mktemp)
  trap 'rm -f "$tmp_validator"' EXIT
  awk '/^np_conf_normalise\(\)/,/^)/' "$NOTPROTON_DIR/dylib/feats/compat_run.sh" > "$tmp_validator"
  out=$(
    # shellcheck disable=SC1090
    . "$tmp_validator"
    np_conf_normalise "$PROJECT_DIR/plugins" "" plugin
  )
  refused=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "!" { print }')
  if [ -n "$refused" ]; then
    echo "FAIL: NotProton refused plugin entries:" >&2
    printf '%s\n' "$refused" >&2
    exit 1
  fi
  records=$(printf '%s\n' "$out" | awk -F'\t' '$1 != "!" && $1 !~ /^== / && !seen[$1]++ { n++ } END { print n + 0 }')
  echo "    OK: NotProton accepted all $records plugin record(s) with 0 refusals"
else
  echo "    SKIP: NotProton repo not found at $NOTPROTON_DIR"
fi

echo "==> Running behavioral tests for compat/run (Overwatch defaults & env contract)"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root" "${tmp_validator:-}"' EXIT

fake_home="$test_root/home"
fake_runtime="$fake_home/Library/Application Support/notrecall/runtime"
fake_bridge="$fake_home/Library/Application Support/notproton/bridge"
mkdir -p "$fake_runtime/bin" "$fake_runtime/lib/wine/x86_64-unix" "$fake_runtime/lib/wine/x86_64-windows" "$fake_bridge"

cat > "$fake_runtime/bin/wine" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "wineboot" ]; then
  mkdir -p "$WINEPREFIX"
  : > "$WINEPREFIX/system.reg"
  exit 0
fi
if [ "${1:-}" = "reg" ]; then
  exit 0
fi
env | sort > "$TEST_ENV_OUT"
exit 0
STUB
cat > "$fake_runtime/bin/wineserver" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod 755 "$fake_runtime/bin/wine" "$fake_runtime/bin/wineserver"

assert_env() {
  if ! grep -Fqx "$2" "$1"; then
    echo "FAIL: expected '$2' in $1" >&2
    exit 1
  fi
}

assert_env_absent() {
  if grep -Fq "^$2=" "$1" || grep -Eq "^$2=" "$1"; then
    echo "FAIL: expected '$2' to be unset in $1" >&2
    exit 1
  fi
}

# Case 1: Overwatch (AppID 2357570) with wrapper exe, user dxmt.conf override, A-series chip, Metal HUD.
ow_data="$test_root/compatdata/2357570"
mkdir -p "$ow_data"
printf 'dxgi.maxFrameLatency = 2\n' > "$ow_data/dxmt.conf"
ow_env="$test_root/ow.env"

HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$ow_data" \
  NOTRECALL_GAME_MODE=0 \
  NOTRECALL_TEST_CHIP="Apple A18 Pro" \
  MTL_HUD_ENABLED=1 \
  TEST_ENV_OUT="$ow_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Launcher.exe"

assert_env "$ow_env" "WINEMAC_MOUSELOOK=Overwatch.exe"
assert_env "$ow_env" "DXMT_GPU_LOST_EXIT=Overwatch.exe"
assert_env "$ow_env" "WINEMAC_INPUT_VARIANT=precise"
assert_env "$ow_env" "WINEMAC_RAW_SOURCE=hid"
assert_env "$ow_env" "WINEMAC_MOUSELOOK_RAW_INTERVAL_US=0"
assert_env "$ow_env" "WINEMSYNC=1"
assert_env "$ow_env" "WINEESYNC=0"
assert_env "$ow_env" "WINE_SIMULATE_WRITECOPY=1"
assert_env "$ow_env" "CX_HACK_FILESYSTEM_TYPE=1"
assert_env "$ow_env" "DXMT_CANVAS_OVERLAY=0"
assert_env "$ow_env" "DXMT_LOG_LEVEL=error"
assert_env "$ow_env" "DXMT_LOG_PATH=none"
assert_env "$ow_env" "DXMT_SHADER_CACHE_PATH=$ow_data/notrecall-cache/cache/shaders"
assert_env "$ow_env" "DXMT_GPU_REPORT=$ow_data/gpu-reports"
assert_env "$ow_env" "MTL_HUD_DISABLE_MENU_BAR=1"
grep -Fq "MTL_HUD_ELEMENTS=" "$ow_env" && grep -Fq "shaders" "$ow_env"
[ -d "$ow_data/notrecall-cache/cache/shaders" ]
[ -d "$ow_data/gpu-reports" ]
[ -f "$ow_data/notrecall-dxmt.conf" ]
grep -Fq "d3d11.shaderCompilerThreads = 8" "$ow_data/notrecall-dxmt.conf"
grep -Fq "dxgi.maxFrameLatency = 1" "$ow_data/notrecall-dxmt.conf"
grep -Fq "dxgi.nativeFullscreen = True" "$ow_data/notrecall-dxmt.conf"
grep -Fq "dxgi.sharpPresentation = True" "$ow_data/notrecall-dxmt.conf"
grep -Fq "dxgi.displaySyncEnabled = True" "$ow_data/notrecall-dxmt.conf"
grep -Fq "dxgi.maxFrameLatency = 2" "$ow_data/notrecall-dxmt.conf"
grep -Fq "DXMT_CONFIG_FILE=Z:" "$ow_env"

# Case 2: Classic mouse mode unsets WINEMAC_RAW_SOURCE and WINEMAC_MOUSELOOK_RAW_INTERVAL_US.
classic_env="$test_root/classic.env"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$ow_data" \
  NOTRECALL_GAME_MODE=0 \
  NOTRECALL_MOUSE_MODE=classic \
  TEST_ENV_OUT="$classic_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

assert_env "$classic_env" "WINEMAC_INPUT_VARIANT=classic"
assert_env_absent "$classic_env" "WINEMAC_RAW_SOURCE"
assert_env_absent "$classic_env" "WINEMAC_MOUSELOOK_RAW_INTERVAL_US"

# Case 3: Non-Overwatch game keeps exe basename and skips managed Overwatch dxmt.conf.
other_data="$test_root/compatdata/1091500"
mkdir -p "$other_data"
other_env="$test_root/other.env"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=1091500 \
  STEAM_COMPAT_DATA_PATH="$other_data" \
  NOTRECALL_GAME_MODE=0 \
  TEST_ENV_OUT="$other_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Cyberpunk\\Cyberpunk2077.exe"

assert_env "$other_env" "WINEMAC_MOUSELOOK=Cyberpunk2077.exe"
[ ! -f "$other_data/notrecall-dxmt.conf" ]
assert_env_absent "$other_env" "DXMT_CONFIG_FILE"
echo "    OK: Overwatch defaults, A-series displaySync, user override merge, classic mouse, and non-OW isolation"

echo "==> All checks passed!"
