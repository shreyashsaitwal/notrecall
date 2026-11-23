import CryptoKit
import Foundation

struct NotRecallInstallOptions: Sendable {
    var runtimeSource: URL? = nil
    var runtimeOnly: Bool = false
    var dryRun: Bool = false
}

struct NotRecallOperationResult: Sendable {
    let succeeded: Bool
    let log: String
    let summary: String
}

struct BundledRuntimeInfo: Sendable {
    let archiveURL: URL
    let version: String?
    let dxmtBase: String?
    let winePatchesSHA256: String?
    let sha256: String?
}

enum NotRecallInstaller {
    private struct InstallerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func locateBundledRuntime() -> BundledRuntimeInfo? {
        guard let resRoot = locateResourcesRoot() else { return nil }
        let fm = FileManager.default
        let candidates = [
            (resRoot.appending(path: "runtime.tar.gz"), resRoot.appending(path: "bundled-runtime.json")),
            (resRoot.appending(path: "build/runtime/runtime.tar.gz"), resRoot.appending(path: "build/runtime/bundled-runtime.json")),
        ]
        for (archiveURL, metaURL) in candidates where fm.fileExists(atPath: archiveURL.path) {
            var version: String?
            var dxmtBase: String?
            var winePatchesSHA256: String?
            var sha: String?
            if let data = try? Data(contentsOf: metaURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                version = json["version"] as? String
                dxmtBase = json["dxmtBase"] as? String
                winePatchesSHA256 = json["winePatchesSHA256"] as? String
                sha = json["runtimeSHA256"] as? String
            }
            return BundledRuntimeInfo(
                archiveURL: archiveURL,
                version: version,
                dxmtBase: dxmtBase,
                winePatchesSHA256: winePatchesSHA256,
                sha256: sha
            )
        }
        return nil
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
        let bundled = locateBundledRuntime()

        let pid = ProcessInfo.processInfo.processIdentifier
        let stageRuntime = nrSupport.appending(path: ".runtime.staging.\(pid)")
        let oldRuntime = nrSupport.appending(path: ".runtime.old.\(pid)")

        defer {
            if fm.fileExists(atPath: stageRuntime.path) {
                try? fm.removeItem(at: stageRuntime)
            }
            let liveRuntime = nrSupport.appending(path: "runtime")
            if fm.fileExists(atPath: liveRuntime.path) && fm.fileExists(atPath: oldRuntime.path) {
                try? fm.removeItem(at: oldRuntime)
            }
        }

        do {
            // 1. Locate runtime source (custom override or bundled runtime.tar.gz).
            let runtimeSrc: URL
            var expectedSHA: String?
            var runtimeVersion: String?
            if let custom = options.runtimeSource {
                runtimeSrc = custom
            } else if let bundled {
                runtimeSrc = bundled.archiveURL
                expectedSHA = bundled.sha256
                runtimeVersion = bundled.version
            } else {
                throw InstallerError(
                    message: "Bundled runtime.tar.gz not found inside NotRecall.app. Rebuild with 'make build-app' or choose a local runtime archive/folder."
                )
            }

            let resolvedLower = runtimeSrc.lastPathComponent.lowercased()
            let runtimeIsArchive = (resolvedLower.hasSuffix(".tar.gz") || resolvedLower.hasSuffix(".tgz"))
                && fm.fileExists(atPath: runtimeSrc.path)

            if !options.dryRun {
                if !runtimeIsArchive && !fm.isExecutableFile(atPath: runtimeSrc.appending(path: "bin/wine").path) {
                    throw InstallerError(message: "Runtime source \(runtimeSrc.path) does not contain bin/wine.")
                }
                if runtimeIsArchive, let sha = expectedSHA, !sha.isEmpty {
                    log("==> Verifying bundled runtime.tar.gz SHA-256")
                    let actualSHA = try sha256Hex(of: runtimeSrc)
                    if actualSHA.lowercased() != sha.lowercased() {
                        throw InstallerError(message: "runtime.tar.gz SHA-256 mismatch (expected \(sha), got \(actualSHA)).")
                    }
                }
            }

            // 2. Verify NotProton's Steamworks bridge is available.
            let bridgeSrc = npSupport.appending(path: "bridge")
            if !options.dryRun && !isDirectory(bridgeSrc) {
                throw InstallerError(message: "NotProton bridge not found at \(bridgeSrc.path). Open NotProton and click Install first so its Steamworks bridge is staged.")
            }

            log("==> Staging runtime from: \(runtimeSrc.path)")
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

            // 3. Wire NotProton Steamworks bridge (lsteamclient + patched ntdll.dll).
            log("==> Wiring NotProton Steamworks bridge into staged runtime")
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
            }

