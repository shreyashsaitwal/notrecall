# NotRecall Codebase & Architecture Review Checklist

Audit performed against live source files on disk (`compat/`, `scripts/`, `app/`, `tests/`, `Makefile`, `README.md`, `docs/`). All verified P0, P1, and P2 items have been resolved and verified.

## P0 — Bugs and Reliability Risks

- [x] **P0-1: Harden `settings.env` parsing, `DXMT_CONFIG` validation, atomic writes, and signal cleanup in `compat/run`** — Fixed in `aacdbef`
  - **Location**: `compat/run:94-114`, `compat/run:412-425`, `compat/run:833-850`, `compat/run:1085-1106`, `compat/run:1304-1318`
  - **Change**: Stripped `\r` and surrounding whitespace in `load_settings_file`; validated `NOTRECALL_FPS_LIMIT` (digits only) and `NOTRECALL_METALFX_SHARPNESS` (keyword/numeric) before appending to `DXMT_CONFIG`; switched `.notrecall-reg.sha` and `load.json` to atomic `*.tmp.$$` + `mv -f`; guarded `cleanup()` against re-entry on repeated signals.
  - **Verified**: `sh -n compat/run && sh tests/check.sh` (including new CRLF, whitespace, disallowed-key, and malformed-FPS regression tests).

- [x] **P0-2: Atomically stage and swap `NotRecallGame.app` wrapper rebuilds in `compat/run`** — Fixed in `aacdbef`
  - **Location**: `compat/run:1198-1292`
  - **Change**: Staged wrapper rebuilds into `$launcher_dir/NotRecallGame.app.tmp.$$`, signed the staged bundle, and atomically swapped it into `$game_app` with rollback and cleanup of old/temp directories.
  - **Verified**: `sh -n compat/run && sh tests/check.sh`.

- [x] **P0-3: Eliminate main-thread blocking I/O and process waits in `NotRecall.app` (`AppState.swift`)** — Fixed in `09c3a31`
  - **Location**: `app/Sources/NotRecallApp/Model/AppState.swift` (`refresh`, `resetOverwatchDisplaySettings`, `configureOverwatchInSteam`, `clearShaderCache`, `requestRebuildShaders`)
  - **Change**: Moved all read-only disk probes in `refresh()` into its single `Task.detached` `RefreshSnapshot`; offloaded `isSteamHelperRunning()` and `SteamVDF.setCompatTool` in `configureOverwatchInSteam()`; offloaded `resetOverwatchDisplaySettings()` (preferring the library containing `appmanifest_2357570.acf`), `clearShaderCache()`, and `requestRebuildShaders()` off `@MainActor` with `isBusy` guards.
  - **Verified**: `xcrun swift build --disable-sandbox --package-path app`.

- [x] **P0-4: Sanitize remote DMG filename and verify SHA-256 before moving into final cache path in `RecallDownloader`** — Fixed in `09c3a31`
  - **Location**: `app/Sources/NotRecallApp/Model/RecallDownloader.swift`
  - **Change**: Validated `release.dmgName` against path separators / `.` / `..`, staged downloads into a `.part-<UUID>` file, verified SHA-256 on the staged file, and atomically promoted via `replaceItemAt`/`moveItem` only after verification passes (cleaning up `.part` on failure).
  - **Verified**: `xcrun swift build --disable-sandbox --package-path app`.

## P1 — Architectural and Boundary Issues

- [x] **P1-1: Clear stale `recall-release.json`, guard `IFS` globbing, and clean `OLD_RUNTIME` in `scripts/install.sh`** — Fixed in `938764a`
  - **Location**: `scripts/install.sh`
  - **Change**: Atomically wrote `recall-release.json` from `Recall.app` sources and removed stale `recall-release.json` when installing from non-`.app` sources; wrapped `find_helper_bin` `IFS='|'` loop in `set -f` / `set +f`; cleaned up `$OLD_RUNTIME` in `cleanup_all` when `$NR_SUPPORT/runtime` exists.
  - **Verified**: `sh -n scripts/install.sh && sh tests/check.sh`.

