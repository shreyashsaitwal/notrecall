# Third-Party Notices

NotRecall builds, bundles, or integrates with components from the following projects:

## Recall
* Project: https://github.com/AsherJN/recall
* Copyright 2026 Joshua Asher Nelson
* License: Apache License, Version 2.0

NotRecall bundles a self-contained Wine + DXMT runtime and four offline shader pipeline helpers (`ow2-pipeline`, `pipeline-prepare`, `pipeline-warm`, `libpipeline_prepare.dylib`) built from Recall's source recipe and patches.

## DXMT
* Upstream: https://github.com/3Shain/dxmt (by Feifan He), via https://github.com/NerRobDog/dxmt and https://github.com/shreyashsaitwal/dxmt
* License: MIT / LGPL-2.1-or-later (per component; original license texts are bundled inside the staged runtime under `~/Library/Application Support/notrecall/runtime/licenses/`)

## Wine (CrossOver 26.3.0)
* Source: CodeWeavers published CrossOver 26.3.0 Wine sources
* License: LGPL-2.1-or-later (`Wine-LGPL-2.1` bundled inside the staged runtime's `licenses/` directory)

## DirectX & NVIDIA NVAPI Headers
* DirectX headers: https://github.com/misyltoad/mingw-directx-headers (`DirectX-Headers-COPYING` bundled in the staged runtime)
* NVIDIA NVAPI headers: https://github.com/NVIDIA/nvapi — MIT (`NVAPI-MIT` bundled in the staged runtime; used to build DXMT's NVAPI and MetalFX/DLSS stand-ins, which contain no NVIDIA proprietary code)

## Apple Game Porting Toolkit Support Library
* Component: `libd3dshared.dylib`
* License: Apple proprietary — bundled unmodified in `lib/external/libd3dshared.dylib` (with Apple's accompanying notices in `licenses/apple/` inside the staged runtime) for Rosetta 2 non-native code region support.

## NotProton
* Project: https://github.com/NotProtonNot/NotProton
* NotRecall does not bundle or fork NotProton. During installation, NotRecall copies the Steamworks bridge (`lsteamclient`, patched CrossOver 26.3 `ntdll.dll`) from the user's existing NotProton installation and installs `plugins/notrecall.conf` using NotProton's plugin specification.
