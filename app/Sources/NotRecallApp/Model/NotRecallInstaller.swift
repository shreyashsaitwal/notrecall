import CryptoKit
import Foundation

struct NotRecallInstallOptions: Sendable {
    var runtimeSource: URL? = nil
    var runtimeOnly: Bool = false
    var dryRun: Bool = false
    var recallTeamID: String? = ProcessInfo.processInfo.environment["RECALL_TEAM_ID"]
}

struct NotRecallOperationResult: Sendable {
    let succeeded: Bool
    let log: String
    let summary: String
}

enum NotRecallInstaller {
    private struct InstallerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func install(options: NotRecallInstallOptions = NotRecallInstallOptions()) -> NotRecallOperationResult {
        var logLines: [String] = []
        func log(_ line: String) {
            logLines.append(line)
        }

        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser
        let npSupport: URL = {
            if let override = env["NOTPROTON_SUPPORT"], !override.isEmpty {
                return URL(filePath: override)
            }
            return home.appending(path: "Library/Application Support/notproton")
        }()
        let nrSupport = home.appending(path: "Library/Application Support/notrecall")
        let steamCompatDir = home.appending(path: "Library/Application Support/Steam/compatibilitytools.d")
        let toolDst = steamCompatDir.appending(path: "notrecall-proton")
        let pluginDst = npSupport.appending(path: "plugins/notrecall.conf")
        let resourcesRoot = locateResourcesRoot()

        let pid = ProcessInfo.processInfo.processIdentifier
        let stageRuntime = nrSupport.appending(path: ".runtime.staging.\(pid)")
        let oldRuntime = nrSupport.appending(path: ".runtime.old.\(pid)")
        var dmgMount: URL?

        defer {
            if let mount = dmgMount, fm.fileExists(atPath: mount.path) {
                _ = runProcess("/usr/bin/hdiutil", ["detach", "-force", mount.path])
                try? fm.removeItem(at: mount)
            }
            if fm.fileExists(atPath: stageRuntime.path) {
                try? fm.removeItem(at: stageRuntime)
            }
            let liveRuntime = nrSupport.appending(path: "runtime")
            if fm.fileExists(atPath: liveRuntime.path) && fm.fileExists(atPath: oldRuntime.path) {
                try? fm.removeItem(at: oldRuntime)
            }
        }

