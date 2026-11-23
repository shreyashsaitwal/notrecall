# Building NotRecall from Source

`NotRecall.app` is a self-contained macOS SwiftUI app and Steam Play compatibility tool. During the build, `scripts/bundle_runtime.py` assembles `runtime.tar.gz` (Wine + DXMT + Recall's native Wine overlays + Apple's unmodified `libd3dshared.dylib`) and compiles the 4 offline shader pipeline helpers (`ow2-pipeline`, `pipeline-prepare`, `pipeline-warm`, `libpipeline_prepare.dylib`) directly from a local [Recall](https://github.com/AsherJN/recall) Phase 2 source build.

## Prerequisites

* **Apple Silicon Mac** running macOS 15.0+ (`NotRecall.app` targets macOS 14.0+, while the bundled runtime and shader helpers target macOS 15.0+; macOS 26.5+ is recommended at runtime for Overwatch)
* **Xcode Command Line Tools** (Swift 5.9+ and `clang`)
* A completed local **Recall Phase 2 workspace** (default: `../recall/runtime/phase-2`) containing:
  * `wine-build-proof.json`, `dxmt-build-proof.json`, `native-build-proof.json`
  * `install/usr/local/` (Wine), `dxmt-install/` (DXMT), `clean-deps/lib/` (native dependencies)
  * `apple-original/redist/lib/external/libd3dshared.dylib` (Apple's unmodified Game Porting Toolkit support library, SHA-256 `5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995`)

### Why `libd3dshared.dylib` is required even under DXMT

Even though NotRecall renders through DXMT rather than D3DMetal, CrossOver/Recall's `dlls/ntdll/unix/loader.c` loads Apple's `libd3dshared.dylib` via `CX_APPLEGPTK_LIBD3DSHARED_PATH` to enable **Rosetta 2 non-native code region support**. Without `lib/external/libd3dshared.dylib` in the bundled runtime, `Overwatch_loader.dll` deadlocks during startup before creating a window. `bundle_runtime.py` verifies its SHA-256 and copies it unmodified (never stripping, restamping, or re-signing it).

## Build Commands

```sh
# Validate shell scripts, VDF manifests, and compat/run behavior
make check

# Assemble build/runtime/runtime.tar.gz and build/helpers/* from ../recall/runtime/phase-2
make build-runtime
# (or pass --force to rebuild even if cached metadata matches)
python3 scripts/bundle_runtime.py --recall-dir ../recall --out build --force

# Build signed build/NotRecall.app (compiles NotRecallApp + notrecall-sysinfo and embeds build/runtime + build/helpers)
make build-app

# Run checks and package build/NotRecall.app, .zip, and .dmg (+ .sha256)
make package

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
make package IDENTITY="Developer ID Application: Your Name (TEAMID)" APP_VERSION=0.1.0
```
