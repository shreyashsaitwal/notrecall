#!/bin/sh
# Validates shell syntax, Steam VDF manifests, and compat/run behavior.
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

echo "==> Checking POSIX shell syntax (sh -n)"
for f in \
  "$PROJECT_DIR/compat/run" \
  "$PROJECT_DIR/scripts/pipeline_hook.sh" \
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

echo "==> Checking NotProton plugin descriptor (notrecall.conf)"
[ -f "$PROJECT_DIR/plugins/notrecall.conf" ]
first_sec=$(grep -E '^\[NOTPROTON_' "$PROJECT_DIR/plugins/notrecall.conf" | head -1)
[ "$first_sec" = "[NOTPROTON_NOTRECALL]" ]
grep -Fq "label       = NotRecall" "$PROJECT_DIR/plugins/notrecall.conf"
grep -Fq "hide_crossover = 1" "$PROJECT_DIR/plugins/notrecall.conf"
grep -Fq "tools          = notrecall-proton*" "$PROJECT_DIR/plugins/notrecall.conf"
! grep -Fq "NOTPROTON_NOTRECALL_REBUILD_SHADERS" "$PROJECT_DIR/plugins/notrecall.conf"
! grep -Fq "NOTPROTON_NOTRECALL_RESET_DISPLAY" "$PROJECT_DIR/plugins/notrecall.conf"
echo "    OK: plugins/notrecall.conf has [NOTPROTON_NOTRECALL] metadata header and hide_crossover = 1"

echo "==> Running behavioral tests for compat/run (Overwatch defaults & env contract)"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

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
  if [ "${2:-}" = "import" ] && [ -n "${TEST_REG_OUT:-}" ]; then
    reg_base="${3#C:\\}"
    cp -f "$WINEPREFIX/drive_c/$reg_base" "$TEST_REG_OUT" 2>/dev/null || true
  fi
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
assert_env "$ow_env" "WINEARCH=win64"
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
grep -Fqx '{"schema":1,"limit":"all"}' "$ow_data/notrecall-cache/cache/pipelines/load.json"

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

# Case 4: Phase 2 registry QoL (LeftOptionIsAlt, WineBrowser, 1x/2x RetinaMode, Bluetooth A2DP mic routing).
reg1_out="$test_root/reg1.reg"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$ow_data" \
  NOTRECALL_GAME_MODE=0 \
  NOTRECALL_TEST_DISPLAY_SCALE=1 \
  NOTRECALL_TEST_BT_MIC_UID="BuiltInMicrophoneDevice" \
  TEST_REG_OUT="$reg1_out" \
  TEST_ENV_OUT="$ow_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

grep -Fq '"RetinaMode"="N"' "$reg1_out"
grep -Fq '"LeftOptionIsAlt"="Y"' "$reg1_out"
grep -Fq '"Browsers"="/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/open"' "$reg1_out"
grep -Fq '"DefaultConnectionSettings"=hex:46,00,00,00,01,00,00,00,01,00,00,00' "$reg1_out"
grep -Fq 'winecoreaudio.drv\devices\1,BuiltInMicrophoneDevice' "$reg1_out"
grep -Fq '"DefaultInput"="{0.0.1.00000000}.{' "$reg1_out"
grep -Fq '"DefaultVoiceInput"="{0.0.1.00000000}.{' "$reg1_out"

reg2_out="$test_root/reg2.reg"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$ow_data" \
  NOTRECALL_GAME_MODE=0 \
  NOTRECALL_TEST_DISPLAY_SCALE=2 \
  NOTRECALL_TEST_BT_MIC_UID="none" \
  NOTRECALL_PROXY_AUTO_DETECT=1 \
  NOTRECALL_SHADER_MEM_MB=first \
  DXMT_ENABLE_NVEXT=1 \
  NOTRECALL_METALFX_SHARPNESS=low \
  TEST_REG_OUT="$reg2_out" \
  TEST_ENV_OUT="$ow_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