- [x] **P1-2: Eliminate unquoted globbing in `seed_overwatch_preferences` in `compat/run`** — Fixed in `aacdbef`
  - **Location**: `compat/run:562-584`, `776-790`
  - **Change**: Replaced unquoted `set -- $...` word splitting with `IFS=' ' read -r` heredoc parsing and numeric fallback guards on `ow_canvas_w`/`ow_canvas_h`.
  - **Verified**: `sh -n compat/run && sh tests/check.sh`.

- [x] **P1-3: Cache `AppIcon.icns` statically in `NotRecallEmblem`** — Fixed in `09c3a31`
  - **Location**: `app/Sources/NotRecallApp/Views/NotRecallStyle.swift`
  - **Change**: Changed `bundledIcon` to `private static let bundledIcon: NSImage?` so SwiftUI no longer reads and decodes `AppIcon.icns` from disk on every view render.
  - **Verified**: `xcrun swift build --disable-sandbox --package-path app`.

- [x] **P1-4: Handle custom `NOTRECALL_FPS_LIMIT` values cleanly in `GameSettingsView` Picker** — Fixed in `09c3a31`
  - **Location**: `app/Sources/NotRecallApp/Views/GameSettingsView.swift`
  - **Change**: Added dynamic `fpsPickerChoices` including `state.fpsLimit` when positive and not in `GameSettings.fpsChoices` so manual `settings.env` FPS caps never cause a SwiftUI Picker tag mismatch.
  - **Verified**: `xcrun swift build --disable-sandbox --package-path app`.

- [x] **P1-5: Fix stale UI copy and docs referencing removed `50-notrecall.conf` plugin and wrong `⌘2`/`⌘3` shortcut** — Fixed in `09c3a31`, `3a22cc6`, `aacdbef`
  - **Location**: `AppState.swift`, `SetupView.swift`, `README.md`, `Makefile`, `docs/BUILDING.md`, `tests/check.sh`
  - **Change**: Updated GPU-hang warning to point to **Game Settings** instead of Steam's Compatibility settings; updated `SetupView` uninstall copy, `README.md` (`⌘3` for Setup & Runtime), `Makefile`, `docs/BUILDING.md`, and `tests/check.sh` header to remove stale plugin references.
  - **Verified**: `sh tests/check.sh` and `xcrun swift build --disable-sandbox --package-path app`.

## P2 — Pragmatic Simplifications & Hardening

- [x] **P2-1: Add `EXIT` temp-dir cleanup trap in `scripts/package.sh` and clean downloaded DMG cache in `scripts/uninstall.sh`** — Fixed in `938764a`
  - **Location**: `scripts/package.sh`, `scripts/uninstall.sh`
  - **Change**: Added `cleanup_package_tmp` `EXIT` trap for `SWIFT_ERR_LOG`, `AppIcon.iconset`, and `.dmg-stage`; updated `uninstall.sh` to remove `~/Library/Caches/notrecall` and only log legacy plugin removal if `50-notrecall.conf` exists.
  - **Verified**: `sh -n scripts/package.sh scripts/uninstall.sh && sh tests/check.sh`.

- [x] **P2-2: Pass `show_alert` arguments safely to `osascript` in `compat/run`** — Fixed in `aacdbef`
  - **Location**: `compat/run:32-35`
  - **Change**: Passed title and message via `osascript -e 'on run argv' ... -- "$1" "$2"` instead of heredoc string interpolation.
  - **Verified**: `sh -n compat/run && sh tests/check.sh`.

- [x] **P2-3: Remove dead test variables, add `settings.env` edge-case tests, and surface action errors/Recall version in `AppState.swift`** — Fixed in `aacdbef`, `09c3a31`
  - **Location**: `tests/check.sh`, `app/Sources/NotRecallApp/Model/AppState.swift`
  - **Change**: Removed unused `NOTPROTON_DIR` and `tmp_validator` from `tests/check.sh` and added CRLF/allowlist/FPS validation tests; surfaced errors in `installRosetta()` and `openOverwatchHighlights()`; added `Recall Release` line to `copyDiagnostics()`.
  - **Verified**: `sh tests/check.sh` and `xcrun swift build --disable-sandbox --package-path app`.
