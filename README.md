# NotRecall

Use [Recall](https://github.com/AsherJN/recall)'s patched Wine + DXMT runtime as a self-contained Steam Play compatibility tool (`notrecall-proton`) on Apple Silicon, riding on top of stock [NotProton](https://github.com/NotProtonNot/NotProton).

## Why This Architecture

- **Zero NotProton forks or Steam signature chasing:** Stock NotProton stays installed to unlock Steam Play, track Steam client updates, render the Compatibility UI, and provide the Steamworks bridge (`lsteamclient`, `steam.exe`, `overlay-shim.dylib`).
- **100% of Recall's runtime, including `ntdll.so`:** Running as a standalone tool in `~/Library/Application Support/Steam/compatibilitytools.d/notrecall-proton` avoids NotProton's variant `ntdll.so` block — preserving Recall's `virtual_mutex` `dlopen` freeze fix and `msync` thread-exit fd-close fix alongside all DXMT, MetalFX, raw HID mouse, audio hotplug, and Media Foundation patches.
- **Self-contained macOS `.app` bundle:** `NotRecall.app` packages the compiled Recall `runtime.tar.gz`, all 4 native shader pipeline helpers (`portable-pipeline`, `pipeline-prepare`, `pipeline-warm`, `libpipeline_prepare.dylib`), `compat/`, `plugins/50-notrecall.conf`, and installer scripts inside `Contents/Resources/` — no preinstalled `Recall.app` required.
- **Per-game offline shader precompilation:** Consolidates reboot-shifted `MTLDevice.registryID` folders and warms Metal's cache before launch, then compiles learned shaders into `.metallib` archives in the background after each session, isolated per Steam AppID.
- **Native Steam Compatibility UI:** Ships `plugins/50-notrecall.conf` so MetalFX/DLSS, RCAS sharpness, raw HID mouse mode, frame pacing, FPS limit, shader pack memory budget, MSync, Metal HUD, and Game Mode toggles appear directly inside Steam's **Properties → Compatibility** tab.

## Prerequisites

1. Apple Silicon Mac with **Rosetta 2** installed (`softwareupdate --install-rosetta --agree-to-license`).
2. **Steam for macOS** in `/Applications/Steam.app`.
3. **Stock NotProton** installed and run at least once so `~/Library/Application Support/notproton/bridge/` (and its CrossOver 26.3 patched `ntdll.dll`) is staged.

## Quick Start

### Using `NotRecall.app`

1. Open `build/NotRecall.app` (or drag it to `/Applications` from `NotRecall-<version>.dmg`).
2. Check the **Status** tab — any missing prerequisites (Rosetta 2, Steam, NotProton bridge) are flagged with direct remediation actions.
3. Click **Dry Run** to preview file operations in the **Logs** tab, or **Install / Update** to stage the runtime, helpers, Steam compatibility tool, and NotProton plugin.
4. For 8,000 Hz Raw HID mouse polling, click **Reveal Steam** and **Open Settings** to drag `Steam.app` into **System Settings → Privacy & Security → Input Monitoring**.
5. Click **Restart Steam**, then right-click any DirectX 10/11 Windows game → **Properties → Compatibility** → enable **Force the use of a specific Steam Play compatibility tool** → select **NotRecall (Recall Wine + DXMT)**.

### Using the CLI (`Makefile` / `scripts/install.sh`)

```sh
# Validate shell scripts, VDF manifests, and NotProton plugin schema
make check

# Preview installation without modifying ~/Library/Application Support
make dry-run

# Install using bundled build/runtime.tar.gz (or override with RUNTIME=/path/to/runtime)
make install

# Update only runtime/ + Steamworks bridge without touching prefixes, shader caches, or plugins
sh scripts/install.sh --runtime-only

# Force patching Recall's own ntdll.dll directly instead of copying NotProton's 26.3 binary
sh scripts/install.sh --patch-ntdll

# Uninstall tool, plugin, and staged runtime (preserves Steam prefixes and game saves)
make uninstall
```

## `NotRecall.app` Features

- **Status:** Checks Rosetta 2, Steam, NotProton bridge, runtime source (with a **Select…** picker for custom `.tar.gz` archives or unpacked runtime folders), staged runtime version, Steam tool, plugin, and helpers, plus a guided **Input Monitoring** setup row (**Reveal Steam** / **Open Settings**) for optional 8,000 Hz Raw HID mouse mode. Includes **Install / Update**, **Update Runtime Only**, **Dry Run**, **Restart Steam**, and **Copy Diagnostics**.
- **Shader Caches:** Scans all Steam libraries from `libraryfolders.vdf` (including external SSDs), resolves game titles from `appmanifest_<appid>.acf`, displays `.metallib` archive counts and disk usage, and offers per-game **Rebuild Shaders** (clears compiled `.metallib` archives and catalog metadata on next launch while preserving learned recipes) and **Clear Cache**.
- **Logs:** Displays **Dry Run** / installer script output as well as the latest `notrecall-run.log` across all Steam libraries with the resolved game title and a one-click **Copy Diagnostics** button for bug reports.

## Building from Source

```sh
git submodule update --init --recursive
make build-runtime   # Builds patched Wine + DXMT + signed nvngx.dll -> build/runtime.tar.gz
make build-helpers   # Compiles portable-pipeline, pipeline-prepare, pipeline-warm, libpipeline_prepare.dylib
make package         # Builds signed build/NotRecall.app, .zip, and .dmg (+ .sha256)
```

See [docs/BUILDING.md](docs/BUILDING.md) for the exact toolchain prerequisites (Xcode Metal Toolchain, `llvm-mingw`, `clang+llvm-15`, `bison`, `meson`/`ninja`, Apple GPTK `libd3dshared.dylib`) and macOS 27 build notes.

## Notes & Limitations

- **DirectX 10/11 only:** Recall's graphics layer is DXMT. For DirectX 12 games, select one of NotProton's CrossOver D3DMetal runners in Steam's Compatibility dropdown.
- **Games with a separate launcher `.exe`:** If Steam launches a launcher binary (e.g. `Launcher.exe`) that spawns the actual game `.exe`, set Steam Launch Options to `NOTRECALL_MOUSE_EXE=ActualGame.exe %command%` so Recall binds raw mouse input and GPU-lost exit to the game process.
- **Per-game Game Mode wrappers:** Each Steam AppID gets a content-stamped `NotRecallGame.app` wrapper with its own deterministic Mach-O `LC_UUID` (isolating macOS Local Network privacy per game) and Hardened Runtime entitlements allowing `DYLD_*` env vars for Steam Overlay.
- **Atomic runtime updates & `--patch-ntdll`:** `scripts/install.sh` stages and validates runtime updates before swapping them into place. The `--patch-ntdll` fallback requires a local source checkout with `NotProton/ntdll-patch`; standalone `NotRecall.app` uses NotProton's pre-staged `bridge/wine/26.3*`.
- **Upstream licenses:** Recall's license notices and third-party attributions are bundled under `NotRecall.app/Contents/Resources/licenses/recall/` and inside `runtime.tar.gz`.