grep -Fq '"RetinaMode"="Y"' "$reg2_out"
grep -Fq '"DefaultInput"=-' "$reg2_out"
grep -Fq '"DefaultVoiceInput"=-' "$reg2_out"
grep -Fq '"DefaultConnectionSettings"=-' "$reg2_out"
grep -Fqx '{"schema":1,"limit":"first"}' "$ow_data/notrecall-cache/cache/pipelines/load.json"
grep -Fq "d3d11.metalfxSharpness=0.4" "$ow_env"

# Regression guard: if another tool (e.g. NotProton) removes RetinaMode from user.reg,
# import_prefix_settings must re-import even when .notrecall-reg.sha still matches.
printf '[Software\\Wine\\Mac Driver] 1700000000\n' > "$ow_data/pfx/user.reg"
reg3_out="$test_root/reg3.reg"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$ow_data" \
  NOTRECALL_GAME_MODE=0 \
  NOTRECALL_TEST_DISPLAY_SCALE=2 \
  NOTRECALL_TEST_BT_MIC_UID="none" \
  NOTRECALL_PROXY_AUTO_DETECT=1 \
  TEST_REG_OUT="$reg3_out" \
  TEST_ENV_OUT="$ow_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"
[ -f "$reg3_out" ]
grep -Fq '"RetinaMode"="Y"' "$reg3_out"

# Case 5: MetalFX Settings_v0.ini [GPU.6] sync, backup, and DLSS cleanup on toggle off.
ow_settings_dir="$ow_data/pfx/drive_c/users/steamuser/Documents/Overwatch/Settings"
mkdir -p "$ow_settings_dir"
ow_ini="$ow_settings_dir/Settings_v0.ini"
cat > "$ow_ini" <<'INI'
[GPU.6]
GPUName = "Apple M3 Pro"
GPUVenderID = "4203"
LastUsedGPUVendorID = "4203"

[Render.13]
HighQualityUpsample = "3"
INI

HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$ow_data" \
  NOTRECALL_GAME_MODE=0 \
  DXMT_ENABLE_NVEXT=1 \
  TEST_ENV_OUT="$ow_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

[ -f "$ow_data/Settings_v0.before-gpu-sync.ini" ]
grep -Fq 'GPUName = "NVIDIA GeForce RTX 4090"' "$ow_ini"
grep -Fq 'GPUVenderID = "4318"' "$ow_ini"
grep -Fq 'GPUDeviceID = "9860"' "$ow_ini"
grep -Fq 'HighQualityUpsample = "3"' "$ow_ini"

# Regression guard: Steam install scripts (verb=run) lack user launch options and must not wipe MetalFX settings.
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$ow_data" \
  NOTRECALL_GAME_MODE=0 \
  NOTRECALL_TEST_GPU_NAME="Apple M3 Pro" \
  TEST_ENV_OUT="$ow_env" \
  sh "$PROJECT_DIR/compat/run" run "C:\\Games\\Overwatch\\vcredist.exe"

grep -Fq 'GPUName = "NVIDIA GeForce RTX 4090"' "$ow_ini"
grep -Fq 'HighQualityUpsample = "3"' "$ow_ini"

HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$ow_data" \
  NOTRECALL_GAME_MODE=0 \
  DXMT_ENABLE_NVEXT=0 \
  NOTRECALL_TEST_GPU_NAME="Apple M3 Pro" \
  TEST_ENV_OUT="$ow_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

grep -Fq 'GPUName = "Apple M3 Pro"' "$ow_ini"
grep -Fq 'GPUVenderID = "4203"' "$ow_ini"
! grep -Fq 'GPUDeviceID' "$ow_ini"
! grep -Fq 'HighQualityUpsample' "$ow_ini"

# Case 6: Overwatch Highlights symlink to ~/Movies/Overwatch with collision-safe clip migration.
hl_data="$test_root/compatdata/hl-ow"
mkdir -p "$hl_data/pfx/drive_c/users/steamuser/Documents/Overwatch/videos/overwatch" "$fake_home/Movies/Overwatch"
printf 'existing' > "$fake_home/Movies/Overwatch/potg.mp4"
printf 'migrated' > "$hl_data/pfx/drive_c/users/steamuser/Documents/Overwatch/videos/overwatch/potg.mp4"

HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$hl_data" \
  NOTRECALL_GAME_MODE=0 \
  TEST_ENV_OUT="$ow_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

