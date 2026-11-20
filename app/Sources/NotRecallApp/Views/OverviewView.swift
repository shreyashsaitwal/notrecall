import SwiftUI

struct OverviewView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OverwatchHeroCard(
                    hasMissingPrerequisites: state.hasMissingPrerequisites,
                    isFullyInstalled: state.isFullyInstalled,
                    overwatchInstalled: state.overwatchInstalled,
                    overwatchConfigured: state.overwatchConfiguredForNotRecall,
                    hasLocalRuntime: state.activeRuntimeSource != nil,
                    hasSteamApp: state.steamAppURL != nil,
                    installedRecallVersion: state.installedRecallVersion,
                    isBusy: state.isBusy,
                    downloadProgress: state.downloadProgress,
                    downloadStatusText: state.downloadStatusText,
                    onPlayOverwatch: { state.playOverwatch() },
                    onConfigureOverwatch: { Task { await state.configureOverwatchInSteam() } },
                    onInstall: {
                        if let rt = state.activeRuntimeSource {
                            Task { await state.runProjectScript("scripts/install.sh", extraArgs: ["--runtime", rt.path]) }
                        } else {
                            state.downloadAndInstallRecall(state.preferredDownloadRelease, runtimeOnly: false)
                        }
                    },
                    onOpenSetup: { state.selectedSection = .setup },
                    onOpenHighlights: { state.openOverwatchHighlights() },
                    onCancelDownload: { state.cancelDownload() }
                )

                MetricsBentoRow(
                    warningCount: state.healthWarnings.count,
                    hasCriticalWarning: state.healthWarnings.contains(where: \.isCritical),
                    installedRecallVersion: state.installedRecallVersion,
                    availableUpdateVersion: state.availableRecallUpdate?.version,
                    stagedRuntimeReady: state.stagedRuntimeReady,
                    shaderSizeFormatted: state.totalShaderCacheFormatted,
                    shaderPackCount: state.totalShaderPackCount,
                    anyShaderCompiling: state.anyShaderCompiling,
                    anyShaderNeedsMacOSOptimization: state.anyShaderNeedsMacOSOptimization,
                    onOpenSetup: { state.selectedSection = .setup },
                    onOpenShaders: { state.selectedSection = .shaders },
                    onOpenWhatsNew: { state.showWhatsNewSheet = true }
                )

                if let update = state.availableRecallUpdate {
                    InlineBanner(
                        symbol: "sparkles",
                        title: "Recall \(update.version) is available",
                        message: state.installedRecallVersion.map {
                            "You have Recall \($0). Your games, saves, and settings stay untouched."
                        } ?? "A newer Recall runtime is ready on GitHub.",
                        tint: NotRecallTheme.brand
                    ) {
                        HStack(spacing: 6) {
                            Button("What’s New") { state.showWhatsNewSheet = true }
                                .buttonStyle(SubtleButtonStyle(compact: true))
                            Button("Update") {
                                state.downloadAndInstallRecall(update, runtimeOnly: state.stagedRuntimeReady)
                            }
                            .buttonStyle(BrandButtonStyle(compact: true))
                            .disabled(state.isBusy)
                        }
                    }
                }

                if state.hasMissingPrerequisites {
                    OverviewPrerequisitesBanner(
                        rosettaInstalled: state.rosettaInstalled,
                        steamInstalled: state.steamAppURL != nil,
                        notProtonReady: state.notProtonBridgeReady,
                        onInstallRosetta: { state.installRosetta() },
                        onOpenNotProton: { state.openNotProton() }
                    )
                }

                if !state.healthWarnings.isEmpty {
                    OverviewHealthWarnings(
                        warnings: state.healthWarnings,
                        onOpenBatterySettings: { state.openBatterySettings() },
                        onOpenShaders: { state.selectedSection = .shaders }
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    PlayerControlsCard(
                        hasSteamApp: state.steamAppURL != nil,
                        isBusy: state.isBusy,
                        onShowSteam: { state.revealSteamInFinder() },
                        onOpenInputMonitoring: { state.openInputMonitoringSettings() },
                        onResetDisplay: { state.confirmResetDisplay = true },
                        onRestartSteam: { Task { await state.restartSteam() } },
                        onForceQuit: { state.confirmForceQuit = true }
                    )

                    EnvironmentSnapshotCard(
                        rosettaInstalled: state.rosettaInstalled,
                        steamInstalled: state.steamAppURL != nil,
                        notProtonReady: state.notProtonBridgeReady,
                        stagedRuntimeReady: state.stagedRuntimeReady,
                        runtimeSummary: state.stagedRuntimeSummary,
                        steamToolAndPluginReady: state.steamToolInstalled && state.pluginInstalled,
                        overwatchShaderEntry: state.overwatchShaderEntry,
                        helpersInstalled: state.helpersInstalled,
                        onManageSetup: { state.selectedSection = .setup },
                        onOpenShaders: { state.selectedSection = .shaders },
                        onOptimizeShader: { entry in Task { await state.optimizeShadersNow(entry) } },
                        onRebuildShader: { entry in state.pendingRebuildShaderEntry = entry }
                    )
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Overwatch Hero Action Card

struct OverwatchHeroCard: View {
    let hasMissingPrerequisites: Bool
    let isFullyInstalled: Bool
    let overwatchInstalled: Bool
    let overwatchConfigured: Bool
    let hasLocalRuntime: Bool
    let hasSteamApp: Bool
    let installedRecallVersion: String?
    let isBusy: Bool
    let downloadProgress: Double?
    let downloadStatusText: String
    let onPlayOverwatch: () -> Void
    let onConfigureOverwatch: () -> Void
    let onInstall: () -> Void
    let onOpenSetup: () -> Void
    let onOpenHighlights: () -> Void
    let onCancelDownload: () -> Void

    private var statusTagText: String {
        if hasMissingPrerequisites { return "Prerequisites Needed" }
        if !isFullyInstalled { return "Not Installed" }
        if overwatchInstalled && overwatchConfigured { return "Ready to Play" }
        if overwatchInstalled { return "Needs Steam Setup" }
        return "Waiting for Overwatch"
    }

    private var statusTagColor: Color {
        if hasMissingPrerequisites || !isFullyInstalled { return NotRecallTheme.warning }
        if overwatchInstalled && overwatchConfigured { return NotRecallTheme.healthy }
        return NotRecallTheme.brand
    }

    private var subtitleText: String {
        if hasMissingPrerequisites {
            return "Install the required prerequisites below before setting up NotRecall."
        }
        if !isFullyInstalled {
            return "Stages Recall’s Mac runtime, Steam compatibility tool, and background shader optimizer."
        }
        if overwatchInstalled && overwatchConfigured {
            let ver = installedRecallVersion.map { "Recall \($0)" } ?? "Recall runtime"
            return "Configured in Steam with \(ver), MetalFX upscaling, and Game Mode."
        }
        if overwatchInstalled {
            return "Overwatch is installed in Steam. Click Set Up in Steam to configure it automatically."
        }
        return "Install Overwatch in Steam, then return here to configure it with one click."
    }

    var body: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    NotRecallEmblem(size: 46)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Overwatch on Steam")
                                .font(NotRecallTheme.font(18, .bold))
                                .tracking(-0.3)
                            StatusTag(text: statusTagText, color: statusTagColor)
                        }
                        Text(subtitleText)
                            .font(NotRecallTheme.font(12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        if hasMissingPrerequisites {
                            Button("Finish Setup", action: onOpenSetup)
                                .buttonStyle(BrandButtonStyle())
                                .disabled(isBusy)
                        } else if !isFullyInstalled {
                            Button(hasLocalRuntime ? "Install NotRecall" : "Download & Install", action: onInstall)
                                .buttonStyle(BrandButtonStyle())
                                .keyboardShortcut(.defaultAction)
                                .disabled(isBusy)
                        } else if overwatchInstalled && !overwatchConfigured {
                            Button(action: onConfigureOverwatch) {
                                Label("Set Up in Steam", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(BrandButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .disabled(isBusy || !hasSteamApp)
                        } else if overwatchInstalled {
                            Button(action: onPlayOverwatch) {
                                Label("Play Overwatch", systemImage: "play.fill")
                            }
                            .buttonStyle(BrandButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .disabled(isBusy || !hasSteamApp)
                        }

                        Button(action: onOpenHighlights) {
                            Label("Highlights", systemImage: "film.stack")
                        }
                        .buttonStyle(SubtleButtonStyle())
                        .help("Open ~/Movies/Overwatch in Finder")
                    }
                }

                if let progress = downloadProgress {
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 10) {
                            Text(downloadStatusText)
                                .font(NotRecallTheme.font(12, .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .contentTransition(.numericText())
                            Spacer()
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(NotRecallTheme.font(12, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                            Button("Cancel", action: onCancelDownload)
                                .buttonStyle(SubtleButtonStyle(compact: true))
                        }
                        SmoothProgressBar(fraction: progress)
                    }
                }
            }
        }
    }
}

// MARK: - Live Bento Metrics Strip

struct MetricsBentoRow: View {
    let warningCount: Int
    let hasCriticalWarning: Bool
    let installedRecallVersion: String?
    let availableUpdateVersion: String?
    let stagedRuntimeReady: Bool
    let shaderSizeFormatted: String
    let shaderPackCount: Int
    let anyShaderCompiling: Bool
    let anyShaderNeedsMacOSOptimization: Bool
    let onOpenSetup: () -> Void
    let onOpenShaders: () -> Void
    let onOpenWhatsNew: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            MetricTile(
                label: "System Health",
                value: warningCount == 0 ? "All Clear" : "\(warningCount) \(warningCount == 1 ? "Warning" : "Warnings")",
                caption: warningCount == 0 ? "macOS, thermals & memory look good" : "Check alerts below before playing",
                symbol: warningCount == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                tint: warningCount == 0 ? NotRecallTheme.healthy : (hasCriticalWarning ? NotRecallTheme.critical : NotRecallTheme.warning),
                action: nil
            )

            MetricTile(
                label: "Recall Runtime",
                value: installedRecallVersion.map { "v\($0)" } ?? (stagedRuntimeReady ? "Staged" : "Not Installed"),
                caption: availableUpdateVersion.map { "Update v\($0) ready" } ?? (stagedRuntimeReady ? "Up to date" : "Download or choose local copy"),
                symbol: availableUpdateVersion != nil ? "arrow.down.circle.fill" : "shippingbox.fill",
                tint: availableUpdateVersion != nil ? NotRecallTheme.brand : (stagedRuntimeReady ? NotRecallTheme.healthy : NotRecallTheme.warning),
                action: availableUpdateVersion != nil ? onOpenWhatsNew : onOpenSetup
            )

            MetricTile(
                label: "Shader Cache",
                value: shaderPackCount > 0 ? shaderSizeFormatted : "Empty",
                caption: anyShaderCompiling
                    ? "Optimizing in background…"
                    : (anyShaderNeedsMacOSOptimization
                        ? "Needs optimization for this macOS"
                        : (shaderPackCount > 0 ? "\(shaderPackCount) shader \(shaderPackCount == 1 ? "pack" : "packs") saved" : "Builds automatically as you play")),
                symbol: "cpu",
                tint: anyShaderCompiling ? NotRecallTheme.brand : (anyShaderNeedsMacOSOptimization ? NotRecallTheme.warning : .secondary),
                action: onOpenShaders
            )
        }
    }
}

struct MetricTile: View {
    let label: String
    let value: String
    let caption: String
    let symbol: String
    let tint: Color
    let action: (() -> Void)?

    var body: some View {
        let tile = SurfaceCard(padding: 13) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(label)
                        .font(NotRecallTheme.font(11.5, .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if action != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(value)
                    .font(NotRecallTheme.font(17, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text(caption)
                    .font(NotRecallTheme.font(11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }

        if let action {
            Button(action: action) { tile }
                .buttonStyle(.plain)
        } else {
            tile
        }
    }
}

// MARK: - Overview Alerts

struct OverviewPrerequisitesBanner: View {
    let rosettaInstalled: Bool
    let steamInstalled: Bool
    let notProtonReady: Bool
    let onInstallRosetta: () -> Void
    let onOpenNotProton: () -> Void

    var body: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(NotRecallTheme.warning)
                    Text("Complete Prerequisites")
                        .font(NotRecallTheme.font(13, .semibold))
                }
                if !rosettaInstalled {
                    ControlRow(
                        title: "Rosetta 2",
                        detail: "Required to run Windows games on Apple Silicon.",
                        buttonTitle: "Install Rosetta",
                        action: onInstallRosetta
                    )
                }
                if !steamInstalled {
                    StackStatusRow(
                        title: "Steam",
                        detail: "Install Steam in /Applications first.",
                        ok: false
                    )
                }
                if !notProtonReady {
                    ControlRow(
                        title: "NotProton Bridge",
                        detail: "Open NotProton and click Install so Steam can launch Windows games.",
                        buttonTitle: "Open NotProton",
                        action: onOpenNotProton
                    )
                }
            }
        }
    }
}

struct OverviewHealthWarnings: View {
    let warnings: [HealthWarning]
    let onOpenBatterySettings: () -> Void
    let onOpenShaders: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(warnings) { warning in
                InlineBanner(
                    symbol: warning.isCritical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                    title: warning.title,
                    message: warning.detail,
                    tint: warning.isCritical ? NotRecallTheme.critical : NotRecallTheme.warning
                ) {
                    if warning.id == "low_power_mode" {
                        Button("Battery Settings", action: onOpenBatterySettings)
                            .buttonStyle(SubtleButtonStyle(compact: true))
                    } else if warning.id == "recent_gpu_hang" {
                        Button("Open Shaders", action: onOpenShaders)
                            .buttonStyle(SubtleButtonStyle(compact: true))
                    }
                }
            }
        }
    }
}

// MARK: - Two-Column Bottom Cards (Always Visible on Main Screen)

struct PlayerControlsCard: View {
    let hasSteamApp: Bool
    let isBusy: Bool
    let onShowSteam: () -> Void
    let onOpenInputMonitoring: () -> Void
    let onResetDisplay: () -> Void
    let onRestartSteam: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    title: "Quick Controls & Recovery",
                    subtitle: "Everyday controls for aim, display fixes, and frozen games.",
                    symbol: "slider.horizontal.3"
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("High-Precision Mouse")
                        .font(NotRecallTheme.font(13, .medium))
                    Text("Add Steam in System Settings › Input Monitoring to skip macOS’s mouse layer for raw aim.")
                        .font(NotRecallTheme.font(11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Show Steam", action: onShowSteam)
                            .buttonStyle(SubtleButtonStyle(compact: true))
                            .disabled(!hasSteamApp)
                        Button("Input Monitoring…", action: onOpenInputMonitoring)
                            .buttonStyle(SubtleButtonStyle(compact: true))
                    }
                    .padding(.top, 2)
                }

                Divider()

                ControlRow(
                    title: "Reset Display Settings",
                    detail: "Fixes black screen or wrong resolution without resetting quality/FPS.",
                    buttonTitle: "Reset…",
                    disabled: isBusy,
                    action: onResetDisplay
                )

                Divider()

                ControlRow(
                    title: "Restart Steam",
                    detail: "Cleanly restarts Steam to pick up compatibility tool changes.",
                    buttonTitle: "Restart",
                    disabled: isBusy || !hasSteamApp,
                    action: onRestartSteam
                )

                Divider()

                ControlRow(
                    title: "Force Quit Overwatch",
                    detail: "Immediately stops a frozen game and its Wine server.",
                    buttonTitle: "Force Quit…",
                    destructive: true,
                    disabled: isBusy,
                    action: onForceQuit
                )
            }
        }
    }
}

