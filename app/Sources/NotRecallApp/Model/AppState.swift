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
    case shaders
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .shaders: return "Shaders"
        case .logs: return "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
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
    @Published var bundledRuntimeURL: URL?
    @Published var bundledRuntimeVersion: String?
    @Published var bundledDXMTBase: String?
    @Published var bundledWinePatchesSHA: String?
    @Published var customRuntimeURL: URL?
    @Published var stagedRuntimeReady = false
    @Published var stagedRuntimeVersion: String?
    @Published var stagedDXMTBase: String?
    @Published var stagedWinePatchesSHA: String?
    @Published var selectedSection: SidebarSection = .overview
    @Published var confirmForceQuit = false
    @Published var confirmResetDisplay = false
    @Published var confirmUninstall = false
    @Published var pendingClearShaderEntry: ShaderCacheEntry?
    @Published var pendingRebuildShaderEntry: ShaderCacheEntry?
    @Published var diagnosticsCopied = false
    @Published var steamToolInstalled = false
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

    let home = FileManager.default.homeDirectoryForCurrentUser

    var notProtonSupport: URL { home.appending(path: "Library/Application Support/notproton") }
    var notRecallSupport: URL { home.appending(path: "Library/Application Support/notrecall") }
    var steamCompatTool: URL { home.appending(path: "Library/Application Support/Steam/compatibilitytools.d/notrecall-proton") }
    var steamConfigVDF: URL { home.appending(path: "Library/Application Support/Steam/config/config.vdf") }
    var overwatchHighlightsDir: URL { home.appending(path: "Movies/Overwatch") }

    var activeRuntimeSource: URL? { customRuntimeURL ?? bundledRuntimeURL }
    var overwatchConfiguredForNotRecall: Bool { overwatchCompatTool == "notrecall-proton" }

    var bundledRuntimeUpdateAvailable: Bool {
        guard stagedRuntimeReady, customRuntimeURL == nil, let bundledVer = bundledRuntimeVersion else { return false }
        if let stagedVer = stagedRuntimeVersion, stagedVer != bundledVer {
            return true
        }
        if let bDxmt = bundledDXMTBase, !bDxmt.isEmpty, let sDxmt = stagedDXMTBase, sDxmt != bDxmt {
            return true
        }
        if let bPatches = bundledWinePatchesSHA, !bPatches.isEmpty, stagedWinePatchesSHA != bPatches {
            return true
        }
        return false
    }

    var hasMissingPrerequisites: Bool {
        !rosettaInstalled || steamAppURL == nil || !notProtonBridgeReady
    }

    var isFullyInstalled: Bool {
        stagedRuntimeReady && steamToolInstalled && helpersInstalled
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
        if let rtVer = stagedRuntimeVersion {
            parts.append(rtVer)
        }
        if let dxmt = stagedDXMTBase, !dxmt.isEmpty {
            parts.append("dxmt \(String(dxmt.prefix(7)))")
        }
        if parts.isEmpty {
            return notRecallSupport.appending(path: "runtime").path
        }
        return parts.joined(separator: " · ")
    }

    var bundledRuntimeLabel: String {
        var parts: [String] = []
        if let ver = bundledRuntimeVersion {
            parts.append(ver)
        }
        if let dxmt = bundledDXMTBase, !dxmt.isEmpty {
            parts.append("dxmt \(String(dxmt.prefix(7)))")
        }
        return parts.isEmpty ? "Bundled Wine + DXMT" : parts.joined(separator: " · ")
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

    private struct RefreshSnapshot: Sendable {
        let steamAppURL: URL?
        let notProtonAppURL: URL?
        let notProtonBridgeReady: Bool
        let bundledRuntimeURL: URL?
        let bundledRuntimeVersion: String?
        let bundledDXMTBase: String?
        let bundledWinePatchesSHA: String?
        let stagedRuntimeReady: Bool
        let stagedRuntimeVersion: String?
        let stagedDXMTBase: String?
        let stagedWinePatchesSHA: String?
        let steamToolInstalled: Bool
        let helpersInstalled: Bool
        let steamLibraryCount: Int
        let rosettaInstalled: Bool
        let healthWarnings: [HealthWarning]
        let overwatchInstalled: Bool
        let overwatchCompatTool: String?
        let shaderCaches: [ShaderCacheEntry]
        let recentLogTitle: String
        let recentLogText: String
    }

    func refresh(preserveLog: Bool = false) async {
        let osOK = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
        )
        macOSSupported = osOK

        let homeDir = home
        let npSupport = notProtonSupport
        let nrSupport = notRecallSupport
        let compatTool = steamCompatTool
        let configVDF = steamConfigVDF

        let snapshot = await Task.detached { () -> RefreshSnapshot in
            let fm = FileManager.default
            let steamApp = Self.detectApp(named: "Steam.app", home: homeDir)
            let notProtonApp = Self.detectApp(named: "NotProton.app", home: homeDir)
            let bridgeReady = fm.fileExists(atPath: npSupport.appending(path: "bridge").path)
            let bundled = NotRecallInstaller.locateBundledRuntime()
            let runtimeReady = fm.isExecutableFile(atPath: nrSupport.appending(path: "runtime/bin/wine").path)
            let (runtimeVer, dxmtBase, winePatchesSHA) = Self.readRuntimeInfo(in: nrSupport.appending(path: "runtime"))
            let toolInstalled = fm.isExecutableFile(atPath: compatTool.appending(path: "run").path)
            let helpersReady = fm.isExecutableFile(atPath: nrSupport.appending(path: "helpers/ow2-pipeline").path)

            let libraries = Self.discoverSteamLibraries(home: homeDir)
            let rosetta = Self.probeRosetta()
            let warnings = Self.collectHealthWarnings(macOSSupported: osOK, libraries: libraries)
            let names = Self.loadSteamAppNames(across: libraries)
            let owInstalled = names["2357570"] != nil
            let owTool = SteamVDF.readCompatTool(forAppID: "2357570", in: configVDF)
            let caches = Self.scanShaderCaches(across: libraries, appNames: names)
            let (logTitle, logText) = Self.loadLatestLog(across: libraries, appNames: names)
            return RefreshSnapshot(
                steamAppURL: steamApp,
                notProtonAppURL: notProtonApp,
                notProtonBridgeReady: bridgeReady,
                bundledRuntimeURL: bundled?.archiveURL,
                bundledRuntimeVersion: bundled?.version,
                bundledDXMTBase: bundled?.dxmtBase,
                bundledWinePatchesSHA: bundled?.winePatchesSHA256,
                stagedRuntimeReady: runtimeReady,
                stagedRuntimeVersion: runtimeVer,
                stagedDXMTBase: dxmtBase,
                stagedWinePatchesSHA: winePatchesSHA,
                steamToolInstalled: toolInstalled,
                helpersInstalled: helpersReady,
                steamLibraryCount: libraries.count,
                rosettaInstalled: rosetta,
                healthWarnings: warnings,
                overwatchInstalled: owInstalled,
                overwatchCompatTool: owTool,
                shaderCaches: caches,
                recentLogTitle: logTitle,
                recentLogText: logText
            )
        }.value

        steamAppURL = snapshot.steamAppURL
        notProtonAppURL = snapshot.notProtonAppURL
        notProtonBridgeReady = snapshot.notProtonBridgeReady
        bundledRuntimeURL = snapshot.bundledRuntimeURL
        bundledRuntimeVersion = snapshot.bundledRuntimeVersion
        bundledDXMTBase = snapshot.bundledDXMTBase
        bundledWinePatchesSHA = snapshot.bundledWinePatchesSHA
        stagedRuntimeReady = snapshot.stagedRuntimeReady
        stagedRuntimeVersion = snapshot.stagedRuntimeVersion
        stagedDXMTBase = snapshot.stagedDXMTBase
        stagedWinePatchesSHA = snapshot.stagedWinePatchesSHA
        steamToolInstalled = snapshot.steamToolInstalled
        helpersInstalled = snapshot.helpersInstalled
        steamLibraryCount = snapshot.steamLibraryCount
        rosettaInstalled = snapshot.rosettaInstalled
        healthWarnings = snapshot.healthWarnings
        overwatchInstalled = snapshot.overwatchInstalled
        overwatchCompatTool = snapshot.overwatchCompatTool
        shaderCaches = snapshot.shaderCaches
        if !preserveLog {
            recentLogTitle = snapshot.recentLogTitle
            recentLogText = snapshot.recentLogText
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
        let command = "softwareupdate --install-rosetta --agree-to-license"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let proc = Process()
        proc.executableURL = URL(filePath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal"]
        do {
            try proc.run()
            statusMessage = "Copied '\(command)' to clipboard and opened Terminal."
        } catch {
            statusMessage = "Copied '\(command)' to clipboard. Open Terminal and paste it to install Rosetta."
        }
    }

    func selectLocalRuntime() {
        let panel = NSOpenPanel()
        panel.title = "Select Custom Runtime"
        panel.message = "Choose a runtime.tar.gz archive or an unpacked runtime folder containing bin/wine."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.gzip, .folder]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fm = FileManager.default
        let lower = url.lastPathComponent.lowercased()
        let isArchive = lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
        let isUnpacked = fm.isExecutableFile(atPath: url.appending(path: "bin/wine").path)
        if isArchive || isUnpacked {
            customRuntimeURL = url
            statusMessage = "Selected custom runtime: \(url.lastPathComponent)"
        } else {
            statusMessage = "Selected item is not a .tar.gz runtime archive or runtime folder containing bin/wine."
        }
    }

    func clearCustomRuntime() {
        customRuntimeURL = nil
        statusMessage = "Reverted to bundled runtime."
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
        do {
            try fm.createDirectory(at: overwatchHighlightsDir, withIntermediateDirectories: true)
            if NSWorkspace.shared.open(overwatchHighlightsDir) {
                statusMessage = "Opened ~/Movies/Overwatch."
            } else {
                statusMessage = "Could not open ~/Movies/Overwatch in Finder."
            }
        } catch {
            statusMessage = "Could not create ~/Movies/Overwatch: \(error.localizedDescription)"
        }
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
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let homeDir = home
        let message = await Task.detached { () -> String in
            let libraries = Self.discoverSteamLibraries(home: homeDir)
            let (defW, defH, defHz) = Self.mainDisplayDefault()
            let fm = FileManager.default
            let existingPfx = libraries.map { $0.appending(path: "compatdata/2357570") }
                .first { fm.fileExists(atPath: $0.appending(path: "pfx").path) }
            let owLibrary = libraries.first { fm.fileExists(atPath: $0.appending(path: "appmanifest_2357570.acf").path) }
            guard let compatDir = existingPfx ?? (owLibrary ?? libraries.first)?.appending(path: "compatdata/2357570") else {
                return "No Steam library found for Overwatch."
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
                return "Reset Overwatch display settings to \(defW) × \(defH) fullscreen. Your graphics quality and FPS settings were kept."
            } catch {
                return "Could not reset display settings: \(error.localizedDescription)"
            }
        }.value
        statusMessage = message
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
                if guiGone {
                    let helperRunning = await Task.detached { Self.isSteamHelperRunning() }.value
                    if !helperRunning {
                        exited = true
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !exited {
                statusMessage = "Steam did not exit in time — quit Steam manually, then click Configure in Steam again."
                return
            }
        }

        let configVDF = steamConfigVDF
        do {
            try await Task.detached {
                try SteamVDF.setCompatTool(forAppID: "2357570", toolName: "notrecall-proton", in: configVDF)
            }.value
            try await NSWorkspace.shared.openApplication(at: steam, configuration: NSWorkspace.OpenConfiguration())
            statusMessage = "Configured Overwatch (AppID 2357570) to use NotRecall in Steam and relaunched Steam."
        } catch {
            statusMessage = "Failed to update Steam config.vdf: \(error.localizedDescription)"
        }
        await refresh()
    }

    func installNotRecall(
        runtimeSource: URL? = nil,
        runtimeOnly: Bool = false,
        dryRun: Bool = false,
        switchToLogs: Bool = false
    ) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let options = NotRecallInstallOptions(
            runtimeSource: runtimeSource,
            runtimeOnly: runtimeOnly,
            dryRun: dryRun
        )
        let title: String
        if dryRun {
            title = "Dry Run Install"
        } else if runtimeOnly {
            title = "Update Runtime Only"
        } else {
            title = "Install / Update NotRecall"
        }
        await runInstallInner(options: options, logTitle: title, switchToLogs: switchToLogs)
    }

    func uninstallNotRecall() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let result = await Task.detached { () -> NotRecallOperationResult in
            NotRecallInstaller.uninstall()
        }.value
        statusMessage = result.summary
        recentLogTitle = "Uninstall NotRecall"
        recentLogText = result.log
        if !result.succeeded {
            selectedSection = .logs
        }
        await refresh(preserveLog: true)
    }

    private func runInstallInner(
        options: NotRecallInstallOptions,
        logTitle: String,
        switchToLogs: Bool
    ) async {
        let result = await Task.detached { () -> NotRecallOperationResult in
            NotRecallInstaller.install(options: options)
        }.value
        statusMessage = result.summary
        recentLogTitle = logTitle
        recentLogText = result.log
        if switchToLogs || !result.succeeded {
            selectedSection = .logs
        }
        await refresh(preserveLog: true)
    }

    func clearShaderCache(_ entry: ShaderCacheEntry) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let message = await Task.detached { () -> String in
            let fm = FileManager.default
            do {
                try fm.removeItem(at: entry.path)
                for metalCache in Self.gameAppMetalCacheURLs(forAppID: entry.appID) where fm.fileExists(atPath: metalCache.path) {
                    try? fm.removeItem(at: metalCache)
                }
                return "Cleared shader cache for \(entry.displayTitle)."
            } catch {
                return "Failed to clear cache: \(error.localizedDescription)"
            }
        }.value
        statusMessage = message
        await refresh()
    }

    func requestRebuildShaders(_ entry: ShaderCacheEntry) async {
        let markerDir = entry.path.appending(path: "cache")
        let marker = markerDir.appending(path: "rebuild-shaders")
        let message = await Task.detached { () -> String in
            do {
                try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
                try Data("1\n".utf8).write(to: marker, options: .atomic)
                return "Queued shader rebuild for \(entry.displayTitle) on next launch."
            } catch {
                return "Failed to queue shader rebuild: \(error.localizedDescription)"
            }
        }.value
        statusMessage = message
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
        let unixWine = notRecallSupport.appending(path: "runtime/lib/wine/x86_64-unix/wine")
        let gameApp: URL
        if entry.appID == "2357570", FileManager.default.isExecutableFile(atPath: recallOWApp.appending(path: "Contents/MacOS/wine").path) {
            gameApp = recallOWApp
        } else if FileManager.default.fileExists(atPath: wrapperApp.path) {
            gameApp = wrapperApp
        } else {
            gameApp = unixWine
        }
        let logFile = entry.path.deletingLastPathComponent().appending(path: "notrecall-run.log")
        let gameAppArg = FileManager.default.fileExists(atPath: gameApp.path) ? gameApp.path : ""
        let args: [String] = [
            hook.path, "post", entry.path.path,
            gameAppArg,
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
        Bundled Runtime:    \(bundledRuntimeLabel) (\(bundledRuntimeURL?.path ?? "missing"))
        Runtime Source:     \(activeRuntimeSource?.path ?? "none")
        Staged Runtime:     \(stagedRuntimeReady ? stagedRuntimeSummary : "missing")
        Overwatch (2357570): \(overwatchInstalled ? "installed" : "not found") (compat tool: \(overwatchCompatTool ?? "unset"))
        Steam Compat Tool:  \(steamToolInstalled ? "installed" : "missing")
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
                    detail: "Try Rebuild Shaders in Shaders, or lower Shader Memory in Steam’s Compatibility tab.",
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

    nonisolated private static func readRuntimeInfo(in runtimeDir: URL) -> (String?, String?, String?) {
        let manifest = runtimeDir.appending(path: "runtime.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        return (
            json["version"] as? String,
            json["dxmtBase"] as? String,
            json["winePatchesSHA256"] as? String
        )
    }

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
            root.appending(path: "io.shreyash.notrecall.game.\(appID)/com.apple.metal")
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
            return args.contains("ow2-pipeline")
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
