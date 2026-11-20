import AppKit
import Combine
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

struct ShaderCacheEntry: Identifiable, Hashable, Sendable {
    let appID: String
    let gameName: String?
    let path: URL
    let sizeBytes: Int64
    let archiveCount: Int
    let rebuildPending: Bool
    let isCompiling: Bool
    let preparingReady: Int?
    let preparingLearned: Int?
    let needsMacOSOptimization: Bool

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

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case setup
    case shaders
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .setup: return "Setup & Runtime"
        case .shaders: return "Shaders"
        case .logs: return "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .setup: return "shippingbox"
        case .shaders: return "cpu"
        case .logs: return "terminal"
        }
    }
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
    @Published var installedRecallVersion: String?
    @Published var latestRecallRelease: RecallReleaseInfo?
    @Published var isCheckingForUpdates = false
    @Published var selectedSection: SidebarSection = .overview
    @Published var showWhatsNewSheet = false
    @Published var confirmForceQuit = false
    @Published var confirmResetDisplay = false
    @Published var confirmUninstall = false
    @Published var pendingClearShaderEntry: ShaderCacheEntry?
    @Published var pendingRebuildShaderEntry: ShaderCacheEntry?
    @Published var diagnosticsCopied = false
    @Published var downloadProgress: Double?
    @Published var downloadStatusText = ""
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

    var isConfirmingClearShader: Bool {
        get { pendingClearShaderEntry != nil }
        set { if !newValue { pendingClearShaderEntry = nil } }
    }

    var isConfirmingRebuildShader: Bool {
        get { pendingRebuildShaderEntry != nil }
        set { if !newValue { pendingRebuildShaderEntry = nil } }
    }

    private var hasCheckedUpdates = false
    private var activeDownloadTask: Task<Void, Never>?

    let home = FileManager.default.homeDirectoryForCurrentUser

    var notProtonSupport: URL { home.appending(path: "Library/Application Support/notproton") }
    var notRecallSupport: URL { home.appending(path: "Library/Application Support/notrecall") }
    var steamCompatTool: URL { home.appending(path: "Library/Application Support/Steam/compatibilitytools.d/notrecall-proton") }
    var steamConfigVDF: URL { home.appending(path: "Library/Application Support/Steam/config/config.vdf") }
    var overwatchHighlightsDir: URL { home.appending(path: "Movies/Overwatch") }
    var pluginFile: URL { notProtonSupport.appending(path: "plugins/50-notrecall.conf") }

    var activeRuntimeSource: URL? { customRuntimeURL ?? recallRuntimeDetected }
    var overwatchConfiguredForNotRecall: Bool { overwatchCompatTool == "notrecall-proton" }
    var preferredDownloadRelease: RecallReleaseInfo { latestRecallRelease ?? .pinnedDefault }

    var availableRecallUpdate: RecallReleaseInfo? {
        guard let latest = latestRecallRelease else { return nil }
        if let installed = installedRecallVersion, !installed.isEmpty {
            return RecallVersion.compare(latest.version, installed) == .orderedDescending ? latest : nil
        }
        if stagedRuntimeReady {
            return RecallVersion.compare(latest.version, RecallReleaseInfo.pinnedDefault.version) == .orderedDescending ? latest : nil
        }
        return nil
    }

    var hasMissingPrerequisites: Bool {
        !rosettaInstalled || steamAppURL == nil || !notProtonBridgeReady
    }

    var isFullyInstalled: Bool {
        stagedRuntimeReady && steamToolInstalled && pluginInstalled && helpersInstalled
    }

    var isReadyToPlay: Bool {
        !hasMissingPrerequisites && isFullyInstalled && overwatchInstalled && overwatchConfiguredForNotRecall
    }

    var appVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var anyShaderCompiling: Bool {
        shaderCaches.contains(where: \.isCompiling)
    }

    var anyShaderNeedsMacOSOptimization: Bool {
        shaderCaches.contains(where: { $0.needsMacOSOptimization && !$0.isCompiling })
    }

    var stagedRuntimeSummary: String {
        var parts: [String] = []
        if let recallVer = installedRecallVersion {
            parts.append("Recall \(recallVer)")
        }
        if let rtVer = stagedRuntimeVersion {
            parts.append(rtVer)
        }
        if parts.isEmpty {
            return notRecallSupport.appending(path: "runtime").path
        }
        return parts.joined(separator: " · ")
    }

    var totalShaderCacheFormatted: String {
        let total = shaderCaches.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var totalShaderPackCount: Int {
        shaderCaches.reduce(0) { $0 + $1.archiveCount }
    }

    var overwatchShaderEntry: ShaderCacheEntry? {
        shaderCaches.first(where: { $0.appID == "2357570" }) ?? shaderCaches.first
    }

    func dismissStatusMessage() {
        statusMessage = ""
    }

    func openBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else { return }
        if NSWorkspace.shared.open(url) {
            statusMessage = "Opened Battery settings. Turn off Low Power Mode for full performance."
        }
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
        installedRecallVersion = Self.readInstalledRecallVersion(in: notRecallSupport)
        steamToolInstalled = fm.isExecutableFile(atPath: steamCompatTool.appending(path: "run").path)
        pluginInstalled = fm.fileExists(atPath: pluginFile.path)
        helpersInstalled = fm.isExecutableFile(atPath: notRecallSupport.appending(path: "helpers/portable-pipeline").path)

        recallRuntimeDetected = Self.detectRecallRuntime(home: home)

        if !hasCheckedUpdates {
            hasCheckedUpdates = true
            Task { [weak self] in
                await self?.checkForRecallUpdates(silent: true)
            }
        }

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
            statusMessage = "Opened Input Monitoring in System Settings. Add Steam to turn on High-precision mouse."
        } else {
            statusMessage = "Could not open System Settings › Privacy & Security › Input Monitoring."
        }
    }

    func revealSteamInFinder() {
        if let steam = steamAppURL {
            NSWorkspace.shared.activateFileViewerSelecting([steam])
            statusMessage = "Showed Steam in Finder — drag it into Input Monitoring for High-precision mouse."
        } else {
            statusMessage = "Steam wasn’t found in Applications."
        }
    }

    func openNotProton() {
        if let app = notProtonAppURL {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            statusMessage = "Opened NotProton — click Install there so Steam can launch Windows games."
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

    func checkForRecallUpdates(silent: Bool = false) async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            let latest = try await RecallReleaseService.fetchLatestRelease()
            latestRecallRelease = latest
            if !silent {
                if let installed = installedRecallVersion,
                   RecallVersion.compare(latest.version, installed) == .orderedDescending {
                    statusMessage = "Recall \(latest.version) is available (installed: \(installed))."
                    showWhatsNewSheet = true
                } else if let installed = installedRecallVersion {
                    statusMessage = "Recall \(installed) is up to date."
                } else {
                    statusMessage = "Latest Recall release on GitHub: \(latest.version)."
                }
            }
        } catch {
            if !silent {
                statusMessage = "Could not check for Recall updates: \(error.localizedDescription)"
            }
        }
    }

    func downloadAndInstallRecall(_ release: RecallReleaseInfo, runtimeOnly: Bool = false) {
        guard !isBusy else { return }
        activeDownloadTask?.cancel()
        activeDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBusy = true
            self.downloadProgress = 0
            self.downloadStatusText = "Downloading \(release.dmgName)…"
            self.statusMessage = "Downloading Recall \(release.version) from GitHub…"
            defer {
                self.downloadProgress = nil
                self.downloadStatusText = ""
                self.isBusy = false
                self.activeDownloadTask = nil
            }
            do {
                let dmgURL = try await RecallDownloader.download(release: release) { [weak self] fraction, written, total in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.downloadProgress = fraction
                        let wStr = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
                        if total > 0 {
                            let tStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                            self.downloadStatusText = "Downloading \(release.dmgName): \(wStr) / \(tStr)"
                        } else {
                            self.downloadStatusText = "Downloading \(release.dmgName): \(wStr)"
                        }
                    }
                }
                self.downloadProgress = 1.0
                self.downloadStatusText = "Verifying & extracting Recall \(release.version)…"
                var args = ["--runtime", dmgURL.path]
                if runtimeOnly {
                    args.insert("--runtime-only", at: 0)
                }
                await self.runProjectScriptInner("scripts/install.sh", extraArgs: args, switchToLogs: false)
            } catch is CancellationError {
                self.statusMessage = "Cancelled Recall \(release.version) download."
            } catch let err as RecallDownloadError {
                if case .cancelled = err {
                    self.statusMessage = "Cancelled Recall \(release.version) download."
                } else {
                    self.statusMessage = "Failed to download Recall \(release.version): \(err.localizedDescription)"
                }
            } catch {
                self.statusMessage = "Failed to download Recall \(release.version): \(error.localizedDescription)"
            }
        }
    }

    func cancelDownload() {
        activeDownloadTask?.cancel()
        statusMessage = "Cancelling download…"
    }

    func selectLocalRuntime() {
        let panel = NSOpenPanel()
        panel.title = "Select Recall Release or Runtime"
        panel.message = "Choose a Recall .dmg, Recall.app, runtime.tar.gz archive, or an unpacked runtime folder containing bin/wine."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.gzip, .folder, .applicationBundle]
        if let dmgType = UTType(filenameExtension: "dmg") {
            types.insert(dmgType, at: 0)
        }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fm = FileManager.default
        let lower = url.lastPathComponent.lowercased()
        let isDMG = lower.hasSuffix(".dmg")
        let isRecallApp = lower.hasSuffix(".app") && (
            fm.fileExists(atPath: url.appending(path: "Contents/Resources/runtime.tar.gz").path) ||
            fm.isExecutableFile(atPath: url.appending(path: "Contents/Resources/runtime/bin/wine").path)
        )
        let isArchive = lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
        let isUnpacked = fm.isExecutableFile(atPath: url.appending(path: "bin/wine").path)
        if isDMG || isRecallApp || isArchive || isUnpacked {
            customRuntimeURL = url
            statusMessage = "Selected custom runtime: \(url.lastPathComponent)"
        } else {
            statusMessage = "Selected item is not a Recall .dmg, Recall.app, .tar.gz archive, or runtime folder containing bin/wine."
        }
    }

    func clearCustomRuntime() {
        customRuntimeURL = nil
        statusMessage = "Reverted to default Recall runtime source."
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

    var defaultOverwatchResolutionLabel: String {
        let (w, h, _) = Self.mainDisplayDefault()
        return "\(w) × \(h)"
    }

    func forceQuitOverwatch() async {
        isBusy = true
        defer { isBusy = false }
        let libraries = Self.discoverSteamLibraries(home: home)
        let wineserver = notRecallSupport.appending(path: "runtime/bin/wineserver")
        await Task.detached {
            let pkill = Process()
            pkill.executableURL = URL(filePath: "/usr/bin/pkill")
            pkill.arguments = ["-9", "-i", "Overwatch.exe"]
            pkill.standardOutput = FileHandle.nullDevice
            pkill.standardError = FileHandle.nullDevice
            try? pkill.run()
            pkill.waitUntilExit()

            let fm = FileManager.default
            guard fm.isExecutableFile(atPath: wineserver.path) else { return }
            for steamapps in libraries {
                let pfx = steamapps.appending(path: "compatdata/2357570/pfx")
                guard fm.fileExists(atPath: pfx.path) else { continue }
                let proc = Process()
                proc.executableURL = wineserver
                proc.arguments = ["-k"]
                var env = ProcessInfo.processInfo.environment
                env["WINEPREFIX"] = pfx.path
                proc.environment = env
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
            }
        }.value
        statusMessage = "Force quit Overwatch."
    }

    func resetOverwatchDisplaySettings() async {
        let libraries = Self.discoverSteamLibraries(home: home)
        let (defW, defH, defHz) = Self.mainDisplayDefault()
        let fm = FileManager.default
        var owCompatDirs = libraries.map { $0.appending(path: "compatdata/2357570") }
            .filter { fm.fileExists(atPath: $0.appending(path: "pfx").path) }
        if owCompatDirs.isEmpty, let first = libraries.first {
            owCompatDirs = [first.appending(path: "compatdata/2357570")]
        }
        guard let compatDir = owCompatDirs.first else {
            statusMessage = "No Steam library found for Overwatch."
            return
        }
        let settingsDir = compatDir.appending(path: "pfx/drive_c/users/steamuser/Documents/Overwatch/Settings")
        let iniURL = settingsDir.appending(path: "Settings_v0.ini")
        let backupURL = compatDir.appending(path: "Settings_v0.before-display-reset.ini")
        let stateURL = compatDir.appending(path: "notrecall-display.state")
        do {
            try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)
            let orig = (try? String(contentsOf: iniURL, encoding: .utf8)) ?? "[Render.13]\n"
            if fm.fileExists(atPath: iniURL.path) {
                try? orig.write(to: backupURL, atomically: true, encoding: .utf8)
            }
            let nl = orig.contains("\r\n") ? "\r\n" : "\n"
            var lines = orig.isEmpty ? ["[Render.13]", ""] : orig.components(separatedBy: nl)
            var rs = -1
            var re = lines.count
            for i in lines.indices {
                let t = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if rs < 0 && t == "[Render.13]" { rs = i + 1 }
                else if rs >= 0 && t.hasPrefix("[") { re = i; break }
            }
            if rs < 0 {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                lines.append("[Render.13]")
                rs = lines.count
                re = rs
            }
            let updates: [(String, String)] = [
                ("DynamicRenderScale", "0"),
                ("FullScreenHeight", String(defH)),
                ("FullScreenRefresh", String(defHz)),
                ("FullScreenWidth", String(defW)),
                ("FullscreenWindow", "0"),
                ("FullscreenWindowEnabled", "0"),
                ("UseCustomWorldScale", "1"),
                ("WindowMode", "0"),
                ("WindowedFullscreen", "0"),
                ("WindowedHeight", String(defH)),
                ("WindowedPosX", "100"),
                ("WindowedPosY", "100"),
                ("WindowedWidth", String(defW)),
            ]
            var last = rs
            for i in rs..<re where !lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                last = i + 1
            }
            for (key, value) in updates {
                let newLine = "\(key) = \"\(value)\""
                var foundIdx: Int? = nil
                for i in rs..<re {
                    let t = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let eq = t.firstIndex(of: "="),
                       t[..<eq].trimmingCharacters(in: .whitespaces) == key {
                        foundIdx = i
                        break
                    }
                }
                if let idx = foundIdx {
                    lines[idx] = newLine
                } else {
                    lines.insert(newLine, at: last)
                    last += 1
                    re += 1
                }
            }
            var updated = lines.joined(separator: nl)
            if !updated.hasSuffix(nl) { updated += nl }
            try updated.write(to: iniURL, atomically: true, encoding: .utf8)
            try? fm.removeItem(at: stateURL)
            statusMessage = "Reset Overwatch display settings to \(defW) × \(defH) fullscreen. Your graphics quality and FPS settings were kept."
        } catch {
            statusMessage = "Could not reset display settings: \(error.localizedDescription)"
        }
    }

    nonisolated private static func mainDisplayDefault() -> (Int, Int, Int) {
        var width = 1920, height = 1200, refresh = 120
        if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
            let mw = mode.width, mh = mode.height
            if mh > 0 && (Double(mw) / Double(mh)) >= 1.69 {
                height = 1080
            }
            let r = Int(mode.refreshRate.rounded())
            if r >= 24 && r <= 999 {
                refresh = r
            }
        }
        return (width, height, refresh)
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
                let guiGone = NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").isEmpty
                if guiGone && !Self.isSteamHelperRunning() {
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
        isBusy = true
        defer { isBusy = false }
        await runProjectScriptInner(relativePath, extraArgs: extraArgs, switchToLogs: switchToLogs)
    }

    private func runProjectScriptInner(_ relativePath: String, extraArgs: [String] = [], switchToLogs: Bool = false) async {
        guard let scriptURL = locateProjectScript(relativePath) else {
            statusMessage = "Could not locate \(relativePath) next to NotRecallApp."
            return
        }
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
        statusMessage = result.0 == 0 ? "Completed \(relativePath)." : "Failed (\(result.0)): see Logs."
        recentLogTitle = "\(relativePath) \(extraArgs.joined(separator: " "))"
        recentLogText = result.1
        if switchToLogs || result.0 != 0 {
            selectedSection = .logs
        }
        await refresh(preserveLog: true)
    }

    func clearShaderCache(_ entry: ShaderCacheEntry) async {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: entry.path)
            for metalCache in Self.gameAppMetalCacheURLs(forAppID: entry.appID) where fm.fileExists(atPath: metalCache.path) {
                try? fm.removeItem(at: metalCache)
            }
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

    func optimizeShadersNow(_ entry: ShaderCacheEntry) async {
        let hook = notRecallSupport.appending(path: "helpers/pipeline_hook.sh")
        guard FileManager.default.isExecutableFile(atPath: hook.path) else {
            statusMessage = "pipeline_hook.sh not installed — click Install / Update first."
            return
        }
        let recallOWApp = notRecallSupport.appending(path: "runtime/lib/wine/game-mode/Overwatch.app")
        let wrapperApp = notRecallSupport.appending(path: "launchers/\(entry.appID)/NotRecallGame.app")
        let gameApp: URL
        if entry.appID == "2357570", FileManager.default.fileExists(atPath: recallOWApp.appending(path: "Contents/MacOS/wine").path) {
            gameApp = recallOWApp
        } else {
            gameApp = wrapperApp
        }
        let logFile = entry.path.deletingLastPathComponent().appending(path: "notrecall-run.log")
        let args: [String] = [
            hook.path, "post", entry.path.path,
            FileManager.default.fileExists(atPath: gameApp.path) ? gameApp.path : "",
            logFile.path
        ]
        let ok = await Task.detached { () -> Bool in
            let proc = Process()
            proc.executableURL = URL(filePath: "/bin/sh")
            proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }.value
        statusMessage = ok
            ? "Started background shader optimization for \(entry.displayTitle)."
            : "Could not start background shader optimization for \(entry.displayTitle)."
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
        diagnosticsCopied = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.diagnosticsCopied = false
        }
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

    nonisolated private static func isSteamHelperRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(filePath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "steam_osx"]
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
                title: "macOS 26.5 or newer needed",
                detail: "Overwatch needs Rosetta fixes from macOS 26.5 or newer; on older versions it may hang before opening.",
                isCritical: true
            ))
        }
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled {
            warnings.append(HealthWarning(
                id: "low_power_mode",
                title: "Low Power Mode is on",
                detail: "Turn off Low Power Mode in System Settings › Battery so your Mac runs at full speed in matches.",
                isCritical: false
            ))
        }
        if info.thermalState == .serious || info.thermalState == .critical {
            warnings.append(HealthWarning(
                id: "thermal_throttling",
                title: "Your Mac is running hot",
                detail: "macOS is slowing down to cool off. Close heavy apps or give your Mac more airflow before playing.",
                isCritical: info.thermalState == .critical
            ))
        }
        let pressure = memoryPressureLevel()
        if pressure >= 2 {
            warnings.append(HealthWarning(
                id: "memory_pressure",
                title: pressure >= 4 ? "Your Mac is very low on memory" : "Your Mac is low on memory",
                detail: "Close apps you aren’t using to prevent stutters and input lag during matches.",
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
                guard mtime >= cutoff,
                      let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["schema"] as? Int == 1,
                      let proc = json["process"] as? String,
                      proc.caseInsensitiveCompare("Overwatch.exe") == .orderedSame else {
                    return false
                }
                let ended = json["ended_process"] as? Bool ?? false
                let revoked = json["access_revoked"] != nil
                let errors = (json["errors"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
                let hangs = (errors["hang"] ?? 0) + (errors["timeout"] ?? 0)
                return ended || revoked || hangs > 0
            }
            if recentHang != nil {
                warnings.append(HealthWarning(
                    id: "recent_gpu_hang",
                    title: "Overwatch’s graphics stopped responding recently",
                    detail: "Try Rebuild Shaders in Shaders, or lower Shader memory in Steam’s Compatibility settings.",
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

    nonisolated private static func readInstalledRecallVersion(in supportDir: URL) -> String? {
        let releaseFile = supportDir.appending(path: "recall-release.json")
        guard let data = try? Data(contentsOf: releaseFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["appVersion"] as? String,
              !version.isEmpty else {
            return nil
        }
        return version
    }

    nonisolated private static func detectRecallRuntime(home: URL) -> URL? {
        let fm = FileManager.default
        // 1. Prefer an installed Recall.app bundle so runtime + shader helpers stay version-locked.
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
        // 2. Fallback: existing Overwatch2Mac unpacked runtimes on disk.
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
            owRoot.appending(path: "runtime")
        ]
        if let hit = unpackedCandidates.first(where: { fm.isExecutableFile(atPath: $0.appending(path: "bin/wine").path) }) {
            return hit
        }
        // 3. Local dev build/runtime.tar.gz if present.
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            var dir = exeDir
            for _ in 0..<5 {
                let candidate = dir.appending(path: "build/runtime.tar.gz")
                if fm.fileExists(atPath: candidate.path) { return candidate }
                dir.deleteLastPathComponent()
            }
        }
        return nil
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

    nonisolated private static func gameAppMetalCacheURLs(forAppID appID: String) -> [URL] {
        guard !appID.isEmpty, appID.allSatisfy(\.isNumber) else { return [] }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count) > 0 else { return [] }
        let root = URL(filePath: String(cString: buf))
        var urls = [
            root.appending(path: "io.shreyash.notrecall.game.\(appID)/com.apple.metal"),
            root.appending(path: "com.notrecall.game.\(appID)/com.apple.metal")
        ]
        if appID == "2357570" {
            urls.append(root.appending(path: "org.overwatch2mac.overwatch/com.apple.metal"))
        }
        return urls
    }

    nonisolated private static func isPrecompileRunning(at cacheRoot: URL) -> Bool {
        let pidFile = cacheRoot.appending(path: "precompile.pid")
        guard let raw = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(raw), pid > 0, kill(pid, 0) == 0 else {
            return false
        }
        let proc = Process()
        proc.executableURL = URL(filePath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "args="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            try? pipe.fileHandleForWriting.close()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let args = String(decoding: data, as: UTF8.self)
            return args.contains("portable-pipeline")
        } catch {
            return false
        }
    }

    nonisolated private static func readPreparingProgress(at cacheRoot: URL) -> (Int, Int)? {
        let url = cacheRoot.appending(path: "cache/preparing.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ready = json["ready"] as? Int,
              let learned = json["learned"] as? Int, learned > 0 else {
            return nil
        }
        return (ready, learned)
    }

    nonisolated private static func needsMacOSOptimization(at cacheRoot: URL) -> Bool {
        let fm = FileManager.default
        let currentOS = ProcessInfo.processInfo.operatingSystemVersionString
        let optURL = cacheRoot.appending(path: "cache/optimized.json")
        if let data = try? Data(contentsOf: optURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let macos = json["macos"] as? String, !macos.isEmpty {
            return macos != currentOS
        }
        let pipelinesDir = cacheRoot.appending(path: "cache/pipelines")
        if let dirs = try? fm.contentsOfDirectory(at: pipelinesDir, includingPropertiesForKeys: nil) {
            for dir in dirs {
                if fm.fileExists(atPath: dir.appending(path: "earlier-macos.json").path) {
                    return true
                }
            }
        }
        return false
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
                let compiling = isPrecompileRunning(at: cache)
                let progress = compiling ? readPreparingProgress(at: cache) : nil
                let macOSStale = needsMacOSOptimization(at: cache)
                result.append(ShaderCacheEntry(
                    appID: appID,
                    gameName: appNames[appID],
                    path: cache,
                    sizeBytes: totalBytes,
                    archiveCount: archives,
                    rebuildPending: rebuildPending,
                    isCompiling: compiling,
                    preparingReady: progress?.0,
                    preparingLearned: progress?.1,
                    needsMacOSOptimization: macOSStale
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
