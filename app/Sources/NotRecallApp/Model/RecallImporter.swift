import Foundation

struct RecallInspection: Sendable {
    let rootURL: URL
    let exists: Bool
    let isValidRecallFolder: Bool
    let shaderCacheBytes: Int64
    let shaderArchiveCount: Int
    let hasShaderCache: Bool
    let settingsINIURL: URL?
    let highlightsDirURL: URL?
    let highlightFileCount: Int
    let highlightsAlreadyInMovies: Bool
    let customDXMTLines: String?

    var hasAnythingToImport: Bool {
        hasShaderCache || settingsINIURL != nil || highlightFileCount > 0 || customDXMTLines != nil
    }

    var formattedShaderSize: String {
        ByteCountFormatter.string(fromByteCount: shaderCacheBytes, countStyle: .file)
    }
}

struct RecallImportOptions: Sendable {
    var importShaders: Bool = true
    var importSettings: Bool = true
    var importHighlights: Bool = true
    var importCustomDXMT: Bool = true
    var queueShaderRebuild: Bool = true

    var hasSelection: Bool {
        importShaders || importSettings || importHighlights || importCustomDXMT
    }
}

enum RecallImporter {
    private static let recallBundleID = "org.overwatch2mac.launcher"

    static func defaultRecallRoot(home: URL) -> URL {
        if let defaults = UserDefaults(suiteName: recallBundleID),
           let saved = defaults.string(forKey: "installLocation"),
           !saved.isEmpty {
            let savedURL = URL(filePath: saved)
            if FileManager.default.fileExists(atPath: savedURL.path) {
                return savedURL
            }
        }
        return home.appending(path: "Library/Application Support/Overwatch2Mac")
    }

    static func inspect(root: URL, home: URL) -> RecallInspection {
        let fm = FileManager.default
        let resolvedRoot = normalizeRecallRoot(root)
        let exists = isDirectory(resolvedRoot)

        let pipelinesDir = resolvedRoot.appending(path: "cache/pipelines")
        let shadersDir = resolvedRoot.appending(path: "cache/shaders")
        let envDir = resolvedRoot.appending(path: "environment")
        let ownerMarker = resolvedRoot.appending(path: ".overwatch-2-mac-owner")

        let isValid = exists && (
            fm.fileExists(atPath: ownerMarker.path) ||
            isDirectory(pipelinesDir) ||
            isDirectory(shadersDir) ||
            isDirectory(envDir)
        )

        var shaderBytes: Int64 = 0
        var archiveCount = 0
        for dir in [pipelinesDir, shadersDir] where isDirectory(dir) {
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let file as URL in enumerator {
                    guard let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          vals.isRegularFile == true else { continue }
                    if file.pathExtension == "metallib" {
                        archiveCount += 1
                    }
                    shaderBytes += Int64(vals.fileSize ?? 0)
                }
            }
        }
        let hasShaderCache = shaderBytes > 0

