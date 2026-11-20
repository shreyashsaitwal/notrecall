import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct ShaderCacheEntry: Identifiable, Hashable, Sendable {
    let appID: String
    let gameName: String?
    let path: URL
    let sizeBytes: Int64
    let archiveCount: Int
    let rebuildPending: Bool

    var id: String { path.path }

    var displayTitle: String {
        if let name = gameName, !name.isEmpty {
            return name
        }
        return "Steam AppID \(appID)"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct HealthWarning: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let isCritical: Bool
}

@MainActor
final class AppState: ObservableObject {
    @Published var rosettaInstalled = false
    @Published var macOSSupported = true
    @Published var steamAppURL: URL?
    @Published var notProtonAppURL: URL?
    @Published var notProtonBridgeReady = false
    @Published var recallRuntimeDetected: URL?
    @Published var customRuntimeURL: URL?
    @Published var stagedRuntimeReady = false
    @Published var stagedRuntimeVersion: String?
    @Published var steamToolInstalled = false
    @Published var pluginInstalled = false
    @Published var helpersInstalled = false
    @Published var healthWarnings: [HealthWarning] = []
    @Published var overwatchInstalled = false
    @Published var overwatchCompatTool: String?

    @Published var steamLibraryCount = 0
    @Published var shaderCaches: [ShaderCacheEntry] = []
    @Published var recentLogText = ""
    @Published var recentLogTitle = ""
    @Published var statusMessage = ""
    @Published var isBusy = false
    @Published var selectedTab = 0

    let home = FileManager.default.homeDirectoryForCurrentUser

    var notProtonSupport: URL { home.appending(path: "Library/Application Support/notproton") }
    var notRecallSupport: URL { home.appending(path: "Library/Application Support/notrecall") }
    var steamCompatTool: URL { home.appending(path: "Library/Application Support/Steam/compatibilitytools.d/notrecall-proton") }
    var steamConfigVDF: URL { home.appending(path: "Library/Application Support/Steam/config/config.vdf") }
    var overwatchHighlightsDir: URL { home.appending(path: "Movies/Overwatch") }
    var pluginFile: URL { notProtonSupport.appending(path: "plugins/50-notrecall.conf") }

    var activeRuntimeSource: URL? { customRuntimeURL ?? recallRuntimeDetected }
    var overwatchConfiguredForNotRecall: Bool { overwatchCompatTool == "notrecall-proton" }

    var hasMissingPrerequisites: Bool {
        !rosettaInstalled || steamAppURL == nil || !notProtonBridgeReady
    }

    func refresh(preserveLog: Bool = false) async {
        let fm = FileManager.default
        macOSSupported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
        )
        steamAppURL = Self.detectApp(named: "Steam.app", home: home)
        notProtonAppURL = Self.detectApp(named: "NotProton.app", home: home)
        notProtonBridgeReady = fm.fileExists(atPath: notProtonSupport.appending(path: "bridge").path)
        stagedRuntimeReady = fm.isExecutableFile(atPath: notRecallSupport.appending(path: "runtime/bin/wine").path)
        stagedRuntimeVersion = Self.readRuntimeVersion(in: notRecallSupport.appending(path: "runtime"))
        steamToolInstalled = fm.isExecutableFile(atPath: steamCompatTool.appending(path: "run").path)
        pluginInstalled = fm.fileExists(atPath: pluginFile.path)
        helpersInstalled = fm.isExecutableFile(atPath: notRecallSupport.appending(path: "helpers/portable-pipeline").path)

        recallRuntimeDetected = Self.detectRecallRuntime(home: home)

        let libraries = Self.discoverSteamLibraries(home: home)
        steamLibraryCount = libraries.count
        let osOK = macOSSupported
        let configVDF = steamConfigVDF

        let scanResult = await Task.detached { () -> (Bool, [HealthWarning], Bool, String?, [ShaderCacheEntry], String, String) in
            let rosetta = Self.probeRosetta()
            let warnings = Self.collectHealthWarnings(macOSSupported: osOK, libraries: libraries)
            let names = Self.loadSteamAppNames(across: libraries)
            let owInstalled = names["2357570"] != nil
            let owTool = SteamVDF.readCompatTool(forAppID: "2357570", in: configVDF)
            let caches = Self.scanShaderCaches(across: libraries, appNames: names)
            let (logTitle, logText) = Self.loadLatestLog(across: libraries, appNames: names)
            return (rosetta, warnings, owInstalled, owTool, caches, logTitle, logText)
        }.value

        rosettaInstalled = scanResult.0
        healthWarnings = scanResult.1
        overwatchInstalled = scanResult.2
        overwatchCompatTool = scanResult.3
        shaderCaches = scanResult.4
        if !preserveLog {
            recentLogTitle = scanResult.5
            recentLogText = scanResult.6
        }
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            statusMessage = "Could not build Input Monitoring Settings URL."
            return
        }
        if NSWorkspace.shared.open(url) {
            statusMessage = "Opened Input Monitoring settings. Add Steam.app if using 8,000 Hz Raw HID mouse mode."
        } else {
            statusMessage = "Could not open System Settings → Privacy & Security → Input Monitoring."
        }
    }

    func revealSteamInFinder() {
        if let steam = steamAppURL {
            NSWorkspace.shared.activateFileViewerSelecting([steam])
            statusMessage = "Revealed Steam.app in Finder — drag it into Input Monitoring for 8,000 Hz mouse polling."
        } else {
            statusMessage = "Steam.app was not found in /Applications or ~/Applications."
        }
    }

    func openNotProton() {
        if let app = notProtonAppURL {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            statusMessage = "Opened NotProton.app — click Install there to stage the Steamworks bridge."
        } else {
            statusMessage = "NotProton.app not found in /Applications or ~/Applications. Install NotProton first."
        }
    }

    func installRosetta() {
        let proc = Process()
        proc.executableURL = URL(filePath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal"]
        try? proc.run()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("softwareupdate --install-rosetta --agree-to-license", forType: .string)
        statusMessage = "Copied 'softwareupdate --install-rosetta --agree-to-license' to clipboard and opened Terminal."
    }

    func selectLocalRuntime() {
        let panel = NSOpenPanel()
        panel.title = "Select Recall Runtime Folder or Archive"
        panel.message = "Choose a runtime.tar.gz archive or an unpacked Recall runtime directory containing bin/wine."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.gzip, .folder]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fm = FileManager.default
        let isArchive = url.lastPathComponent.hasSuffix(".tar.gz") || url.lastPathComponent.hasSuffix(".tgz")
        let isUnpacked = fm.isExecutableFile(atPath: url.appending(path: "bin/wine").path)
        if isArchive || isUnpacked {
            customRuntimeURL = url
            statusMessage = "Selected custom runtime: \(url.lastPathComponent)"
        } else {
            statusMessage = "Selected item is not a .tar.gz archive or a runtime folder containing bin/wine."
        }
    }

    func clearCustomRuntime() {
        customRuntimeURL = nil
        statusMessage = "Reverted to auto-detected Recall runtime."
    }

    func restartSteam() async {
        guard let steam = steamAppURL else {
            statusMessage = "Steam.app not found in /Applications or ~/Applications."
            return
        }
        isBusy = true
        defer { isBusy = false }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam")
        for app in running {
            app.terminate()
        }
        if !running.isEmpty {
            var exited = false
            for _ in 0..<20 {
                let stillRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam")
                if stillRunning.isEmpty {
                    exited = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !exited {
                statusMessage = "Steam is still shutting down — wait for it to finish closing, then relaunch Steam."
                return
            }
        }
        do {
            try await NSWorkspace.shared.openApplication(at: steam, configuration: NSWorkspace.OpenConfiguration())
            statusMessage = "Restarted Steam."
        } catch {
            statusMessage = "Failed to relaunch Steam: \(error.localizedDescription)"
        }
    }

    func playOverwatch() {
        guard let url = URL(string: "steam://rungameid/2357570") else { return }
        if NSWorkspace.shared.open(url) {
            statusMessage = "Launching Overwatch via Steam…"
        } else {
            statusMessage = "Could not open steam://rungameid/2357570."
        }
    }

    func openOverwatchHighlights() {
        let fm = FileManager.default
        try? fm.createDirectory(at: overwatchHighlightsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(overwatchHighlightsDir)
        statusMessage = "Opened ~/Movies/Overwatch."
    }

    func configureOverwatchInSteam() async {
        guard let steam = steamAppURL else {
            statusMessage = "Steam.app not found in /Applications or ~/Applications."
            return
        }
        guard FileManager.default.fileExists(atPath: steamConfigVDF.path) else {
            statusMessage = "Steam config.vdf not found. Launch and sign into Steam once first."
            return
        }
        isBusy = true
        defer { isBusy = false }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam")
        for app in running {
            app.terminate()
        }
        if !running.isEmpty {
            var exited = false
            for _ in 0..<24 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").isEmpty {
                    exited = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !exited {
                statusMessage = "Steam did not exit in time — quit Steam manually, then click Configure in Steam again."
                return
            }
        }

        do {
            try SteamVDF.setCompatTool(forAppID: "2357570", toolName: "notrecall-proton", in: steamConfigVDF)
            try await NSWorkspace.shared.openApplication(at: steam, configuration: NSWorkspace.OpenConfiguration())
            statusMessage = "Configured Overwatch (AppID 2357570) to use NotRecall in Steam and relaunched Steam."
        } catch {
            statusMessage = "Failed to update Steam config.vdf: \(error.localizedDescription)"
        }
        await refresh()
    }

    func runProjectScript(_ relativePath: String, extraArgs: [String] = [], switchToLogs: Bool = false) async {
        guard let scriptURL = locateProjectScript(relativePath) else {
            statusMessage = "Could not locate \(relativePath) next to NotRecallApp."
            return
        }
        isBusy = true
        defer { isBusy = false }
        let result = await Task.detached { () -> (Int32, String) in
            let proc = Process()
            proc.executableURL = URL(filePath: "/bin/sh")
            proc.arguments = [scriptURL.path] + extraArgs
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
        }.value
        statusMessage = result.0 == 0 ? "Completed \(relativePath)." : "Failed (\(result.0)): see Logs tab."
        recentLogTitle = "\(relativePath) \(extraArgs.joined(separator: " "))"
        recentLogText = result.1
        if switchToLogs || result.0 != 0 {
            selectedTab = 2
        }
        await refresh(preserveLog: true)
    }

    func clearShaderCache(_ entry: ShaderCacheEntry) async {
        do {
            try FileManager.default.removeItem(at: entry.path)
            statusMessage = "Cleared shader cache for \(entry.displayTitle)."
        } catch {
            statusMessage = "Failed to clear cache: \(error.localizedDescription)"
        }
        await refresh()
    }

    func requestRebuildShaders(_ entry: ShaderCacheEntry) async {
        let markerDir = entry.path.appending(path: "cache")
        let marker = markerDir.appending(path: "rebuild-shaders")
        do {
            try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
            try Data("1\n".utf8).write(to: marker)
            statusMessage = "Queued shader rebuild for \(entry.displayTitle) on next launch."
        } catch {
            statusMessage = "Failed to queue shader rebuild: \(error.localizedDescription)"
        }
        await refresh()
    }

    func copyDiagnostics() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let chip = Self.hardwareBrandString()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let logTail = recentLogText.split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n")

        let report = """
        NotRecall Diagnostics
        =====================
        App Version:        \(appVersion)
        macOS:              \(osVersion) (\(macOSSupported ? ">=26.5 ok" : "<26.5 unsupported"))
        Hardware:           \(chip)
        Rosetta 2:          \(rosettaInstalled ? "verified (arch -x86_64)" : "missing")
        Health Warnings:    \(healthWarnings.isEmpty ? "none" : healthWarnings.map(\.id).joined(separator: ", "))
        Steam.app:          \(steamAppURL?.path ?? "missing")
        Steam Libraries:    \(steamLibraryCount)
        NotProton Bridge:   \(notProtonBridgeReady ? "ready" : "missing")
        Runtime Source:     \(activeRuntimeSource?.path ?? "none")
        Staged Runtime:     \(stagedRuntimeReady ? (stagedRuntimeVersion ?? "ready") : "missing")
        Overwatch (2357570): \(overwatchInstalled ? "installed" : "not found") (compat tool: \(overwatchCompatTool ?? "unset"))
        Steam Compat Tool:  \(steamToolInstalled ? "installed" : "missing")
        NotProton Plugin:   \(pluginInstalled ? "installed" : "missing")
        Shader Helpers:     \(helpersInstalled ? "installed" : "missing")
        Input Monitoring:   manual setup required (grant to Steam.app in System Settings)
        Shader Caches:      \(shaderCaches.count) game(s)

        --- Latest Log Tail (\(recentLogTitle.isEmpty ? "none" : recentLogTitle)) ---
        \(logTail)
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        statusMessage = "Copied diagnostics report to clipboard."
    }

    private func locateProjectScript(_ relativePath: String) -> URL? {
        if let resDir = Bundle.main.resourceURL {
            let bundled = resDir.appending(path: relativePath)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        var roots: [URL] = []
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(exeDir)
        }
        roots.append(URL(filePath: FileManager.default.currentDirectoryPath))
        for start in roots {
            var dir = start
            for _ in 0..<6 {
                let candidate = dir.appending(path: relativePath)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }

    nonisolated private static func probeRosetta() -> Bool {
        let proc = Process()
        proc.executableURL = URL(filePath: "/usr/bin/arch")
        proc.arguments = ["-x86_64", "/usr/bin/true"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func memoryPressureLevel() -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return 1
        }
        return level
    }

    nonisolated private static func collectHealthWarnings(macOSSupported: Bool, libraries: [URL]) -> [HealthWarning] {
        var warnings: [HealthWarning] = []
        if !macOSSupported {
            warnings.append(HealthWarning(
                id: "macos_version",
                title: "macOS 26.5 or newer recommended",
                detail: "Overwatch requires Rosetta fixes from macOS 26.5+; older releases may hang before opening.",
                isCritical: true
            ))
        }
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled {
            warnings.append(HealthWarning(
                id: "low_power_mode",
                title: "Low Power Mode is enabled",
                detail: "Disable Low Power Mode in System Settings → Battery for full CPU/GPU clocks in Overwatch.",
                isCritical: false
            ))
        }
        if info.thermalState == .serious || info.thermalState == .critical {
            warnings.append(HealthWarning(
                id: "thermal_throttling",
                title: "Mac is thermally throttling",
                detail: "macOS is reducing clocks to cool down. Close heavy background apps or improve airflow before queuing.",
                isCritical: info.thermalState == .critical
            ))
        }
        let pressure = memoryPressureLevel()
        if pressure >= 2 {
            warnings.append(HealthWarning(
                id: "memory_pressure",
                title: pressure >= 4 ? "Critical memory pressure" : "High memory pressure",
                detail: "Close memory-heavy apps (or restart if up for days) to avoid input lag and stutters in Overwatch.",
                isCritical: pressure >= 4
            ))
        }
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86400)
        for steamapps in libraries {
            let gpuDir = steamapps.appending(path: "compatdata/2357570/gpu-reports")
            guard let files = try? fm.contentsOfDirectory(at: gpuDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let recentHang = files.first { url in
                guard url.lastPathComponent.hasPrefix("gpu-"), url.pathExtension == "json" else { return false }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard mtime >= cutoff, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("\"gpu_lost\":true") || text.contains("\"hang\"") || text.contains("\"exit_reason\"")
            }
            if recentHang != nil {
                warnings.append(HealthWarning(
                    id: "recent_gpu_hang",
                    title: "Recent Overwatch GPU hang detected",
                    detail: "macOS terminated Overwatch's GPU context in a recent session. Consider rebuilding shaders or lowering Shader Pack Memory Budget.",
                    isCritical: false
                ))
                break
            }
        }
        return warnings
    }

    nonisolated private static func hardwareBrandString() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    nonisolated private static func detectApp(named name: String, home: URL) -> URL? {
        let fm = FileManager.default
        let candidates = [
            URL(filePath: "/Applications").appending(path: name),
            home.appending(path: "Applications").appending(path: name)
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    nonisolated private static func readRuntimeVersion(in runtimeDir: URL) -> String? {
        let manifest = runtimeDir.appending(path: "runtime.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else {
            return nil
        }
        return version
    }

    nonisolated private static func detectRecallRuntime(home: URL) -> URL? {
        let fm = FileManager.default
        // 1. Prefer NotRecall's own bundled runtime.tar.gz inside NotRecall.app/Contents/Resources.
        if let resDir = Bundle.main.resourceURL {
            let bundled = resDir.appending(path: "runtime.tar.gz")
            if fm.fileExists(atPath: bundled.path) { return bundled }
        }
        // 2. Check build/runtime.tar.gz next to executable or repo root.
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            var dir = exeDir
            for _ in 0..<5 {
                let candidate = dir.appending(path: "build/runtime.tar.gz")
                if fm.fileExists(atPath: candidate.path) { return candidate }
                dir.deleteLastPathComponent()
            }
        }
        // 3. Fallback: auto-discover existing Recall runtime on disk.
        let owRoot = home.appending(path: "Library/Application Support/Overwatch2Mac")
        let runtimesDir = owRoot.appending(path: "runtimes")
        if let versions = try? fm.contentsOfDirectory(at: runtimesDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = versions.sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 > d1
            }
            if let hit = sorted.first(where: { fm.isExecutableFile(atPath: $0.appending(path: "bin/wine").path) }) {
                return hit
            }
        }
        let unpackedCandidates = [
            owRoot.appending(path: "runtime/current"),
            owRoot.appending(path: "runtime"),
            URL(filePath: "/Applications/Recall.app/Contents/Resources/runtime")
        ]
        if let hit = unpackedCandidates.first(where: { fm.isExecutableFile(atPath: $0.appending(path: "bin/wine").path) }) {
            return hit
        }
        let archiveCandidates = [
            URL(filePath: "/Applications/Recall.app/Contents/Resources/runtime.tar.gz"),
            home.appending(path: "Applications/Recall.app/Contents/Resources/runtime.tar.gz")
        ]
        return archiveCandidates.first { fm.fileExists(atPath: $0.path) }
    }

    // Parse Steam's libraryfolders.vdf to discover primary + external/secondary Steam libraries.
    nonisolated private static func discoverSteamLibraries(home: URL) -> [URL] {
        let fm = FileManager.default
        let defaultRoot = home.appending(path: "Library/Application Support/Steam")
        var seen = Set<String>()
        var libraries: [URL] = []

        func appendIfExists(_ root: URL) {
            let steamapps = root.appending(path: "steamapps").standardizedFileURL
            if fm.fileExists(atPath: steamapps.path), seen.insert(steamapps.path).inserted {
                libraries.append(steamapps)
            }
        }

        appendIfExists(defaultRoot)

        let vdf = defaultRoot.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            let pattern = #""path"\s+"([^"]+)""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    if let r = Range(match.range(at: 1), in: text) {
                        let rawPath = String(text[r]).replacingOccurrences(of: "\\\\", with: "/")
                        appendIfExists(URL(filePath: rawPath))
                    }
                }
            }
        }
        return libraries
    }

    // Parse appmanifest_<appid>.acf across all Steam libraries for human-readable game titles.
    nonisolated private static func loadSteamAppNames(across libraries: [URL]) -> [String: String] {
        let fm = FileManager.default
        var names: [String: String] = [:]
        let namePattern = #""name"\s+"([^"]+)""#
        let nameRegex = try? NSRegularExpression(pattern: namePattern)

        for steamapps in libraries {
            guard let items = try? fm.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else { continue }
            for file in items {
                let fname = file.lastPathComponent
                guard fname.hasPrefix("appmanifest_"), fname.hasSuffix(".acf") else { continue }
                let appID = String(fname.dropFirst("appmanifest_".count).dropLast(".acf".count))
                guard !appID.isEmpty, names[appID] == nil,
                      let text = try? String(contentsOf: file, encoding: .utf8),
                      let regex = nameRegex else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range),
                   let r = Range(match.range(at: 1), in: text) {
                    names[appID] = String(text[r])
                }
            }
        }
        return names
    }

    nonisolated private static func scanShaderCaches(across libraries: [URL], appNames: [String: String]) -> [ShaderCacheEntry] {
        let fm = FileManager.default
        var result: [ShaderCacheEntry] = []
        for steamapps in libraries {
            let compatData = steamapps.appending(path: "compatdata")
            guard let entries = try? fm.contentsOfDirectory(at: compatData, includingPropertiesForKeys: nil) else { continue }
            for dir in entries {
                let cache = dir.appending(path: "notrecall-cache")
                guard fm.fileExists(atPath: cache.path) else { continue }
                var totalBytes: Int64 = 0
                var archives = 0
                if let enumerator = fm.enumerator(at: cache, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let file as URL in enumerator {
                        if file.pathExtension == "metallib" { archives += 1 }
                        totalBytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
                let appID = dir.lastPathComponent
                let rebuildPending = fm.fileExists(atPath: cache.appending(path: "cache/rebuild-shaders").path)
                result.append(ShaderCacheEntry(
                    appID: appID,
                    gameName: appNames[appID],
                    path: cache,
                    sizeBytes: totalBytes,
                    archiveCount: archives,
                    rebuildPending: rebuildPending
                ))
            }
        }
        return result.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    nonisolated private static func loadLatestLog(across libraries: [URL], appNames: [String: String]) -> (String, String) {
        let fm = FileManager.default
        var logs: [URL] = []
        for steamapps in libraries {
            let compatData = steamapps.appending(path: "compatdata")
            guard let entries = try? fm.contentsOfDirectory(at: compatData, includingPropertiesForKeys: nil) else { continue }
            for dir in entries {
                let log = dir.appending(path: "notrecall-run.log")
                if fm.fileExists(atPath: log.path) { logs.append(log) }
            }
        }
        let sorted = logs.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d0 > d1
        }
        guard let latest = sorted.first, let text = try? String(contentsOf: latest, encoding: .utf8) else {
            return ("", "No notrecall-run.log found yet. Launch a Steam game using NotRecall to generate one.")
        }
        let appID = latest.deletingLastPathComponent().lastPathComponent
        let title = appNames[appID].map { "\($0) (AppID \(appID))" } ?? "AppID \(appID)"
        return (title, "[\(latest.path)]\n\n" + text)
    }
}