hl_link="$hl_data/pfx/drive_c/users/steamuser/Documents/Overwatch/videos/overwatch"
[ -L "$hl_link" ]
[ "$(readlink "$hl_link")" = "$fake_home/Movies/Overwatch" ]
[ "$(cat "$fake_home/Movies/Overwatch/potg.mp4")" = "existing" ]
[ "$(cat "$fake_home/Movies/Overwatch/potg 2.mp4")" = "migrated" ]
echo "    OK: Phase 2 registry QoL, 1x/2x RetinaMode, BT mic routing, MetalFX Settings_v0.ini sync, and Highlights migration"

# Case 7: Recall native WINE_GAME_MODE (Overwatch.app) + Overwatch Settings_v0.ini baseline & canvas sync.
gm_data="$test_root/compatdata/gm-ow"
mkdir -p "$gm_data" "$fake_runtime/lib/wine/game-mode/Overwatch.app/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$fake_runtime/lib/wine/game-mode/Overwatch.app/Contents/MacOS/wine"
chmod 755 "$fake_runtime/lib/wine/game-mode/Overwatch.app/Contents/MacOS/wine"
gm_env="$test_root/gm.env"

HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$gm_data" \
  NOTRECALL_TEST_DISPLAY_DEFAULT="1920 1080 144" \
  TEST_ENV_OUT="$gm_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

assert_env "$gm_env" "WINE_GAME_MODE=Overwatch.exe"
gm_ini="$gm_data/pfx/drive_c/users/steamuser/Documents/Overwatch/Settings/Settings_v0.ini"
[ -f "$gm_ini" ]
grep -Fq 'FullScreenWidth = "1920"' "$gm_ini"
grep -Fq 'FullScreenHeight = "1080"' "$gm_ini"
grep -Fq 'FullScreenRefresh = "144"' "$gm_ini"
grep -Fq 'GFXPresetLevel = "1"' "$gm_ini"
grep -Fq 'FrameRateCap = "600"' "$gm_ini"
grep -Fq 'VerticalSyncEnabled = "0"' "$gm_ini"
grep -Fq 'DynamicRenderScale = "0"' "$gm_ini"
grep -Fq 'dxgi.fullscreenCanvasWidth = 1920' "$gm_data/notrecall-dxmt.conf"
grep -Fq 'dxgi.fullscreenCanvasHeight = 1080' "$gm_data/notrecall-dxmt.conf"

# Subsequent launch preserves player's in-game resolution/graphics edits and syncs dxmt.conf canvas.
sed -i '' 's/FullScreenWidth = "1920"/FullScreenWidth = "2560"/; s/FullScreenHeight = "1080"/FullScreenHeight = "1440"/; s/GFXPresetLevel = "1"/GFXPresetLevel = "3"/' "$gm_ini"
gm_off_env="$test_root/gm_off.env"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$gm_data" \
  NOTRECALL_GAME_MODE=0 \
  TEST_ENV_OUT="$gm_off_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

assert_env_absent "$gm_off_env" "WINE_GAME_MODE"
grep -Fq 'FullScreenWidth = "2560"' "$gm_ini"
grep -Fq 'FullScreenHeight = "1440"' "$gm_ini"
grep -Fq 'GFXPresetLevel = "3"' "$gm_ini"
grep -Fq 'dxgi.fullscreenCanvasWidth = 2560' "$gm_data/notrecall-dxmt.conf"
grep -Fq 'dxgi.fullscreenCanvasHeight = 1440' "$gm_data/notrecall-dxmt.conf"
echo "    OK: Recall native WINE_GAME_MODE, Overwatch Settings_v0.ini baseline seeding, and dxmt.conf canvas sync"

# Case 8: Mouse polling rate cap, per-display resolution/refresh memory + fit-to-screen clamping, and diagnostic logging presets.
pd_data="$test_root/compatdata/pd-ow"
mkdir -p "$pd_data"
pd_env1="$test_root/pd1.env"