            // 4. Stage bundled shader pipeline helpers.
            func stageShaderHelpers() throws {
                log("==> Installing bundled shader pipeline helpers")
                let bins = ["ow2-pipeline", "pipeline-prepare", "pipeline-warm", "libpipeline_prepare.dylib"]
                var stagedCount = 0
                var missing: [String] = []
                for bin in bins {
                    if let found = findBundledHelper(named: bin, resourcesRoot: resourcesRoot) {
                        log("    Staging \(bin) from: \(found.path)")
                        let dst = nrSupport.appending(path: "helpers/\(bin)")
                        if options.dryRun {
                            log("[dry-run] cp -f \(found.path) \(dst.path)")
                        } else {
                            try copyReplacing(from: found, to: dst, permissions: 0o755)
                        }
                        stagedCount += 1
                    } else {
                        missing.append(bin)
                    }
                }
                if stagedCount == 0 {
                    log("    Note: shader pipeline helpers not bundled (in-game DXMT shader caching still works).")
                } else if !missing.isEmpty {
                    log("    Warning: missing bundled helper(s): \(missing.joined(separator: " "))")
                }
            }

            if options.runtimeOnly {
                try stageShaderHelpers()
                let verSuffix = runtimeVersion.map { " (\($0))" } ?? ""
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

            try stageShaderHelpers()

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

            if let sysinfoBin = findBundledHelper(named: "notrecall-sysinfo", resourcesRoot: resRoot) {
                log("    Staging notrecall-sysinfo from: \(sysinfoBin.path)")
                let dst = nrSupport.appending(path: "helpers/notrecall-sysinfo")
                if options.dryRun {
                    log("[dry-run] cp -f \(sysinfoBin.path) \(dst.path)")
                } else {
                    try copyReplacing(from: sysinfoBin, to: dst, permissions: 0o755)
                }
            }

            // 5. Install Steam compatibility tool bundle, NotProton adoption metadata, and plugin.
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

            let verSentence = runtimeVersion.map { " Installed bundled runtime \($0)." } ?? ""
            log("")
            log("Done!\(verSentence) Restart Steam, then select 'NotRecall' under:")
            log("  Game -> Properties -> Compatibility -> Force the use of a specific Steam Play compatibility tool")
            log("Configure MetalFX, Metal HUD, mouse mode, and other options directly in Steam's Compatibility tab.")

            return NotRecallOperationResult(
                succeeded: true,
                log: logLines.joined(separator: "\n"),
                summary: options.dryRun
                    ? "Dry run completed — see Logs."
                    : (runtimeVersion.map { "Installed NotRecall (\($0))." } ?? "Installed NotRecall.")
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
                log("==> Removing NotRecall cache: \(nrCache.path)")
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

    static func locateResourcesRoot() -> URL? {
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

    private static func findBundledHelper(named binName: String, resourcesRoot: URL?) -> URL? {
        guard let resourcesRoot else { return nil }
        let fm = FileManager.default
        let searchDirs = [
            resourcesRoot.appending(path: "helpers"),
            resourcesRoot.appending(path: "build/helpers")
        ]
        for dir in searchDirs {
            let candidate = dir.appending(path: binName)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
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