        let profileDir = findWindowsProfile(in: resolvedRoot)
        let settingsCandidate = profileDir?.appending(path: "Documents/Overwatch/Settings/Settings_v0.ini")
        let settingsURL = settingsCandidate.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }

        let moviesOW = home.appending(path: "Movies/Overwatch").standardizedFileURL
        var highlightsDir: URL?
        var highlightCount = 0
        var alreadyInMovies = false
        if let hlCandidate = profileDir?.appending(path: "Documents/Overwatch/videos/overwatch"),
           entryExists(at: hlCandidate) {
            let resolvedHL = hlCandidate.resolvingSymlinksInPath().standardizedFileURL
            if resolvedHL == moviesOW {
                alreadyInMovies = true
            } else if isDirectory(hlCandidate) {
                highlightsDir = hlCandidate
                if let files = try? fm.contentsOfDirectory(at: hlCandidate, includingPropertiesForKeys: [.isRegularFileKey]) {
                    highlightCount = files.filter { url in
                        let ext = url.pathExtension.lowercased()
                        guard ["mp4", "webm", "mov", "mkv"].contains(ext) else { return false }
                        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    }.count
                }
            }
        }

        var customLines: String?
        if let defaults = UserDefaults(suiteName: recallBundleID),
           defaults.bool(forKey: "rendererCustomOn"),
           let raw = defaults.string(forKey: "rendererCustom") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                customLines = trimmed
            }
        }

        return RecallInspection(
            rootURL: resolvedRoot,
            exists: exists,
            isValidRecallFolder: isValid,
            shaderCacheBytes: shaderBytes,
            shaderArchiveCount: archiveCount,
            hasShaderCache: hasShaderCache,
            settingsINIURL: settingsURL,
            highlightsDirURL: highlightsDir,
            highlightFileCount: highlightCount,
            highlightsAlreadyInMovies: alreadyInMovies,
            customDXMTLines: customLines
        )
    }

    static func performImport(
        inspection: RecallInspection,
        options: RecallImportOptions,
        compatDir: URL,
        home: URL
    ) -> NotRecallOperationResult {
        var logLines: [String] = []
        var importedParts: [String] = []
        func log(_ line: String) { logLines.append(line) }

        let fm = FileManager.default
        log("==> Importing from Recall folder: \(inspection.rootURL.path)")
        log("==> Target Steam Overwatch compatdata: \(compatDir.path)")

        do {
            try fm.createDirectory(at: compatDir, withIntermediateDirectories: true)

            // 1. Learned shader & pipeline caches
            if options.importShaders && inspection.hasShaderCache {
                let dstCacheRoot = compatDir.appending(path: "notrecall-cache/cache")
                try fm.createDirectory(at: dstCacheRoot, withIntermediateDirectories: true)

                let srcPipelines = inspection.rootURL.appending(path: "cache/pipelines")
                let srcShaders = inspection.rootURL.appending(path: "cache/shaders")
                var copiedFiles = 0

                if isDirectory(srcPipelines) {
                    let dstPipelines = dstCacheRoot.appending(path: "pipelines")
                    copiedFiles += try mergeDirectoryContents(from: srcPipelines, to: dstPipelines)
                    log("    Copied pipeline cache into \(dstPipelines.path)")
                }
                if isDirectory(srcShaders) {
                    let dstShaders = dstCacheRoot.appending(path: "shaders")
                    copiedFiles += try mergeDirectoryContents(from: srcShaders, to: dstShaders)
                    log("    Copied shader cache into \(dstShaders.path)")
                }

                if options.queueShaderRebuild {
                    let marker = dstCacheRoot.appending(path: "rebuild-shaders")
                    try Data("1\n".utf8).write(to: marker, options: .atomic)
                    log("    Queued shader rebuild so learned recipes recompile for NotRecall's DXMT.")
                }
                importedParts.append("shaders (\(copiedFiles) files)")
            }

            // 2. Overwatch Settings_v0.ini
            if options.importSettings, let srcINI = inspection.settingsINIURL {
                let dstSettingsDir = compatDir.appending(path: "pfx/drive_c/users/steamuser/Documents/Overwatch/Settings")
                let dstINI = dstSettingsDir.appending(path: "Settings_v0.ini")
                try fm.createDirectory(at: dstSettingsDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dstINI.path) {
                    let backup = compatDir.appending(path: "Settings_v0.before-recall-import.ini")
                    if fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: backup) }
                    try fm.copyItem(at: dstINI, to: backup)
                    log("    Backed up existing Settings_v0.ini -> \(backup.lastPathComponent)")
                    try fm.removeItem(at: dstINI)
                }
                try fm.copyItem(at: srcINI, to: dstINI)
                // Clear cached display state so compat/run re-syncs dxmt.conf canvas on next launch.
                let displayState = compatDir.appending(path: "notrecall-display.state")
                if fm.fileExists(atPath: displayState.path) {
                    try? fm.removeItem(at: displayState)
                }
                log("    Imported Overwatch Settings_v0.ini")
                importedParts.append("settings")
            }

            // 3. Saved Highlights -> ~/Movies/Overwatch
            if options.importHighlights, let srcHL = inspection.highlightsDirURL, inspection.highlightFileCount > 0 {
                let moviesOW = home.appending(path: "Movies/Overwatch")
                try fm.createDirectory(at: moviesOW, withIntermediateDirectories: true)
                let files = (try? fm.contentsOfDirectory(at: srcHL, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
                var copiedClips = 0
                for file in files {
                    let ext = file.pathExtension.lowercased()
                    guard ["mp4", "webm", "mov", "mkv"].contains(ext),
                          (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let dst = freeDestinationURL(in: moviesOW, fileName: file.lastPathComponent)
                    try fm.copyItem(at: file, to: dst)
                    copiedClips += 1
                }
                log("    Copied \(copiedClips) highlight clip(s) into \(moviesOW.path)")
                if copiedClips > 0 {
                    importedParts.append("\(copiedClips) \(copiedClips == 1 ? "highlight" : "highlights")")
                }
            }

            // 4. Custom dxmt.conf lines from Recall preferences
            if options.importCustomDXMT, let lines = inspection.customDXMTLines {
                let dstConf = compatDir.appending(path: "dxmt.conf")
                let existing = (try? String(contentsOf: dstConf, encoding: .utf8)) ?? ""
                if existing.contains(lines) {
                    log("    Custom dxmt.conf lines already present in \(dstConf.path); skipped duplicate.")
                } else {
                    if !existing.isEmpty {
                        let backup = compatDir.appending(path: "dxmt.conf.before-recall-import")
                        try? existing.write(to: backup, atomically: true, encoding: .utf8)
                    }
                    let prefix = existing.isEmpty ? "" : (existing.hasSuffix("\n") ? existing + "\n" : existing + "\n\n")
                    let updated = prefix + "# Imported from Recall\n" + lines + "\n"
                    try updated.write(to: dstConf, atomically: true, encoding: .utf8)
                    log("    Imported custom dxmt.conf lines into \(dstConf.path)")
                    importedParts.append("custom dxmt.conf")
                }
            }

            if importedParts.isEmpty {
                log("Nothing was imported (selected items were empty or already up to date).")
                return NotRecallOperationResult(
                    succeeded: true,
                    log: logLines.joined(separator: "\n"),
                    summary: "Nothing new to import from Recall."
                )
            }

            let joined = importedParts.joined(separator: ", ")
            log("")
            log("Done! Imported \(joined) from Recall.")
            return NotRecallOperationResult(
                succeeded: true,
                log: logLines.joined(separator: "\n"),
                summary: "Imported \(joined) from Recall."
            )
        } catch {
            log("Error: \(error.localizedDescription)")
            return NotRecallOperationResult(
                succeeded: false,
                log: logLines.joined(separator: "\n"),
                summary: "Import from Recall failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    private static func normalizeRecallRoot(_ url: URL) -> URL {
        let fm = FileManager.default
        let clean = url.standardizedFileURL
        if clean.lastPathComponent == "Overwatch2Mac" ||
            fm.fileExists(atPath: clean.appending(path: ".overwatch-2-mac-owner").path) ||
            isDirectory(clean.appending(path: "cache/pipelines")) ||
            isDirectory(clean.appending(path: "environment")) {
            return clean
        }
        let nested = clean.appending(path: "Overwatch2Mac")
        if isDirectory(nested) {
            return nested
        }
        return clean
    }

    private static func findWindowsProfile(in recallRoot: URL) -> URL? {
        let fm = FileManager.default
        let usersDir = recallRoot.appending(path: "environment/drive_c/users")
        guard isDirectory(usersDir) else { return nil }
        let crossover = usersDir.appending(path: "crossover")
        if isDirectory(crossover) { return crossover }
        let names = (try? fm.contentsOfDirectory(atPath: usersDir.path))?.sorted() ?? []
        for name in names where name != "Public" && !name.hasPrefix(".") {
            let candidate = usersDir.appending(path: name)
            if isDirectory(candidate) { return candidate }
        }
        return nil
    }

    private static func mergeDirectoryContents(from srcDir: URL, to dstDir: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        var count = 0
        guard let enumerator = fm.enumerator(
            at: srcDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let srcPrefix = srcDir.standardizedFileURL.path
        for case let item as URL in enumerator {
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(srcPrefix + "/") else { continue }
            let relPath = String(itemPath.dropFirst(srcPrefix.count + 1))
            let dstItem = dstDir.appending(path: relPath)
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if vals?.isDirectory == true {
                try fm.createDirectory(at: dstItem, withIntermediateDirectories: true)
            } else if vals?.isRegularFile == true {
                try fm.createDirectory(at: dstItem.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dstItem.path) {
                    try fm.removeItem(at: dstItem)
                }
                try fm.copyItem(at: item, to: dstItem)
                count += 1
            }
        }
        return count
    }

    private static func freeDestinationURL(in dir: URL, fileName: String) -> URL {
        let direct = dir.appending(path: fileName)
        if !entryExists(at: direct) { return direct }
        let ns = fileName as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var index = 2
        while true {
            let nextName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = dir.appending(path: nextName)
            if !entryExists(at: candidate) { return candidate }
            index += 1
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func entryExists(at url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
