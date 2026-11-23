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
                    hasRuntimeSource: state.activeRuntimeSource != nil,
                    hasSteamApp: state.steamAppURL != nil,
                    stagedRuntimeSummary: state.stagedRuntimeSummary,
                    isBusy: state.isBusy,
                    onPlayOverwatch: { state.playOverwatch() },
                    onConfigureOverwatch: { Task { await state.configureOverwatchInSteam() } },
                    onInstall: {
                        Task { await state.installNotRecall(runtimeSource: state.customRuntimeURL) }
                    },
                    onOpenHighlights: { state.openOverwatchHighlights() }
                )

                MetricsBentoRow(
                    warningCount: state.healthWarnings.count,
                    hasCriticalWarning: state.healthWarnings.contains(where: \.isCritical),
                    stagedRuntimeReady: state.stagedRuntimeReady,
                    stagedRuntimeVersion: state.stagedRuntimeVersion,
                    bundledRuntimeVersion: state.bundledRuntimeVersion,
                    bundledRuntimeUpdateAvailable: state.bundledRuntimeUpdateAvailable,
                    shaderSizeFormatted: state.totalShaderCacheFormatted,
                    shaderPackCount: state.totalShaderPackCount,
                    anyShaderCompiling: state.anyShaderCompiling,
                    anyShaderNeedsMacOSOptimization: state.anyShaderNeedsMacOSOptimization,
                    onOpenShaders: { state.selectedSection = .shaders },
                    onUpdateBundledRuntime: {
                        Task { await state.installNotRecall(runtimeSource: nil, runtimeOnly: true) }
                    }
                )

                if state.bundledRuntimeUpdateAvailable {
                    InlineBanner(
                        symbol: "sparkles",
                        title: "Updated bundled runtime ready (\(state.bundledRuntimeLabel))",
                        message: "This build of NotRecall includes a newer Wine + DXMT runtime than what’s currently staged. Your games, saves, and settings stay untouched.",
                        tint: NotRecallTheme.brand
                    ) {
                        Button("Update Runtime") {
                            Task { await state.installNotRecall(runtimeSource: nil, runtimeOnly: true) }
                        }
                        .buttonStyle(BrandButtonStyle(compact: true))
                        .disabled(state.isBusy)
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

                RuntimeManagementCard(
                    activeRuntimeSource: state.activeRuntimeSource,
                    hasCustomRuntime: state.customRuntimeURL != nil,
                    bundledRuntimeLabel: state.bundledRuntimeLabel,
                    stagedRuntimeReady: state.stagedRuntimeReady,
                    isBusy: state.isBusy,
                    onChooseLocal: { state.selectLocalRuntime() },
                    onResetLocal: { state.clearCustomRuntime() },
                    onInstallOrUpdate: {
                        Task { await state.installNotRecall(runtimeSource: state.customRuntimeURL) }
                    },
                    onUpdateRuntimeOnly: {
                        Task { await state.installNotRecall(runtimeSource: state.customRuntimeURL, runtimeOnly: true) }
                    },
                    onDryRun: {
                        Task {
                            await state.installNotRecall(
                                runtimeSource: state.customRuntimeURL,
                                dryRun: true,
                                switchToLogs: true
                            )
                        }
                    },
                    onUninstall: { state.confirmUninstall = true }
                )

                HStack(alignment: .top, spacing: 14) {
                    RecoveryControlsCard(
                        hasSteamApp: state.steamAppURL != nil,
                        isBusy: state.isBusy,
                        onShowSteam: { state.revealSteamInFinder() },
                        onOpenInputMonitoring: { state.openInputMonitoringSettings() },
                        onImportFromRecall: { state.openImportFromRecall() },
                        onResetDisplay: { state.confirmResetDisplay = true },
                        onRestartSteam: { Task { await state.restartSteam() } },
                        onForceQuit: { state.confirmForceQuit = true }
                    )

                    EnvironmentSnapshotCard(
                        rosettaInstalled: state.rosettaInstalled,
                        steamInstalled: state.steamAppURL != nil,
                        steamPath: state.steamAppURL?.path,
                        notProtonReady: state.notProtonBridgeReady,
                        notProtonSupportPath: state.notProtonSupport.path,
                        stagedRuntimeReady: state.stagedRuntimeReady,
                        runtimeSummary: state.stagedRuntimeSummary,
                        steamToolReady: state.steamToolInstalled,
                        steamToolPath: state.steamCompatTool.path,
                        overwatchShaderEntry: state.overwatchShaderEntry,
                        helpersInstalled: state.helpersInstalled,
                        onInstallRosetta: { state.installRosetta() },
                        onOpenNotProton: { state.openNotProton() },
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
    let hasRuntimeSource: Bool
    let hasSteamApp: Bool
    let stagedRuntimeSummary: String
    let isBusy: Bool
    let onPlayOverwatch: () -> Void
    let onConfigureOverwatch: () -> Void
    let onInstall: () -> Void
    let onOpenHighlights: () -> Void

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
            return "Installs the bundled Wine + DXMT runtime, Steam compatibility tool, and shader optimizer offline."
        }
        if overwatchInstalled && overwatchConfigured {
            return "Configured in Steam (\(stagedRuntimeSummary)). Customize per-game options in Steam’s Compatibility tab."
        }
        if overwatchInstalled {
            return "Overwatch is installed in Steam. Click Set Up in Steam to configure it automatically."
        }
        return "Install Overwatch in Steam, then return here to configure it with one click."
    }

    var body: some View {
        SurfaceCard(padding: 18) {
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
                    if !hasMissingPrerequisites {
                        if !isFullyInstalled {
                            Button("Install NotRecall", action: onInstall)
                                .buttonStyle(BrandButtonStyle())
                                .keyboardShortcut(.defaultAction)
                                .disabled(isBusy || !hasRuntimeSource)
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
                    }

                    Button(action: onOpenHighlights) {
                        Label("Highlights", systemImage: "film.stack")
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .help("Open ~/Movies/Overwatch in Finder")
                }
            }
        }
    }
}

// MARK: - Live Bento Metrics Strip

struct MetricsBentoRow: View {
    let warningCount: Int
    let hasCriticalWarning: Bool
    let stagedRuntimeReady: Bool
    let stagedRuntimeVersion: String?
    let bundledRuntimeVersion: String?
    let bundledRuntimeUpdateAvailable: Bool
    let shaderSizeFormatted: String
    let shaderPackCount: Int
    let anyShaderCompiling: Bool
    let anyShaderNeedsMacOSOptimization: Bool
    let onOpenShaders: () -> Void
    let onUpdateBundledRuntime: () -> Void

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
                label: "Bundled Runtime",
                value: stagedRuntimeVersion ?? (stagedRuntimeReady ? "Staged" : "Not Installed"),
                caption: bundledRuntimeUpdateAvailable
                    ? ((bundledRuntimeVersion != nil && bundledRuntimeVersion != stagedRuntimeVersion)
                        ? "New bundled build ready (\(bundledRuntimeVersion!))"
                        : "Updated Wine + DXMT build ready")
                    : (stagedRuntimeReady ? "Matches bundled Wine + DXMT" : "Ready to install offline"),
                symbol: bundledRuntimeUpdateAvailable ? "arrow.triangle.2.circlepath.circle.fill" : "shippingbox.fill",
                tint: bundledRuntimeUpdateAvailable ? NotRecallTheme.brand : (stagedRuntimeReady ? NotRecallTheme.healthy : NotRecallTheme.warning),
                action: bundledRuntimeUpdateAvailable ? onUpdateBundledRuntime : nil
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

// MARK: - Runtime Source & Installation Management

struct RuntimeManagementCard: View {
    let activeRuntimeSource: URL?
    let hasCustomRuntime: Bool
    let bundledRuntimeLabel: String
    let stagedRuntimeReady: Bool
    let isBusy: Bool
    let onChooseLocal: () -> Void
    let onResetLocal: () -> Void
    let onInstallOrUpdate: () -> Void
    let onUpdateRuntimeOnly: () -> Void
    let onDryRun: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    title: "Runtime & Installation",
                    subtitle: "Uses the Wine + DXMT runtime bundled inside NotRecall.app, or an optional custom local archive.",
                    symbol: "shippingbox"
                )

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: activeRuntimeSource != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(activeRuntimeSource != nil ? NotRecallTheme.healthy : NotRecallTheme.warning)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasCustomRuntime ? "Custom Runtime Override" : "Bundled Runtime (\(bundledRuntimeLabel))")
                            .font(NotRecallTheme.font(13, .semibold))
                        Text(activeRuntimeSource?.path ?? "Bundled runtime.tar.gz not found — rebuild with 'make build-app' or choose a local archive.")
                            .font(NotRecallTheme.font(11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Button("Choose…", action: onChooseLocal)
                            .buttonStyle(SubtleButtonStyle(compact: true))
                            .disabled(isBusy)
                        if hasCustomRuntime {
                            Button("Reset", action: onResetLocal)
                                .buttonStyle(SubtleButtonStyle(compact: true))
                                .disabled(isBusy)
                        }
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Button("Install / Update", action: onInstallOrUpdate)
                        .buttonStyle(BrandButtonStyle(compact: true))
                        .disabled(isBusy || activeRuntimeSource == nil)

                    if stagedRuntimeReady {
                        Button("Update Runtime Only", action: onUpdateRuntimeOnly)
                            .buttonStyle(SubtleButtonStyle(compact: true))
                            .disabled(isBusy || activeRuntimeSource == nil)
                    }

                    Button("Dry Run", action: onDryRun)
                        .buttonStyle(SubtleButtonStyle(compact: true))
                        .disabled(isBusy || activeRuntimeSource == nil)

                    Spacer()

                    Button("Uninstall…", action: onUninstall)
                        .buttonStyle(SubtleButtonStyle(destructive: true, compact: true))
                        .disabled(isBusy)
                }
            }
        }
    }
}

