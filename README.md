# NotRecall

Use [Recall](https://github.com/AsherJN/recall)'s patched Wine + DXMT runtime as a self-contained Steam Play compatibility tool (`notrecall-proton`) on Apple Silicon, riding on top of stock [NotProton](https://github.com/NotProtonNot/NotProton).

## Why This Architecture

- **Zero NotProton forks or Steam signature chasing:** Stock NotProton stays installed to unlock Steam Play, track Steam client updates, render the Compatibility UI, and provide the Steamworks bridge (`lsteamclient`, `steam.exe`, `overlay-shim.dylib`).
- **100% of Recall's runtime, including `ntdll.so`:** Running as a standalone tool in `~/Library/Application Support/Steam/compatibilitytools.d/notrecall-proton` avoids NotProton's variant `ntdll.so` block — preserving Recall's `virtual_mutex` `dlopen` freeze fix and `msync` thread-exit fd-close fix alongside all DXMT, MetalFX, raw HID mouse, audio hotplug, and Media Foundation patches.
- **Lightweight macOS `.app` bundle with verified Recall downloads:** `NotRecall.app` bundles `compat/`, `notrecall-sysinfo`, and installer scripts, and downloads official signed [Recall](https://github.com/AsherJN/recall/releases) `.dmg` releases from GitHub (verifying SHA-256 and code signature) — or lets you point to a local `Recall.app` / `.dmg` / `runtime.tar.gz`.
- **Per-game offline shader precompilation:** Consolidates reboot-shifted `MTLDevice.registryID` folders and warms Metal's cache before launch, then compiles learned shaders into `.metallib` archives in the background after each session, isolated per Steam AppID.
- **Native Steam Compatibility UI & custom Launch Options without OS Error 260:** `notrecall-proton` is adopted by stock NotProton via `build`/`flavor` metadata and `plugins/notrecall.conf` (`hide_crossover = 1`), so NotProton's shell launch hook wraps launches cleanly—letting you toggle MetalFX/DLSS, sharpening, Metal Performance HUD, raw HID mouse mode, mouse polling cap, frame pacing, FPS limit, shader memory, Game Mode, MSync, and logging directly in Steam → **Properties → Compatibility** (or pass standard `KEY=VAL %command%` Launch Options), with `NotRecall.app` (`settings.env`) serving as optional global defaults.

## Prerequisites

1. Apple Silicon Mac running **macOS 26.5 or later** (recommended for Overwatch) with **Rosetta 2** installed (`softwareupdate --install-rosetta --agree-to-license`).
2. **Steam for macOS** in `/Applications/Steam.app`.
3. **Stock NotProton** installed and run at least once so `~/Library/Application Support/notproton/bridge/` (and its CrossOver 26.3 patched `ntdll.dll`) is staged.

## Quick Start

### Using `NotRecall.app`

1. Open `build/NotRecall.app` (or drag it to `/Applications` from `NotRecall-<version>.dmg`).
2. In **Overview**, check your live prerequisites, system health, and Overwatch status — any missing prerequisites (Rosetta 2, Steam, NotProton bridge) are flagged with direct actions.
3. Click **Download & Install** (or **Install NotRecall** if a local Recall copy is detected) to stage the runtime, shader helpers, Steam compatibility tool, and NotProton Compatibility UI plugin. Use the **Recall Runtime & Installation** card on **Overview** for custom sources, **Update Runtime Only**, **Dry Run**, or **Uninstall…**.
4. Click **Set Up in Steam** on the Overwatch hero card to configure Overwatch automatically, or right-click any DirectX 10/11 Windows game in Steam → **Properties → Compatibility** → enable **Force the use of a specific Steam Play compatibility tool** → select **NotRecall (Recall Wine + DXMT)**.
5. Configure per-game graphics, mouse, system, and diagnostic options directly in Steam’s **Properties → Compatibility** tab. For High-Precision raw HID mouse input, use **Show Steam** and **Input Monitoring…** in **Recovery & Input** to add `Steam.app` in **System Settings → Privacy & Security → Input Monitoring**.

### Using the CLI (`Makefile` / `scripts/install.sh`)

```sh
# Validate shell scripts, VDF manifests, and behavioral tests
make check

# Preview installation without modifying ~/Library/Application Support
make dry-run RUNTIME=~/Downloads/Recall-1.6.6.dmg

# Install using a Recall .dmg, Recall.app, runtime.tar.gz, or unpacked runtime directory
make install RUNTIME=~/Downloads/Recall-1.6.6.dmg

# Update only runtime/ + Steamworks bridge without touching prefixes, shader caches, or settings
sh scripts/install.sh --runtime-only --runtime ~/Downloads/Recall-1.6.6.dmg

# Uninstall tool, staged runtime, settings, and DMG cache (preserves Steam prefixes and game saves)
make uninstall
```

## `NotRecall.app` Features

- **Overview (`⌘1`):** Dashboard showing Overwatch readiness with direct **Play Overwatch** / **Set Up in Steam** and **Highlights** actions, live metric tiles (**System Health**, **Recall Runtime**, **Shader Cache**), contextual warnings (Low Power Mode, thermals, memory pressure, recent GPU hangs, Recall updates), **Recall Runtime & Installation** (`Choose…` / `Reset` local runtime source, **Install / Update**, **Update Runtime Only**, **Dry Run**, **Uninstall…**), **Recovery & Input** (High-Precision Mouse permission helpers, **Reset Display Settings**, **Restart Steam**, **Force Quit Overwatch**), and a live **Stack & Shaders** checklist with direct **Optimize Now** and **Rebuild** buttons.
- **Shaders (`⌘2`):** Scans all Steam libraries from `libraryfolders.vdf` (including external SSDs), resolves game titles from `appmanifest_<appid>.acf`, tracks live background precompilation progress and post-macOS-update optimization status, and provides per-game **Optimize Now**, **Rebuild Shaders**, and **Clear Cache**.
- **Logs (`⌘3`):** Displays **Dry Run** / installer script output as well as the latest `notrecall-run.log` across all Steam libraries with the resolved game title and one-click **Copy Diagnostics** (`⇧⌘C`).

## Building from Source

```sh
make check       # Validate shell syntax, VDF manifests, and behavioral tests
make build-app   # Build signed build/NotRecall.app (including notrecall-sysinfo)
make package     # Run checks and build build/NotRecall.app, .zip, and .dmg (+ .sha256)
```

See [docs/BUILDING.md](docs/BUILDING.md) for prerequisites and Developer ID signing options.

## Notes & Limitations

- **DirectX 10/11 only:** Recall's graphics layer is DXMT. For DirectX 12 games, select one of NotProton's CrossOver D3DMetal runners in Steam's Compatibility dropdown.
- **Games with a separate launcher `.exe`:** If Steam launches a launcher binary (e.g. `Launcher.exe`) that spawns the actual game `.exe`, set Steam Launch Options to `NOTRECALL_MOUSE_EXE=ActualGame.exe %command%` so Recall binds raw mouse input and GPU-lost exit to the game process.
- **Per-game Game Mode wrappers:** Overwatch uses Recall's signed `Overwatch.app` bundle for native `WINE_GAME_MODE`; other Steam AppIDs get a content-stamped `NotRecallGame.app` wrapper with deterministic Mach-O `LC_UUID` and Hardened Runtime entitlements allowing `DYLD_*` env vars for Steam Overlay.
- **Upstream notices:** Third-party attributions are bundled in `THIRD_PARTY_NOTICES.md` inside `NotRecall.app/Contents/Resources/`.
