# NotRecall

Run [Recall](https://github.com/AsherJN/recall)'s patched Wine + DXMT runtime as a native Steam Play compatibility tool (`NotRecall`) on Apple Silicon, built to work alongside stock [NotProton](https://github.com/NotProtonNot/NotProton).

`NotRecall.app` bundles the Wine + DXMT runtime, offline shader pipeline helpers, Steam compatibility tool, and NotProton Compatibility UI plugin into a single self-contained macOS app — so installation and updates happen offline with one click.

## What NotRecall Adds on Top of Recall

Recall is built as a standalone Battle.net app tuned specifically for Overwatch. NotRecall brings that runtime into Steam and extends it so it works cleanly across your Steam library:

- Full Recall runtime inside Steam without forking NotProton
- Multi-game DirectX 10/11 support
- Native Steam Compatibility UI & custom Launch Options
- Newer upstream DXMT
- Per-game offline shader pipeline & companion app

## Prerequisites

1. **Apple Silicon Mac** running macOS 15.0 or later (**macOS 26.5+** recommended for Overwatch) with **Rosetta 2** installed (`softwareupdate --install-rosetta --agree-to-license`).
2. **Steam for macOS** installed at `/Applications/Steam.app`.
3. **Stock [NotProton](https://github.com/NotProtonNot/NotProton)** installed and set up at least once so `~/Library/Application Support/notproton/bridge/` (including its CrossOver 26.3 patched `ntdll.dll`) is staged.

## Quick Start

1. Open `NotRecall.app` (from `NotRecall-<version>.dmg` or `build/NotRecall.app`).
2. On **Overview**, verify Rosetta 2, Steam, and the NotProton Bridge are ready — any missing prerequisite is flagged with a direct action.
3. Click **Install NotRecall** to stage the bundled Wine + DXMT runtime, shader helpers, Steam compatibility tool, and NotProton Compatibility UI plugin offline, then restart Steam.
4. For Overwatch, click **Set Up in Steam** on the Overwatch card. For any other DirectX 10/11 Windows game, right-click the game in Steam → **Properties → Compatibility** → enable **Force the use of a specific Steam Play compatibility tool** → select **NotRecall**.
5. Adjust per-game graphics, mouse, system, and diagnostic options directly in Steam's **Properties → Compatibility** tab. For **High-Precision** raw HID mouse input, use **Show Steam** and **Input Monitoring…** under **Recovery & Input** to grant `Steam.app` Input Monitoring permission in System Settings.

## `NotRecall.app`

* **Overview (`⌘1`):** Overwatch readiness with **Play Overwatch** (`⌘P`) / **Set Up in Steam** and **Highlights** (`⇧⌘H`) actions, live system health/runtime/shader status, contextual warnings (Low Power Mode, thermals, memory pressure, recent GPU hangs, bundled runtime updates), **Runtime & Installation** (`Choose…` / `Reset` local runtime override, **Install / Update**, **Update Runtime Only**, **Dry Run**, **Uninstall…**), **Recovery & Input** (**Show Steam**, **Input Monitoring…**, **Reset Display Settings**, **Restart Steam**, **Force Quit Overwatch**), and **Stack & Shaders**.
* **Shaders (`⌘2`):** Scans all Steam libraries (including external drives), resolves game titles from `appmanifest_<appid>.acf`, tracks live background optimization progress and post-macOS-update status, and offers per-game **Optimize Now**, **Rebuild Shaders**, and **Clear Cache**.
* **Logs (`⌘3`):** Shows **Dry Run** / installer output and the latest `notrecall-run.log` across Steam libraries, with one-click **Copy Diagnostics** (`⇧⌘C`).

## Building from Source

```sh
make check       # Validate shell syntax, VDF manifests, and compat/run behavior
make build-app   # Build signed build/NotRecall.app (with bundled runtime + helpers)
make package     # Run checks and build build/NotRecall.app, .zip, and .dmg (+ .sha256)
```

See [docs/BUILDING.md](docs/BUILDING.md) for Recall Phase 2 workspace prerequisites and Developer ID signing options.

## Notes & Limitations

* **DirectX 10/11 only:** Recall's graphics layer is DXMT (built with D3D12 disabled). For DirectX 12 games, select one of NotProton's CrossOver D3DMetal runners in Steam's Compatibility dropdown.
* **Games with a separate launcher `.exe`:** If Steam launches a launcher binary (e.g. `Launcher.exe`) that spawns the real game executable, set Steam Launch Options to `NOTRECALL_MOUSE_EXE=ActualGame.exe %command%` so raw mouse input and GPU-lost exit bind to the game process.
* **Third-party notices:** Component attributions and license details are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and bundled inside `NotRecall.app/Contents/Resources/`.