// MARK: - Two-Column Bottom Cards (Recovery & Stack)

struct RecoveryControlsCard: View {
    let hasSteamApp: Bool
    let isBusy: Bool
    let onShowSteam: () -> Void
    let onOpenInputMonitoring: () -> Void
    let onImportFromRecall: () -> Void
    let onResetDisplay: () -> Void
    let onRestartSteam: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    title: "Recovery & Input",
                    subtitle: "Per-game options live in Steam’s Properties › Compatibility tab.",
                    symbol: "wrench.and.screwdriver"
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
                    title: "Import from Recall",
                    detail: "Copy shaders, Overwatch settings, highlights, and custom dxmt.conf from Recall.",
                    buttonTitle: "Import…",
                    disabled: isBusy,
                    action: onImportFromRecall
                )

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
    let steamPath: String?
    let notProtonReady: Bool
    let notProtonSupportPath: String
    let stagedRuntimeReady: Bool
    let runtimeSummary: String
    let steamToolReady: Bool
    let steamToolPath: String
    let overwatchShaderEntry: ShaderCacheEntry?
    let helpersInstalled: Bool
    let onInstallRosetta: () -> Void
    let onOpenNotProton: () -> Void
    let onOpenShaders: () -> Void
    let onOptimizeShader: (ShaderCacheEntry) -> Void
    let onRebuildShader: (ShaderCacheEntry) -> Void

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    title: "Stack & Shaders",
                    subtitle: "Live status of your macOS compatibility stack.",
                    symbol: "checkmark.seal"
                )

                VStack(alignment: .leading, spacing: 8) {
                    StackStatusRow(
                        title: "Rosetta 2",
                        detail: rosettaInstalled ? "Verified (x86_64)" : "Needed for Windows games on Apple Silicon",
                        ok: rosettaInstalled,
                        actionTitle: rosettaInstalled ? nil : "Install",
                        action: onInstallRosetta
                    )
                    StackStatusRow(
                        title: "Steam",
                        detail: steamPath ?? "Install Steam in Applications first",
                        ok: steamInstalled
                    )
                    StackStatusRow(
                        title: "NotProton Bridge",
                        detail: notProtonReady ? notProtonSupportPath : "Open NotProton and click Install first",
                        ok: notProtonReady,
                        actionTitle: notProtonReady ? nil : "Open NotProton",
                        action: onOpenNotProton
                    )
                    StackStatusRow(
                        title: "Wine + DXMT Runtime",
                        detail: stagedRuntimeReady ? runtimeSummary : "Not staged yet",
                        ok: stagedRuntimeReady
                    )
                    StackStatusRow(
                        title: "Steam Compat Tool",
                        detail: steamToolReady ? steamToolPath : "Not installed yet",
                        ok: steamToolReady
                    )
                    StackStatusRow(
                        title: "Shader Optimizer",
                        detail: helpersInstalled ? "Ready in background" : "Not installed yet",
                        ok: helpersInstalled
                    )
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
