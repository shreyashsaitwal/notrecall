import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView(selection: $state.selectedTab) {
            statusTab
                .tabItem { Label("Status", systemImage: "checkmark.shield") }
                .tag(0)
            shaderCachesTab
                .tabItem { Label("Shaders", systemImage: "cpu") }
                .tag(1)
            logsTab
                .tabItem { Label("Logs", systemImage: "doc.text") }
                .tag(2)
        }
        .padding()
        .sheet(isPresented: $state.showWhatsNewSheet) {
            if let release = state.availableRecallUpdate ?? state.latestRecallRelease {
                WhatsNewSheet(
                    release: release,
                    installedVersion: state.installedRecallVersion,
                    isBusy: state.isBusy,
                    onUpdate: {
                        state.showWhatsNewSheet = false
                        state.downloadAndInstallRecall(release, runtimeOnly: state.stagedRuntimeReady)
                    },
                    onDismiss: {
                        state.showWhatsNewSheet = false
                    }
                )
            }
        }
        .alert("Force quit Overwatch?", isPresented: $state.confirmForceQuit) {
            Button("Cancel", role: .cancel) {}
            Button("Force Quit", role: .destructive) {
                Task { await state.forceQuitOverwatch() }
            }
        } message: {
            Text("Use this when the game stops responding. If you’re in a match, you’ll leave it.")
        }
        .alert("Reset display settings?", isPresented: $state.confirmResetDisplay) {
            Button("Cancel", role: .cancel) {}
            Button("Reset") {
                Task { await state.resetOverwatchDisplaySettings() }
            }
        } message: {
            Text("Overwatch will open full screen at \(state.defaultOverwatchResolutionLabel) the next time it starts. Your graphics quality and FPS settings stay as they are.")
        }
    }

    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("NotRecall for Steam")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        Task { await state.checkForRecallUpdates(silent: false) }
                    } label: {
                        Label(state.isCheckingForUpdates ? "Checking…" : "Check Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .disabled(state.isCheckingForUpdates || state.isBusy)
                    Button {
                        state.copyDiagnostics()
                    } label: {
                        Label("Copy Diagnostics", systemImage: "doc.on.clipboard")
                    }
                    .controlSize(.small)
                }

                Text("Play Overwatch and other DirectX 11 Windows games on Steam using Recall’s Mac runtime.")
                    .foregroundStyle(.secondary)

                if let update = state.availableRecallUpdate {
                    recallUpdateCallout(update)
                }

                if state.hasMissingPrerequisites {
                    prerequisiteCallout
                }

                if !state.healthWarnings.isEmpty {
                    healthWarningsCallout
                }

                overwatchCard

                GroupBox("Setup Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        statusRow("Rosetta 2", ok: state.rosettaInstalled, detail: state.rosettaInstalled ? "Ready" : "Needed to run Windows games on Apple Silicon")
                        statusRow("Steam", ok: state.steamAppURL != nil, detail: state.steamAppURL?.path ?? "Install Steam in Applications first")
                        statusRow("NotProton", ok: state.notProtonBridgeReady, detail: state.notProtonBridgeReady ? "Ready" : "Open NotProton and click Install so Steam can launch Windows games")
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: state.activeRuntimeSource != nil ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                .foregroundStyle(state.activeRuntimeSource != nil ? .green : .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.customRuntimeURL != nil ? "Custom Recall File" : (state.activeRuntimeSource != nil ? "Local Recall Copy" : "Recall Download"))
                                    .font(.body)
                                Text(
                                    state.activeRuntimeSource?.path
                                        ?? "Downloads \(state.preferredDownloadRelease.title) from GitHub\(state.preferredDownloadRelease.formattedSize.map { " (\($0))" } ?? "")"
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Choose…") { state.selectLocalRuntime() }
                                .controlSize(.small)
                            if state.customRuntimeURL != nil {
                                Button("Reset") { state.clearCustomRuntime() }
                                    .controlSize(.small)
                            }
                        }
                        statusRow(
                            "Recall Runtime",
                            ok: state.stagedRuntimeReady,
                            detail: stagedRuntimeDetail
                        )
                        statusRow("Steam Compatibility Tool", ok: state.steamToolInstalled, detail: state.steamToolInstalled ? "Ready in Steam" : "Not installed yet")
                        statusRow("Steam Settings Panel", ok: state.pluginInstalled, detail: state.pluginInstalled ? "Installed — adds NotRecall options to Steam’s Compatibility tab" : "Not installed yet")
                        statusRow("Background Shader Optimizer", ok: state.helpersInstalled, detail: state.helpersInstalled ? "Ready — prepares shaders between matches to prevent stutters" : "Not installed yet")
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("High-precision mouse (optional)").font(.body)
                                Text("Skips macOS’s mouse layer for the most precise aim. Add Steam in System Settings › Input Monitoring — until then, your mouse works normally.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show Steam") { state.revealSteamInFinder() }
                                .controlSize(.small)
                            Button("Open Settings") { state.openInputMonitoringSettings() }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }

                troubleshootingCard

                if let progress = state.downloadProgress {
                    GroupBox {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: progress, total: 1.0)
                                Text(state.downloadStatusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Cancel") {
                                state.cancelDownload()
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack(spacing: 8) {
                    Button(state.activeRuntimeSource != nil ? "Install / Update" : "Download & Install") {
                        if let rt = state.activeRuntimeSource {
                            Task {
                                await state.runProjectScript("scripts/install.sh", extraArgs: ["--runtime", rt.path])
                            }
                        } else {
                            state.downloadAndInstallRecall(state.preferredDownloadRelease, runtimeOnly: false)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)

                    if state.stagedRuntimeReady {
                        Button("Update Runtime Only") {
                            if let rt = state.activeRuntimeSource {
                                Task {
                                    await state.runProjectScript("scripts/install.sh", extraArgs: ["--runtime-only", "--runtime", rt.path])
                                }
                            } else {
                                state.downloadAndInstallRecall(state.preferredDownloadRelease, runtimeOnly: true)
                            }
                        }
                        .disabled(state.isBusy)
                    }

                    Button("Dry Run") {
                        Task {
                            var args = ["--dry-run"]
                            if let rt = state.activeRuntimeSource { args += ["--runtime", rt.path] }
                            await state.runProjectScript("scripts/install.sh", extraArgs: args, switchToLogs: true)
                        }
                    }
                    .disabled(state.isBusy)

                    Button("Restart Steam") {
                        Task { await state.restartSteam() }
                    }
                    .disabled(state.isBusy || state.steamAppURL == nil)

                    Button("Uninstall", role: .destructive) {
                        Task { await state.runProjectScript("scripts/uninstall.sh") }
                    }
                    .disabled(state.isBusy)

                    Spacer()

                    Button("Refresh") {
                        Task { await state.refresh() }
                    }
                    .disabled(state.isBusy)
                }

                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stagedRuntimeDetail: String {
        let path = state.notRecallSupport.appending(path: "runtime").path
        var parts: [String] = []
        if let recallVer = state.installedRecallVersion {
            parts.append("Recall \(recallVer)")
        }
        if let rtVer = state.stagedRuntimeVersion {
            parts.append(rtVer)
        }
        if parts.isEmpty { return path }
        return "\(parts.joined(separator: " • ")) — \(path)"
    }

    private func recallUpdateCallout(_ update: RecallReleaseInfo) -> some View {
        GroupBox {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recall \(update.version) is available")
                        .font(.headline)
                    Text(
                        state.installedRecallVersion.map { "You have Recall \($0). Your games, saves, and settings stay as they are." }
                            ?? "A newer Recall release is ready on GitHub."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("What's New…") {
                    state.showWhatsNewSheet = true
                }
                .controlSize(.small)
                Button("Update") {
                    state.downloadAndInstallRecall(update, runtimeOnly: state.stagedRuntimeReady)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.isBusy)
            }
            .padding(.vertical, 2)
        }
    }

    private var prerequisiteCallout: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Before You Install")
                        .font(.headline)
                    if !state.rosettaInstalled {
                        Text("Install Rosetta 2 so your Mac can run Windows games.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !state.notProtonBridgeReady {
                        Text("Open NotProton and click Install first so Steam can launch Windows games.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if state.steamAppURL == nil {
                        Text("Install Steam in Applications before setting up NotRecall.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !state.rosettaInstalled {
                    Button("Install Rosetta") { state.installRosetta() }
                        .controlSize(.small)
                }
                if !state.notProtonBridgeReady {
                    Button("Open NotProton") { state.openNotProton() }
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var healthWarningsCallout: some View {
        GroupBox("Before You Play") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.healthWarnings) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: warning.isCritical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(warning.isCritical ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.title).font(.subheadline.weight(.medium))
                            Text(warning.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var overwatchCard: some View {
        GroupBox("Overwatch on Steam") {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: state.overwatchConfiguredForNotRecall ? "checkmark.circle.fill" : (state.overwatchInstalled ? "gamecontroller.fill" : "magnifyingglass"))
                    .foregroundStyle(state.overwatchConfiguredForNotRecall ? .green : (state.overwatchInstalled ? .blue : .secondary))
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    if !state.overwatchInstalled {
                        Text("Overwatch isn’t installed in Steam yet")
                            .font(.subheadline.weight(.medium))
                        Text("Install Overwatch in Steam, then come back here to set it up with one click.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if state.overwatchConfiguredForNotRecall {
                        Text("Ready to play")
                            .font(.subheadline.weight(.medium))
                        Text("Set up in Steam with Recall’s recommended Overwatch settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Overwatch is installed — ready to set up")
                            .font(.subheadline.weight(.medium))
                        Text("Click Set Up in Steam to configure Overwatch automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if state.overwatchInstalled && !state.overwatchConfiguredForNotRecall {
                    Button("Set Up in Steam") {
                        Task { await state.configureOverwatchInSteam() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.isBusy || !state.steamToolInstalled)
                }
                if state.overwatchInstalled {
                    Button("Play") {
                        state.playOverwatch()
                    }
                    .controlSize(.small)
                    .disabled(state.isBusy || state.steamAppURL == nil)
                }
                Button("Highlights") {
                    state.openOverwatchHighlights()
                }
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        }
    }

    private var troubleshootingCard: some View {
        GroupBox("Troubleshooting") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Force Quit Overwatch").font(.body)
                        Text("If the game stops responding.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Force Quit", role: .destructive) {
                        state.confirmForceQuit = true
                    }
                    .controlSize(.small)
                    .disabled(state.isBusy)
                }
                Divider()
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset Display Settings…").font(.body)
                        Text("If Overwatch opens to a black screen or at the wrong size.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset") {
                        state.confirmResetDisplay = true
                    }
                    .controlSize(.small)
                    .disabled(state.isBusy)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var shaderCachesTab: some View {
        let anyCompiling = state.shaderCaches.contains(where: \.isCompiling)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Game Shaders")
                        .font(.title3.weight(.semibold))
                    Text("Your Mac learns shaders as you play and optimizes them in the background so future matches stay smooth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await state.refresh() } }
            }
            if state.shaderCaches.isEmpty {
                ContentUnavailableView(
                    "No Shaders Saved Yet",
                    systemImage: "cpu",
                    description: Text("Play a game with NotRecall and your Mac will build its shader cache automatically.")
                )
            } else {
                List(state.shaderCaches) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(entry.displayTitle).font(.headline)
                                    if entry.isCompiling {
                                        Text("Optimizing")
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.2))
                                            .clipShape(Capsule())
                                    }
                                    if entry.needsMacOSOptimization && !entry.isCompiling {
                                        Text("Optimize for this macOS")
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.2))
                                            .clipShape(Capsule())
                                    }
                                    if entry.rebuildPending {
                                        Text("Rebuilding Next Launch")
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.2))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(entry.formattedSize) • \(entry.archiveCount) shader \(entry.archiveCount == 1 ? "pack" : "packs")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Optimize Now") {
                                Task { await state.optimizeShadersNow(entry) }
                            }
                            .disabled(entry.isCompiling || !state.helpersInstalled)
                            Button("Rebuild Shaders") {
                                Task { await state.requestRebuildShaders(entry) }
                            }
                            .help("Builds your shaders again without forgetting any. Try it if FPS drops or graphics look wrong.")
                            .disabled(entry.rebuildPending || entry.isCompiling)
                            Button("Clear Cache", role: .destructive) {
                                Task { await state.clearShaderCache(entry) }
                            }
                            .help("Deletes saved shaders if a game crashes or shows graphics glitches.")
                            .disabled(entry.isCompiling)
                        }
                        if entry.isCompiling {
                            if let ready = entry.preparingReady, let learned = entry.preparingLearned, learned > 0 {
                                VStack(alignment: .leading, spacing: 2) {
                                    ProgressView(value: Double(min(ready, learned)), total: Double(learned))
                                    Text("Optimizing \(ready) of \(learned) shaders in the background…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Optimizing shaders in the background…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .task(id: "\(state.selectedTab)-\(anyCompiling)") {
            guard state.selectedTab == 1, anyCompiling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await state.refresh(preserveLog: true)
            }
        }
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session Log")
                        .font(.title3.weight(.semibold))
                    if !state.recentLogTitle.isEmpty {
                        Text(state.recentLogTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Copy Diagnostics") { state.copyDiagnostics() }
                Button("Reload") { Task { await state.refresh() } }
            }
            ScrollView {
                Text(state.recentLogText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func statusRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
    }
}

struct WhatsNewSheet: View {
    let release: RecallReleaseInfo
    let installedVersion: String?
    let isBusy: Bool
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's New in \(release.title)")
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        if let installed = installedVersion {
                            Text("Installed: \(installed)")
                        }
                        if let size = release.formattedSize {
                            Text("Download: \(size)")
                        }
                        if let minOS = release.minimumMacOS {
                            Text("Requires macOS \(minOS)+")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("View on GitHub") {
                    NSWorkspace.shared.open(release.releasePageURL)
                }
                .controlSize(.small)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(release.whatsNewMarkdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            Spacer().frame(height: 2)
                        } else if trimmed.hasPrefix("## ") {
                            Text(String(trimmed.dropFirst(3)))
                                .font(.headline)
                                .padding(.top, 4)
                        } else if trimmed.hasPrefix("### ") {
                            Text(String(trimmed.dropFirst(4)))
                                .font(.subheadline.weight(.semibold))
                                .padding(.top, 2)
                        } else if let attributed = try? AttributedString(markdown: trimmed) {
                            Text(attributed)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(trimmed)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 200, maxHeight: 340)

            Divider()

            HStack {
                Text("NotRecall will download \(release.dmgName), verify it, and update your runtime. Your games, saves, and settings stay as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Not Now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Update to \(release.version)", action: onUpdate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

