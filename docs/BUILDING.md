# Building NotRecall from Source

`NotRecall.app` is a self-contained macOS SwiftUI app and Steam Play compatibility tool. During the build, `scripts/bundle_runtime.py` automatically resolves [Recall](https://github.com/shreyashsaitwal/recall) (reusing a sibling `../recall` checkout if present, or cloning the pinned commit into `build/recall-source`), bootstraps any missing Recall Phase 2 toolchains and builds (dependencies, Wine, DXMT), compiles the 4 offline shader pipeline helpers (`ow2-pipeline`, `pipeline-prepare`, `pipeline-warm`, `libpipeline_prepare.dylib`), and packs `runtime.tar.gz`.

## Prerequisites

* **Apple Silicon Mac** running macOS 15.0+ (`NotRecall.app` targets macOS 14.0+, while the bundled runtime and shader helpers target macOS 15.0+; macOS 26.5+ is recommended at runtime for Overwatch)
* **Xcode Command Line Tools** (Swift 5.9+, `clang`, macOS 26.5 SDK) and **Xcode Metal Toolchain** (for building DXMT shaders)
* **Homebrew build tools** (only needed when building Recall Phase 2 from scratch):
  ```sh
  brew install bison meson ninja openssl@3 pkg-config
  ```
* **Apple Game Porting Toolkit `libd3dshared.dylib`** (SHA-256 `5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995`): mount Apple's GPTK DMG before building, or pass `GPTK_DIR=/path/to/gptk` (or `LIBD3DSHARED_PATH=/path/to/libd3dshared.dylib`). If you already have NotRecall or Recall installed locally, `bundle_runtime.py` auto-detects and verifies it automatically.

### Why `libd3dshared.dylib` is required even under DXMT

Even though NotRecall renders through DXMT rather than D3DMetal, CrossOver/Recall's `dlls/ntdll/unix/loader.c` loads Apple's `libd3dshared.dylib` via `CX_APPLEGPTK_LIBD3DSHARED_PATH` to enable **Rosetta 2 non-native code region support**. Without `lib/external/libd3dshared.dylib` in the bundled runtime, `Overwatch_loader.dll` deadlocks during startup before creating a window. `bundle_runtime.py` verifies its SHA-256 and copies it unmodified (never stripping, restamping, or re-signing it).

## Build Commands

```sh
# Validate shell scripts, VDF manifests, and compat/run behavior
make check

# Bootstrap Recall (if needed) and build runtime.tar.gz + shader helpers
make build-runtime

# Build signed build/NotRecall.app (compiles NotRecallApp + notrecall-sysinfo and embeds runtime + helpers)
make build-app

# Run checks and package build/NotRecall.app, .zip, and .dmg (+ .sha256)
make package

# Optional overrides (local Recall checkout, GPTK path, parallelism)
make package RECALL_DIR=../recall GPTK_DIR="/Volumes/Evaluation environment for Windows games 3.0" JOBS=4

# Force re-running Recall Phase 2 + re-packing runtime.tar.gz
python3 scripts/bundle_runtime.py --out build --rebuild-recall --force

# Clean all build/ artifacts
make clean
```

### Runtime Bundling Notes

* `bundle_runtime.py` compiles Recall's native Wine overlays (`wineserver`, `ntdll.so`, `win32u.so`, `winemac.so`, `mmdevapi.dll`, `winecoreaudio.so`, `services.exe`, `sechost.dll`, `mfreadwrite.dll`, `mfh264enc.dll`, `winemacmf.{dll,so}`, and `share/wine/wine.inf`) against the Phase 2 Wine build tree, ensuring `HAVE_MTLDEVICE_REGISTRYID=1` (Metal GPU enumeration in `winemac.so`) and `HAVE_AVFOUNDATION_AVFOUNDATION_H=1` (microphone permissions in `winecoreaudio.so`) are active.
* `nvngx.dll` is excluded from `llvm-strip --strip-debug` and verified with `sign_pe.check` so its Authenticode signature stays intact for MetalFX/DLSS.
* Mach-O binaries (except `libd3dshared.dylib`) are restamped to `minos=15.0` before signing. `wine` and `Overwatch.app` allow `DYLD_*` env vars for Steam Overlay injection, while `wineserver` omits `allow-dyld-environment-variables` so `overlay-shim.dylib` is not injected across `fork()`.

## Signing for Distribution

By default, `make build-app` and `make package` use ad-hoc signing (`IDENTITY=-`). For distribution to other Macs, pass a Developer ID Application identity (which automatically enables `--options runtime --timestamp`):

```sh
make package IDENTITY="Developer ID Application: Your Name (TEAMID)" APP_VERSION=1.0.0
```