        do {
            // 1. Locate Recall runtime source.
            guard var runtimeSrc = options.runtimeSource ?? findRecallRuntime(home: home) else {
                throw InstallerError(
                    message: "Could not locate a Recall release (.dmg, Recall.app, runtime.tar.gz, or bin/wine). Download a release from GitHub or choose a local Recall file."
                )
            }

            var recallAppSrc: URL?
            var recallHelpersDir: URL?
            var recallAppVersion: String?
            var recallRuntimeVersion: String?
            var recallExpectedSHA: String?

            // 2. Detect source type (.dmg, .app, archive, or unpacked directory).
            let lowerName = runtimeSrc.lastPathComponent.lowercased()
            if lowerName.hasSuffix(".dmg") {
                guard fm.fileExists(atPath: runtimeSrc.path) else {
                    throw InstallerError(message: "DMG not found: \(runtimeSrc.path)")
                }
                if options.dryRun {
                    log("[dry-run] attach read-only DMG \"\(runtimeSrc.path)\", verify Recall.app signature & release.json SHA-256, and extract runtime + helpers")
                } else {
                    let mountDir = fm.temporaryDirectory.appending(path: "notrecall-dmg-\(UUID().uuidString)")
                    try fm.createDirectory(at: mountDir, withIntermediateDirectories: true)
                    dmgMount = mountDir
                    log("==> Mounting Recall DMG: \(runtimeSrc.path)")
                    let attach = runProcess("/usr/bin/hdiutil", [
                        "attach", "-nobrowse", "-readonly", "-noverify",
                        "-mountpoint", mountDir.path, runtimeSrc.path
                    ])
                    guard attach.status == 0 else {
                        throw InstallerError(message: "Failed to mount DMG: \(attach.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                    let directApp = mountDir.appending(path: "Recall.app")
                    if isDirectory(directApp) {
                        recallAppSrc = directApp
                    } else if let items = try? fm.contentsOfDirectory(at: mountDir, includingPropertiesForKeys: nil) {
                        recallAppSrc = items.first {
                            $0.pathExtension.lowercased() == "app" && isDirectory($0.appending(path: "Contents/Resources"))
                        }
                    }
                    guard recallAppSrc != nil else {
                        throw InstallerError(message: "No Recall.app bundle found inside \(runtimeSrc.path).")
                    }
                }
            } else if lowerName.hasSuffix(".app") {
                let appURL = runtimeSrc.standardizedFileURL
                guard isDirectory(appURL.appending(path: "Contents/Resources")) else {
                    throw InstallerError(message: "Invalid app bundle: \(appURL.path)")
                }
                recallAppSrc = appURL
            }

            if let appSrc = recallAppSrc {
                if !options.dryRun {
                    log("==> Verifying Recall.app code signature")
                    var args = ["--verify", "--deep", "--strict"]
                    if let teamID = options.recallTeamID, !teamID.isEmpty {
                        args.append("-R=anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"")
                    }
                    args.append(appSrc.path)
                    let verify = runProcess("/usr/bin/codesign", args)
                    guard verify.status == 0 else {
                        throw InstallerError(message: "Recall.app code signature verification failed: \(verify.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                }

                let releaseJSON = appSrc.appending(path: "Contents/Resources/release.json")
                if let data = try? Data(contentsOf: releaseJSON),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    recallAppVersion = json["appVersion"] as? String
                    recallRuntimeVersion = json["runtimeVersion"] as? String
                    recallExpectedSHA = json["runtimeSHA256"] as? String
                }

                let bundledTarball = appSrc.appending(path: "Contents/Resources/runtime.tar.gz")
                let bundledUnpacked = appSrc.appending(path: "Contents/Resources/runtime")
                if fm.fileExists(atPath: bundledTarball.path) {
                    runtimeSrc = bundledTarball
                } else if fm.isExecutableFile(atPath: bundledUnpacked.appending(path: "bin/wine").path) {
                    runtimeSrc = bundledUnpacked
                } else {
                    throw InstallerError(message: "\(appSrc.path) does not contain Contents/Resources/runtime.tar.gz or runtime/bin/wine.")
                }

                let helpersCandidate = appSrc.appending(path: "Contents/Helpers")
                if isDirectory(helpersCandidate) {
                    recallHelpersDir = helpersCandidate
                }
            }

            let resolvedLower = runtimeSrc.lastPathComponent.lowercased()
            let runtimeIsArchive: Bool = {
                if resolvedLower.hasSuffix(".tar.gz") || resolvedLower.hasSuffix(".tgz") {
                    return fm.fileExists(atPath: runtimeSrc.path)
                }
                if resolvedLower.hasSuffix(".dmg") {
                    return true // dry-run only
                }
                return false
            }()

            if !options.dryRun {
                if !runtimeIsArchive && !fm.isExecutableFile(atPath: runtimeSrc.appending(path: "bin/wine").path) {
                    throw InstallerError(message: "Runtime source \(runtimeSrc.path) does not contain bin/wine.")
                }
                if runtimeIsArchive, let expectedSHA = recallExpectedSHA, !expectedSHA.isEmpty {
                    log("==> Verifying runtime.tar.gz SHA-256 against Recall release.json")
                    let actualSHA = try sha256Hex(of: runtimeSrc)
                    if actualSHA.lowercased() != expectedSHA.lowercased() {
                        throw InstallerError(message: "runtime.tar.gz SHA-256 mismatch (expected \(expectedSHA), got \(actualSHA)).")
                    }
                }
            }

            // 3. Verify NotProton's Steamworks bridge is available.
            let bridgeSrc = npSupport.appending(path: "bridge")
            if !options.dryRun && !isDirectory(bridgeSrc) {
                throw InstallerError(message: "NotProton bridge not found at \(bridgeSrc.path). Open NotProton and click Install first so its Steamworks bridge is staged.")
            }

            log("==> Staging Recall runtime from: \(runtimeSrc.path)")
            if options.dryRun {
                log("[dry-run] mkdir -p \(nrSupport.path) \(nrSupport.appending(path: "helpers").path)")
                if !options.runtimeOnly {
                    log("[dry-run] mkdir -p \(toolDst.path)")
                }
                if runtimeIsArchive {
                    log("[dry-run] extract \"\(runtimeSrc.path)\" into staging dir, wire Steamworks bridge, and atomically replace \"\(nrSupport.appending(path: "runtime").path)\"")
                } else {
                    log("[dry-run] copy \"\(runtimeSrc.path)\" into staging dir, wire Steamworks bridge, and atomically replace \"\(nrSupport.appending(path: "runtime").path)\"")
                }
            } else {
                try fm.createDirectory(at: nrSupport, withIntermediateDirectories: true)
                try fm.createDirectory(at: nrSupport.appending(path: "helpers"), withIntermediateDirectories: true)
                if !options.runtimeOnly {
                    try fm.createDirectory(at: toolDst, withIntermediateDirectories: true)
                }

                if fm.fileExists(atPath: stageRuntime.path) {
                    try fm.removeItem(at: stageRuntime)
                }
                if runtimeIsArchive {
                    try fm.createDirectory(at: stageRuntime, withIntermediateDirectories: true)
                    let untar = runProcess("/usr/bin/tar", ["-xzf", runtimeSrc.path, "-C", stageRuntime.path])
                    guard untar.status == 0 else {
                        throw InstallerError(message: "Failed to extract runtime archive: \(untar.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                } else {
                    try fm.copyItem(at: runtimeSrc, to: stageRuntime)
                }

                guard fm.isExecutableFile(atPath: stageRuntime.appending(path: "bin/wine").path),
                      isDirectory(stageRuntime.appending(path: "lib/wine/x86_64-unix")) else {
                    throw InstallerError(message: "Staged runtime from \(runtimeSrc.path) did not contain bin/wine and lib/wine/x86_64-unix.")
                }
            }

            // 4. Wire NotProton Steamworks bridge (lsteamclient + patched ntdll.dll).
            log("==> Wiring NotProton Steamworks bridge into staged Recall runtime")
            if options.dryRun {
                log("[dry-run] copy lsteamclient.{dll,so} and patched CrossOver 26.3 ntdll.dll")
            } else {
                let stageWin64 = stageRuntime.appending(path: "lib/wine/x86_64-windows")
                let stageWin32 = stageRuntime.appending(path: "lib/wine/i386-windows")
                let stageUnix64 = stageRuntime.appending(path: "lib/wine/x86_64-unix")

                var copiedLscDLL = false
                let bridgeLsc64 = bridgeSrc.appending(path: "x86_64-windows/lsteamclient.dll")
                let bridgeLscFlat = bridgeSrc.appending(path: "lsteamclient.dll")
                if fm.fileExists(atPath: bridgeLsc64.path) {
                    try copyReplacing(from: bridgeLsc64, to: stageWin64.appending(path: "lsteamclient.dll"))
                    copiedLscDLL = true
                } else if fm.fileExists(atPath: bridgeLscFlat.path) {
                    try copyReplacing(from: bridgeLscFlat, to: stageWin64.appending(path: "lsteamclient.dll"))
                    copiedLscDLL = true
                }

                let bridgeLsc32 = bridgeSrc.appending(path: "i386-windows/lsteamclient.dll")
                if fm.fileExists(atPath: bridgeLsc32.path) && isDirectory(stageWin32) {
                    try copyReplacing(from: bridgeLsc32, to: stageWin32.appending(path: "lsteamclient.dll"))
                }

                var copiedLscSO = false
                let bridgeLscSO = bridgeSrc.appending(path: "x86_64-unix/lsteamclient.so")
                if fm.fileExists(atPath: bridgeLscSO.path) {
                    try copyReplacing(from: bridgeLscSO, to: stageUnix64.appending(path: "lsteamclient.so"))
                    copiedLscSO = true
                }

                guard copiedLscDLL && copiedLscSO else {
                    throw InstallerError(message: "NotProton bridge at \(bridgeSrc.path) is missing lsteamclient.dll or x86_64-unix/lsteamclient.so.")
                }

                let wineBridgeDir = bridgeSrc.appending(path: "wine")
                let patchedNtdllDir = (try? fm.contentsOfDirectory(at: wineBridgeDir, includingPropertiesForKeys: nil))?
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .first {
                        $0.lastPathComponent.hasPrefix("26.3") &&
                        fm.fileExists(atPath: $0.appending(path: "x86_64-windows/ntdll.dll").path)
                    }

                guard let ntdllDir = patchedNtdllDir else {
                    throw InstallerError(message: "No CrossOver 26.3 patched ntdll.dll found under \(wineBridgeDir.path)/26.3*. Open NotProton and set up CrossOver 26.3 first.")
                }
                log("    Using NotProton patched CrossOver 26.3 ntdll.dll from: \(ntdllDir.path)")
                try copyReplacing(
                    from: ntdllDir.appending(path: "x86_64-windows/ntdll.dll"),
                    to: stageWin64.appending(path: "ntdll.dll")
                )
                let ntdll32 = ntdllDir.appending(path: "i386-windows/ntdll.dll")
                if fm.fileExists(atPath: ntdll32.path) && isDirectory(stageWin32) {
                    try copyReplacing(from: ntdll32, to: stageWin32.appending(path: "ntdll.dll"))
                }

                // Atomically swap staged runtime into place.
                let liveRuntime = nrSupport.appending(path: "runtime")
                if fm.fileExists(atPath: oldRuntime.path) {
                    try fm.removeItem(at: oldRuntime)
                }
                if fm.fileExists(atPath: liveRuntime.path) {
                    try fm.moveItem(at: liveRuntime, to: oldRuntime)
                }
                do {
                    try fm.moveItem(at: stageRuntime, to: liveRuntime)
                    if fm.fileExists(atPath: oldRuntime.path) {
                        try? fm.removeItem(at: oldRuntime)
                    }
                } catch {
                    if fm.fileExists(atPath: oldRuntime.path) && !fm.fileExists(atPath: liveRuntime.path) {
                        try? fm.moveItem(at: oldRuntime, to: liveRuntime)
                    }
                    throw error
                }

                // Record Recall release metadata & licenses when extracted from Recall.app.
                let releaseDst = nrSupport.appending(path: "recall-release.json")
                if let appSrc = recallAppSrc {
                    let releaseSrc = appSrc.appending(path: "Contents/Resources/release.json")
                    if fm.fileExists(atPath: releaseSrc.path) {
                        let data = try Data(contentsOf: releaseSrc)
                        try data.write(to: releaseDst, options: .atomic)
                    } else if let appVer = recallAppVersion, !appVer.isEmpty {
                        let payload: [String: String] = [
                            "appVersion": appVer,
                            "runtimeVersion": recallRuntimeVersion ?? ""
                        ]
                        let data = try JSONSerialization.data(withJSONObject: payload)
                        try data.write(to: releaseDst, options: .atomic)
                    } else {
                        try? fm.removeItem(at: releaseDst)
                    }

                    let licensesSrc = appSrc.appending(path: "Contents/Resources/Licenses")
                    if isDirectory(licensesSrc) {
                        let licensesDst = nrSupport.appending(path: "licenses/recall")
                        if fm.fileExists(atPath: licensesDst.path) {
                            try fm.removeItem(at: licensesDst)
                        }
                        try fm.createDirectory(at: licensesDst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: licensesSrc, to: licensesDst)
                        for notice in ["PROJECT-LICENSE.txt", "NOTICE.txt"] {
                            let srcNotice = appSrc.appending(path: "Contents/Resources/\(notice)")
                            if fm.fileExists(atPath: srcNotice.path) {
                                try copyReplacing(from: srcNotice, to: licensesDst.appending(path: notice))
                            }
                        }
                    }
                } else {
                    try? fm.removeItem(at: releaseDst)
                }
            }

            // 5. Stage Recall shader helpers.
            func stageRecallHelpers() throws {
                log("==> Installing shader pipeline helpers")
                let bins = ["ow2-pipeline", "pipeline-prepare", "pipeline-warm", "libpipeline_prepare.dylib"]
                var stagedCount = 0
                var missing: [String] = []
                for bin in bins {
                    if let found = findHelperBinary(
                        named: bin,
                        recallHelpersDir: recallHelpersDir,
                        resourcesRoot: resourcesRoot,
                        home: home
                    ) {
                        log("    Staging \(bin) from: \(found.path)")
                        let dst = nrSupport.appending(path: "helpers/\(bin)")
                        if options.dryRun {
                            log("[dry-run] cp -f \(found.path) \(dst.path)")
                        } else {
                            try copyReplacing(from: found, to: dst, permissions: 0o755)
                        }
                        stagedCount += 1
                    } else if bin != "libpipeline_prepare.dylib" {
                        missing.append(bin)
                    }
                }
                if !options.dryRun {
                    let legacyPipeline = nrSupport.appending(path: "helpers/portable-pipeline")
                    if entryExists(at: legacyPipeline) {
                        try? fm.removeItem(at: legacyPipeline)
                    }
                }
                if stagedCount == 0 {
                    log("    Note: ow2-pipeline helper not found (in-game DXMT shader caching still works; use a Recall .dmg/.app to enable offline precompilation).")
                } else if !missing.isEmpty {
                    log("    Warning: missing companion helper(s): \(missing.joined(separator: " "))")
                    log("    Use a Recall .dmg or Recall.app for full offline precompilation & warming.")
                }
            }

            if options.runtimeOnly {
                if recallHelpersDir != nil {
                    try stageRecallHelpers()
                }
                let verSuffix = recallAppVersion.map { " (Recall \($0))" } ?? ""
                log("")
                log("Done! Updated NotRecall runtime\(verSuffix) only (Steam prefixes, shader caches, and plugin untouched).")
                return NotRecallOperationResult(
                    succeeded: true,
                    log: logLines.joined(separator: "\n"),
                    summary: options.dryRun
                        ? "Dry run completed (runtime only)."
                        : "Updated NotRecall runtime\(verSuffix)."
                )
            }

            try stageRecallHelpers()

            guard let resRoot = resourcesRoot else {
                throw InstallerError(message: "Could not locate bundled NotRecall resources (compat/ and scripts/pipeline_hook.sh).")
            }

            let pipelineHookSrc = resRoot.appending(path: "scripts/pipeline_hook.sh")
            let pipelineHookDst = nrSupport.appending(path: "helpers/pipeline_hook.sh")
            if options.dryRun {
                log("[dry-run] cp -f \(pipelineHookSrc.path) \(pipelineHookDst.path)")
            } else {
                guard fm.fileExists(atPath: pipelineHookSrc.path) else {
                    throw InstallerError(message: "Missing bundled pipeline_hook.sh at \(pipelineHookSrc.path).")
                }
                try copyReplacing(from: pipelineHookSrc, to: pipelineHookDst, permissions: 0o755)
            }

            if let sysinfoBin = findHelperBinary(
                named: "notrecall-sysinfo",
                recallHelpersDir: nil,
                resourcesRoot: resRoot,
                home: home
            ) {
                log("    Staging notrecall-sysinfo from: \(sysinfoBin.path)")
                let dst = nrSupport.appending(path: "helpers/notrecall-sysinfo")
                if options.dryRun {
                    log("[dry-run] cp -f \(sysinfoBin.path) \(dst.path)")
                } else {
                    try copyReplacing(from: sysinfoBin, to: dst, permissions: 0o755)
                }
            }

            // 6. Install Steam compatibility tool bundle, NotProton adoption metadata, and plugin.
            log("==> Installing Steam compatibility tool to: \(toolDst.path)")
            let compatFiles: [(String, Int?)] = [
                ("compatibilitytool.vdf", nil),
                ("toolmanifest.vdf", nil),
                ("run", 0o755)
            ]
            for (name, perms) in compatFiles {
                let src = resRoot.appending(path: "compat/\(name)")
                let dst = toolDst.appending(path: name)
                if options.dryRun {
                    log("[dry-run] cp -f \(src.path) \(dst.path)")
                } else {
                    guard fm.fileExists(atPath: src.path) else {
                        throw InstallerError(message: "Missing bundled compat file: \(src.path)")
                    }
                    try copyReplacing(from: src, to: dst, permissions: perms)
                }
            }

            if let adoptBuild = readNotProtonAdoptBuild(npSupport: npSupport) {
                log("==> Adopting notrecall-proton into NotProton (build \(adoptBuild), rosetta)")
                if options.dryRun {
                    log("[dry-run] write \(toolDst.appending(path: "build").path) (\(adoptBuild)) and \(toolDst.appending(path: "flavor").path) (rosetta)")
                } else {
                    try Data("\(adoptBuild)\n".utf8).write(to: toolDst.appending(path: "build"), options: .atomic)
                    try Data("rosetta\n".utf8).write(to: toolDst.appending(path: "flavor"), options: .atomic)
                }
            } else {
                log("    Note: \(npSupport.appending(path: "tools").path) not found yet; compat/run will sync adoption metadata once NotProton is installed.")
            }

            let pluginSrc = resRoot.appending(path: "plugins/notrecall.conf")
            if fm.fileExists(atPath: pluginSrc.path) {
                log("==> Installing NotProton Steam Compatibility plugin to: \(pluginDst.path)")
                if options.dryRun {
                    log("[dry-run] cp -f \(pluginSrc.path) \(pluginDst.path)")
                } else {
                    try fm.createDirectory(at: pluginDst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try copyReplacing(from: pluginSrc, to: pluginDst)
                }
            }

            let verSentence = recallAppVersion.map { " Installed Recall \($0) runtime." } ?? ""
            log("")
            log("Done!\(verSentence) Restart Steam, then select 'NotRecall (Recall Wine + DXMT)' under:")
            log("  Game -> Properties -> Compatibility -> Force the use of a specific Steam Play compatibility tool")
            log("Configure MetalFX, Metal HUD, mouse mode, and other options directly in Steam's Compatibility tab.")

            return NotRecallOperationResult(
                succeeded: true,
                log: logLines.joined(separator: "\n"),
                summary: options.dryRun
                    ? "Dry run completed — see Logs."
                    : (recallAppVersion.map { "Installed NotRecall (Recall \($0))." } ?? "Installed NotRecall.")
            )
        } catch {
            log("Error: \(error.localizedDescription)")
            return NotRecallOperationResult(
                succeeded: false,
                log: logLines.joined(separator: "\n"),
                summary: "Install failed: \(error.localizedDescription)"
            )
        }
    }

    static func uninstall() -> NotRecallOperationResult {
        var logLines: [String] = []
        func log(_ line: String) {
            logLines.append(line)
        }

        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser
        let npSupport: URL = {
            if let override = env["NOTPROTON_SUPPORT"], !override.isEmpty {
                return URL(filePath: override)
            }
            return home.appending(path: "Library/Application Support/notproton")
        }()
        let nrSupport = home.appending(path: "Library/Application Support/notrecall")
        let nrCache = home.appending(path: "Library/Caches/notrecall")
        let toolDst = home.appending(path: "Library/Application Support/Steam/compatibilitytools.d/notrecall-proton")
        let pluginDst = npSupport.appending(path: "plugins/notrecall.conf")

        do {
            log("==> Removing Steam compatibility tool: \(toolDst.path)")
            if entryExists(at: toolDst) {
                try fm.removeItem(at: toolDst)
            }

            if entryExists(at: pluginDst) {
                log("==> Removing NotProton plugin: \(pluginDst.path)")
                try fm.removeItem(at: pluginDst)
            }

            log("==> Removing staged runtime, launchers & settings: \(nrSupport.path)")
            if entryExists(at: nrSupport) {
                try fm.removeItem(at: nrSupport)
            }

            if entryExists(at: nrCache) {
                log("==> Removing downloaded Recall cache: \(nrCache.path)")
                try fm.removeItem(at: nrCache)
            }

            log("Uninstall complete. Restart Steam to refresh the compatibility tool list.")
            return NotRecallOperationResult(
                succeeded: true,
                log: logLines.joined(separator: "\n"),
                summary: "Uninstalled NotRecall. Restart Steam to refresh the compatibility tool list."
            )
        } catch {
            log("Error: \(error.localizedDescription)")
            return NotRecallOperationResult(
                succeeded: false,
                log: logLines.joined(separator: "\n"),
                summary: "Uninstall failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    private static func locateResourcesRoot() -> URL? {
        let fm = FileManager.default
        if let resDir = Bundle.main.resourceURL,
           fm.fileExists(atPath: resDir.appending(path: "compat/run").path) {
            return resDir
        }
        var roots: [URL] = []
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(exeDir)
        }
        roots.append(URL(filePath: fm.currentDirectoryPath))
        for start in roots {
            var dir = start
            for _ in 0..<6 {
                if fm.fileExists(atPath: dir.appending(path: "compat/run").path) {
                    return dir
                }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }

    private static func findRecallRuntime(home: URL) -> URL? {
        let fm = FileManager.default
        let appCandidates = [
            URL(filePath: "/Applications/Recall.app"),
            home.appending(path: "Applications/Recall.app")
        ]
        if let hit = appCandidates.first(where: {
            fm.fileExists(atPath: $0.appending(path: "Contents/Resources/runtime.tar.gz").path) ||
            fm.isExecutableFile(atPath: $0.appending(path: "Contents/Resources/runtime/bin/wine").path)
        }) {
            return hit
        }

        let owRoot = home.appending(path: "Library/Application Support/Overwatch2Mac")
        let runtimesDir = owRoot.appending(path: "runtimes")
        if let versions = try? fm.contentsOfDirectory(at: runtimesDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = versions.sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 > d1
            }
            if let hit = sorted.first(where: {
                fm.isExecutableFile(atPath: $0.appending(path: "bin/wine").path) &&
                isDirectory($0.appending(path: "lib/wine/x86_64-unix"))
            }) {
                return hit
            }
        }

        for rel in ["runtime/current", "runtime"] {
            let candidate = owRoot.appending(path: rel)
            if fm.isExecutableFile(atPath: candidate.appending(path: "bin/wine").path) &&
                isDirectory(candidate.appending(path: "lib/wine/x86_64-unix")) {
                return candidate
            }
        }
        return nil
    }

    private static func findHelperBinary(
        named binName: String,
        recallHelpersDir: URL?,
        resourcesRoot: URL?,
        home: URL
    ) -> URL? {
        let fm = FileManager.default
        var searchDirs: [URL] = []
        if binName == "notrecall-sysinfo" {
            if let resourcesRoot {
                searchDirs.append(resourcesRoot.appending(path: "helpers"))
                searchDirs.append(resourcesRoot.appending(path: "build/helpers"))
            }
        } else {
            if let recallHelpersDir { searchDirs.append(recallHelpersDir) }
            searchDirs.append(URL(filePath: "/Applications/Recall.app/Contents/Helpers"))
            searchDirs.append(home.appending(path: "Applications/Recall.app/Contents/Helpers"))
        }

        for dir in searchDirs {
            let direct = dir.appending(path: binName)
            if fm.isExecutableFile(atPath: direct.path) {
                return direct
            }
        }
        return nil
    }

    private static func readNotProtonAdoptBuild(npSupport: URL) -> String? {
        let toolsFile = npSupport.appending(path: "tools")
        guard let text = try? String(contentsOf: toolsFile, encoding: .utf8) else { return nil }
        var first: String?
        var rosetta: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3, !cols[1].isEmpty else { continue }
            if first == nil { first = cols[1] }
            if cols[2] == "rosetta", rosetta == nil { rosetta = cols[1] }
        }
        return rosetta ?? first
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Returns true for existing files, directories, and even broken symlinks.
    private static func entryExists(at url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func copyReplacing(from src: URL, to dst: URL, permissions: Int? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if entryExists(at: dst) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: dst.path)
        }
    }

    private static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(filePath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            try? pipe.fileHandleForWriting.close()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (1, error.localizedDescription)
        }
    }
}