struct EnvironmentSnapshotCard: View {
    let rosettaInstalled: Bool
    let steamInstalled: Bool
    let notProtonReady: Bool
    let stagedRuntimeReady: Bool
    let runtimeSummary: String
    let steamToolAndPluginReady: Bool
    let overwatchShaderEntry: ShaderCacheEntry?
    let helpersInstalled: Bool
    let onManageSetup: () -> Void
    let onOpenShaders: () -> Void
    let onOptimizeShader: (ShaderCacheEntry) -> Void
    let onRebuildShader: (ShaderCacheEntry) -> Void

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    CardHeader(
                        title: "Stack & Shaders",
                        subtitle: "Live status of your macOS compatibility stack.",
                        symbol: "checkmark.seal"
                    )
                    Spacer(minLength: 8)
                    Button("Manage", action: onManageSetup)
                        .buttonStyle(.borderless)
                        .font(NotRecallTheme.font(12, .medium))
                        .foregroundStyle(NotRecallTheme.brand)
                }

                VStack(alignment: .leading, spacing: 8) {
                    StackStatusRow(title: "Rosetta 2", detail: rosettaInstalled ? "Verified (x86_64)" : "Missing", ok: rosettaInstalled)
                    StackStatusRow(title: "Steam & NotProton", detail: (steamInstalled && notProtonReady) ? "Bridge ready" : "Incomplete", ok: steamInstalled && notProtonReady)
                    StackStatusRow(title: "Recall Runtime", detail: stagedRuntimeReady ? runtimeSummary : "Not staged yet", ok: stagedRuntimeReady)
                    StackStatusRow(title: "Steam Tool & Settings", detail: steamToolAndPluginReady ? "Installed in Steam" : "Not installed yet", ok: steamToolAndPluginReady)
                    StackStatusRow(title: "Shader Optimizer", detail: helpersInstalled ? "Ready in background" : "Not installed yet", ok: helpersInstalled)
                }

                Divider()

                if let entry = overwatchShaderEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(entry.displayTitle) Shaders")
                                .font(NotRecallTheme.font(13, .semibold))
                            Spacer()
                            Text("\(entry.formattedSize) · \(entry.archiveCount) \(entry.archiveCount == 1 ? "pack" : "packs")")
                                .font(NotRecallTheme.font(11.5))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        if entry.isCompiling {
                            if let ready = entry.preparingReady, let learned = entry.preparingLearned, learned > 0 {
                                SmoothProgressBar(fraction: Double(min(ready, learned)) / Double(learned))
                                Text("Optimizing \(ready.formatted()) of \(learned.formatted()) shaders…")
                                    .font(NotRecallTheme.font(11.5))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            } else {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Optimizing shaders in the background…")
                                        .font(NotRecallTheme.font(11.5))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 6) {
                            Button("Optimize Now") { onOptimizeShader(entry) }
                                .buttonStyle(BrandButtonStyle(compact: true))
                                .disabled(entry.isCompiling || !helpersInstalled)
                            Button("Rebuild") { onRebuildShader(entry) }
                                .buttonStyle(SubtleButtonStyle(compact: true))
                                .disabled(entry.rebuildPending || entry.isCompiling)
                            Spacer(minLength: 0)
                            Button("All Shaders", action: onOpenShaders)
                                .buttonStyle(.borderless)
                                .font(NotRecallTheme.font(12, .medium))
                                .foregroundStyle(NotRecallTheme.brand)
                        }
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Game Shaders")
                                .font(NotRecallTheme.font(13, .medium))
                            Text("Builds automatically after your first match.")
                                .font(NotRecallTheme.font(11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Shaders", action: onOpenShaders)
                            .buttonStyle(SubtleButtonStyle(compact: true))
                    }
                }
            }
        }
    }
}
