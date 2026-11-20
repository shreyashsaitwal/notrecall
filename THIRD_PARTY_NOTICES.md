# Third-Party Notices

NotRecall integrates with and stages components from the following projects:

## Recall
- Original project: https://github.com/AsherJN/recall
- Copyright 2026 Joshua Asher Nelson
- License: Apache License, Version 2.0

NotRecall downloads and extracts the prebuilt Wine + DXMT runtime and offline shader pipeline helpers directly from official Recall GitHub releases. Full runtime component licenses (Wine, DXMT, LLVM, and Apple GPTK notices) are copied from the downloaded Recall release into `~/Library/Application Support/notrecall/licenses/recall/` during installation.

## NotProton
- Steamworks bridge (`lsteamclient`, `steam.exe` shim, `overlay-shim.dylib`, patched CrossOver 26.3 `ntdll.dll`) and UI plugin specification are provided by a user's existing NotProton installation.