# Display A (4K 16:9 144Hz monitor) with 1000 Hz mouse cap and all 3 diagnostic logging presets.
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$pd_data" \
  NOTRECALL_GAME_MODE=0 \
  NOTRECALL_MOUSE_RATE=1000 \
  NOTRECALL_LOG_CRASHES=1 \
  NOTRECALL_LOG_GRAPHICS=1 \
  NOTRECALL_LOG_MOUSE=1 \
  NOTRECALL_TEST_DISPLAY_INFO="monA-1-1 1920 1080 144 3840 2160" \
  TEST_ENV_OUT="$pd_env1" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

assert_env "$pd_env1" "WINEMAC_MOUSELOOK_RAW_INTERVAL_US=1000"
assert_env "$pd_env1" "WINEDEBUG=-all,err+all,+seh,+loaddll,+timestamp,+pid"
assert_env "$pd_env1" "DXMT_LOG_LEVEL=info"
assert_env "$pd_env1" "DXMT_LOG_PATH=$pd_data/dxmt-logs"
assert_env "$pd_env1" "WINEMAC_INPUT_STATS=$pd_data/input-logs/input"
[ -d "$pd_data/dxmt-logs" ]
[ -d "$pd_data/input-logs" ]

pd_ini="$pd_data/pfx/drive_c/users/steamuser/Documents/Overwatch/Settings/Settings_v0.ini"
grep -Fq 'FullScreenWidth = "1920"' "$pd_ini"
grep -Fq 'FullScreenHeight = "1080"' "$pd_ini"
grep -Fq 'FullScreenRefresh = "144"' "$pd_ini"

# Player chooses 3840x2160 on Display A, then switches to Display B (16:10 120Hz MacBook, max 3024x1964).
sed -i '' 's/FullScreenWidth = "1920"/FullScreenWidth = "3840"/; s/FullScreenHeight = "1080"/FullScreenHeight = "2160"/' "$pd_ini"
pd_env2="$test_root/pd2.env"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$pd_data" \
  NOTRECALL_GAME_MODE=0 \
  NOTRECALL_MOUSE_RATE=500 \
  NOTRECALL_TEST_DISPLAY_INFO="macB-2-2 1920 1200 120 3024 1964" \
  TEST_ENV_OUT="$pd_env2" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

assert_env "$pd_env2" "WINEMAC_MOUSELOOK_RAW_INTERVAL_US=2000"
# Display B gets its own 1920x1200 @ 120Hz default without losing Display A's 3840x2160.
grep -Fq 'FullScreenWidth = "1920"' "$pd_ini"
grep -Fq 'FullScreenHeight = "1200"' "$pd_ini"
grep -Fq 'FullScreenRefresh = "120"' "$pd_ini"
grep -Fq 'dxgi.fullscreenCanvasWidth = 1920' "$pd_data/notrecall-dxmt.conf"
grep -Fq 'dxgi.fullscreenCanvasHeight = 1200' "$pd_data/notrecall-dxmt.conf"

# Switch back to Display A, but with a smaller max display size (2560x1440) -> clamps 3840x2160 down to 2560x1440!
pd_env3="$test_root/pd3.env"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$pd_data" \
  NOTRECALL_GAME_MODE=0 \
  NOTRECALL_TEST_DISPLAY_INFO="monA-1-1 1920 1080 144 2560 1440" \
  TEST_ENV_OUT="$pd_env3" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

grep -Fq 'FullScreenWidth = "2560"' "$pd_ini"
grep -Fq 'FullScreenHeight = "1440"' "$pd_ini"
grep -Fq 'FullScreenRefresh = "144"' "$pd_ini"
grep -Fq 'dxgi.fullscreenCanvasWidth = 2560' "$pd_data/notrecall-dxmt.conf"
grep -Fq 'dxgi.fullscreenCanvasHeight = 1440' "$pd_data/notrecall-dxmt.conf"
echo "    OK: Mouse polling cap, per-display resolution/refresh memory + clamping, and diagnostic logging presets"

