# Building NotRecall from Source

NotRecall builds its self-contained Wine + DXMT runtime directly from the pinned `./recall` git submodule without modifying `./recall`.

## Prerequisites

1. **Xcode + Metal Toolchain**
   - Full Xcode (e.g., Xcode 27) with Command Line Tools installed and the Metal shader compiler downloaded:
     ```sh
     sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
     xcodebuild -downloadComponent MetalToolchain
     ```
   - `scripts/build_runtime.sh` resolves your active macOS SDK via `xcrun --show-sdk-path` (e.g. `MacOSX27.2.sdk`) and invokes CLT `clang` directly under `arch -x86_64` to avoid macOS 27's arm64-only `libxcrun.dylib`.

2. **Recall Phase 2 Toolchains** (staged under `recall/runtime/toolchains/` or passed via `--toolchains`)
   - `llvm-mingw-20251216-ucrt-macos-universal` (universal `clang` / MinGW-w64 cross-compiler for Windows PE DLLs)
   - `clang+llvm-15.0.7-x86_64-apple-darwin21.0` (required by DXMT's `airconv` for LLVM 15 typed-pointer `.air` bitcode)
   - `bison` (GNU Bison 3.x, e.g. symlinked from Homebrew `/opt/homebrew/opt/bison/bin/bison`)
   - `python/bin/meson` and `python/bin/ninja` (Python venv with `meson` and `ninja` installed)

3. **Apple Game Porting Toolkit (`libd3dshared.dylib`)**
   - Stage Apple's original GPTK redist files under `build/phase-2/apple-original/`:
     - `redist/lib/external/libd3dshared.dylib`
     - `License.rtf`, `Read Me.rtf`, `Acknowledgements.rtf`
   - `scripts/build_runtime.sh` accepts any genuine Apple-signed GPTK `libd3dshared.dylib` and enforces `codesign --verify --strict -R='anchor apple'` during Step 5.

4. **Disk Space**
   - ~12–15 GiB free during the build (`build/phase-2/` can be deleted after `make package` finishes).

## Build Steps

```sh
# 1. Initialize the pinned Recall submodule
git submodule update --init --recursive

# 2. Build Wine, native deps, patched DXMT, and assemble build/runtime.tar.gz
make build-runtime

# 3. Compile the 4 native shader pipeline helpers into build/helpers/
make build-helpers

# 4. Run checks and package build/NotRecall.app, .zip, and .dmg (+ .sha256)
make package
```

### Resuming Partial Builds

`scripts/build_runtime.sh` is idempotent across all 5 steps:
- Step 1 caches downloads under `build/phase-2/downloads/`.
- Steps 2–4 skip automatically once `native-build-proof.json`, `wine-build-proof.json`, and `dxmt-build-proof.json` exist.
- Step 5 skips if `build/phase-2/artifacts/<version>.tar.gz` already exists and cleans partial artifact directories on retry.

### Signing for Distribution

`scripts/package.sh` builds `NotRecallApp` via `swift build -c release` (from `app/Package.swift`), signs nested Mach-O helpers (`libpipeline_prepare.dylib`, `pipeline-prepare`, `pipeline-warm`, `portable-pipeline`) inside-out before signing `NotRecall.app` (avoiding deprecated `codesign --deep`), and enforces `codesign --verify --deep --strict`.

By default, `make build-runtime` and `make package` use ad-hoc signing (`IDENTITY=-`). For distribution to other Macs, pass a Developer ID Application identity (which automatically enables `--options runtime --timestamp`):

```sh
IDENTITY="Developer ID Application: Your Name (TEAMID)" make build-runtime
IDENTITY="Developer ID Application: Your Name (TEAMID)" APP_VERSION=0.1.0 make package
```

On macOS 27+, `scripts/package.sh` uses `diskutil image create from` to create the `.dmg`, falling back to `hdiutil create` on older macOS releases.
