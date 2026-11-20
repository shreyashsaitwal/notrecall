# Building NotRecall from Source

NotRecall builds as a lightweight (~1–2 MB) macOS SwiftUI app and Steam compatibility tool. Rather than compiling Wine, DXMT, and Apple GPTK from source, `NotRecall.app` downloads official signed [Recall](https://github.com/AsherJN/recall/releases) releases directly from GitHub, verifies their SHA-256 and code signature, and extracts `runtime.tar.gz` plus the 4 offline shader pipeline helpers (`ow2-pipeline` → `portable-pipeline`, `pipeline-prepare`, `pipeline-warm`, `libpipeline_prepare.dylib`).

## Prerequisites

- **macOS 14.0+** on Apple Silicon (macOS 26.5+ recommended at runtime for Overwatch)
- **Xcode Command Line Tools** (Swift 5.9+ and `clang`)

No git submodules, MinGW cross-compilers, or Apple GPTK staging are required.

## Build Commands

```sh
# Validate shell scripts, VDF manifests, compat/run behavior, and installer dry-run
make check

# Build build/NotRecall.app (compiles NotRecallApp + notrecall-sysinfo)
make build-app

# Run checks and package build/NotRecall.app, .zip, and .dmg (+ .sha256)
make package

# Clean all build/ artifacts
make clean
```

## Installing from CLI

You can also run the installer directly against a downloaded Recall `.dmg`, an installed `Recall.app`, a `runtime.tar.gz`, or an unpacked runtime directory:

```sh
make install RUNTIME=~/Downloads/Recall-1.6.6.dmg
# or:
make install RUNTIME=/Applications/Recall.app
```

## Signing for Distribution

By default, `make build-app` and `make package` use ad-hoc signing (`IDENTITY=-`). For distribution to other Macs, pass a Developer ID Application identity (which automatically enables `--options runtime --timestamp`):

```sh
make package IDENTITY="Developer ID Application: Your Name (TEAMID)" APP_VERSION=0.1.0
```