# Case 9: Global settings.env + per-game notrecall-settings.env loading & env override precedence.
cfg_data="$test_root/compatdata/cfg-ow"
mkdir -p "$cfg_data" "$fake_home/Library/Application Support/notrecall"
cat > "$fake_home/Library/Application Support/notrecall/settings.env" <<'CFG'
# Global NotRecall settings
MTL_HUD_ENABLED=1
NOTRECALL_MOUSE_MODE=classic
DXMT_ENABLE_NVEXT=1
NOTRECALL_METALFX_SHARPNESS=high
CFG
cat > "$cfg_data/notrecall-settings.env" <<'CFG'
NOTRECALL_MOUSE_MODE=precise
CFG
cfg_env="$test_root/cfg.env"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$cfg_data" \
  NOTRECALL_GAME_MODE=0 \
  DXMT_ENABLE_NVEXT=0 \
  TEST_ENV_OUT="$cfg_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

assert_env "$cfg_env" "MTL_HUD_ENABLED=1"
assert_env "$cfg_env" "MTL_HUD_DISABLE_MENU_BAR=1"
assert_env "$cfg_env" "WINEMAC_INPUT_VARIANT=precise"
assert_env_absent "$cfg_env" "WINEMAC_RAW_SOURCE"
assert_env "$cfg_env" "DXMT_ENABLE_NVEXT=0"

# Regression guard: CRLF, surrounding whitespace, disallowed keys, and invalid FPS/sharpness values.
printf '  MTL_HUD_ENABLED = 1 \r\nNOTRECALL_FPS_LIMIT=144;evil=1\r\nUNSAFE_KEY=boom\r\n' > "$fake_home/Library/Application Support/notrecall/settings.env"
cfg_hard_env="$test_root/cfg_hard.env"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$cfg_data" \
  NOTRECALL_GAME_MODE=0 \
  TEST_ENV_OUT="$cfg_hard_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

assert_env "$cfg_hard_env" "MTL_HUD_ENABLED=1"
assert_env_absent "$cfg_hard_env" "UNSAFE_KEY"
! grep -Fq "preferredMaxFrameRate=144;evil=1" "$cfg_hard_env"
rm -f "$fake_home/Library/Application Support/notrecall/settings.env"
echo "    OK: settings.env global/per-game loading, CRLF/allowlist hardening, and env override precedence"

# Case 10: Adopted NotProton plugin env vars (NOTPROTON_NOTRECALL_* & NOTPROTON_ENV_*) override settings.env,
# while explicit raw env vars still take highest precedence.
cat > "$fake_home/Library/Application Support/notrecall/settings.env" <<'CFG'
NOTRECALL_MOUSE_MODE=classic
NOTRECALL_FPS_LIMIT=60
CFG
np_env="$test_root/np_plugin.env"
HOME="$fake_home" \
  STEAM_COMPAT_APP_ID=2357570 \
  STEAM_COMPAT_DATA_PATH="$cfg_data" \
  NOTPROTON_NOTRECALL_METALFX=1 \
  NOTPROTON_NOTRECALL_MTL_HUD=1 \
  NOTPROTON_NOTRECALL_DISABLE_GAMEMODE=1 \
  NOTPROTON_NOTRECALL_DISABLE_BT_MIC_FIX=1 \
  NOTPROTON_ENV_NOTRECALL_METALFX_SHARPNESS=high \
  NOTPROTON_ENV_NOTRECALL_MOUSE_MODE=hid \
  NOTPROTON_ENV_NOTRECALL_FPS_LIMIT=144 \
  NOTRECALL_FPS_LIMIT=120 \
  TEST_ENV_OUT="$np_env" \
  sh "$PROJECT_DIR/compat/run" waitforexitandrun "C:\\Games\\Overwatch\\Overwatch.exe"

assert_env "$np_env" "DXMT_ENABLE_NVEXT=1"
assert_env "$np_env" "MTL_HUD_ENABLED=1"
assert_env "$np_env" "NOTRECALL_GAME_MODE=0"
assert_env "$np_env" "NOTRECALL_BT_MIC_FIX=0"
assert_env "$np_env" "WINEMAC_INPUT_VARIANT=precise"
assert_env "$np_env" "WINEMAC_RAW_SOURCE=hid"
grep -Fq "d3d11.metalfxSharpness=0.8" "$np_env"
grep -Fq "d3d11.preferredMaxFrameRate=120" "$np_env"
rm -f "$fake_home/Library/Application Support/notrecall/settings.env"
echo "    OK: NotProton adopted plugin env translation and precedence"

echo "==> All checks passed!"
