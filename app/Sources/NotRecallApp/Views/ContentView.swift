import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 196, ideal: 210, max: 240)
        } detail: {
            VStack(spacing: 0) {
                DetailContentRouter(state: state)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

                if !state.statusMessage.isEmpty {
                    StatusFooterBar(
                        message: state.statusMessage,
                        onDismiss: { state.dismissStatusMessage() }
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(NotRecallTheme.canvas(scheme))
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.2), value: state.statusMessage.isEmpty)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await state.checkForRecallUpdates(silent: false) }
                } label: {
                    Label(state.isCheckingForUpdates ? "Checking…" : "Check Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Check GitHub for newer Recall runtime releases (⇧⌘U)")
                .disabled(state.isCheckingForUpdates || state.isBusy)

                Button {
                    state.copyDiagnostics()
                } label: {
                    Label(
                        state.diagnosticsCopied ? "Copied" : "Diagnostics",
                        systemImage: state.diagnosticsCopied ? "checkmark" : "doc.on.clipboard"
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .help("Copy system & log diagnostics to clipboard (⇧⌘C)")

                Button {
                    Task { await state.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh installation, Steam, and shader status (⌘R)")
                .disabled(state.isBusy)
            }
        }
        .sheet(isPresented: $state.showWhatsNewSheet) {
            if let release = state.availableRecallUpdate ?? state.latestRecallRelease ?? Optional(RecallReleaseInfo.pinnedDefault) {
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
        .alert(
            "Rebuild shaders for \(state.pendingRebuildShaderEntry?.displayTitle ?? "this game")?",
            isPresented: $state.isConfirmingRebuildShader
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Rebuild") {
                if let entry = state.pendingRebuildShaderEntry {
                    state.pendingRebuildShaderEntry = nil
                    Task { await state.requestRebuildShaders(entry) }
                }
            }
        } message: {
            Text("Builds your saved shaders again without forgetting any on the next launch. Try this if FPS drops or graphics look wrong.")
        }
        .alert(
            "Clear shader cache for \(state.pendingClearShaderEntry?.displayTitle ?? "this game")?",
            isPresented: $state.isConfirmingClearShader
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) {
                if let entry = state.pendingClearShaderEntry {
                    state.pendingClearShaderEntry = nil
                    Task { await state.clearShaderCache(entry) }
                }
            }
        } message: {
            Text("Deletes saved shaders (\(state.pendingClearShaderEntry?.formattedSize ?? "")). Your next few matches will stutter while your Mac relearns them. Your game files and settings stay as they are.")
        }
        .alert("Uninstall NotRecall?", isPresented: $state.confirmUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                Task { await state.uninstallNotRecall() }
            }
        } message: {
            Text("This removes NotRecall’s Steam compatibility tool, staged runtime, settings, and downloaded Recall cache. Your Steam games and saved highlights stay untouched.")
        }
        .task(id: state.anyShaderCompiling) {
            guard state.anyShaderCompiling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await state.refresh(preserveLog: true)
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                NotRecallEmblem(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("NotRecall")
                        .font(NotRecallTheme.font(14, .semibold))
                    Text("v\(state.appVersionString) · Steam")
                        .font(NotRecallTheme.font(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            List(SidebarSection.allCases, selection: $state.selectedSection) { section in
                SidebarRow(
                    section: section,
                    setupNeedsAttention: state.hasMissingPrerequisites || !state.isFullyInstalled,
                    shaderBadgeCount: state.shaderCaches.count,
                    shadersActive: state.anyShaderCompiling || state.anyShaderNeedsMacOSOptimization
                )
                .tag(section)
            }
            .listStyle(.sidebar)

            Divider()

            SidebarStatusFooter(
                isReadyToPlay: state.isReadyToPlay,
                hasMissingPrerequisites: state.hasMissingPrerequisites,
                installedRecallVersion: state.installedRecallVersion,
                availableUpdateVersion: state.availableRecallUpdate?.version,
                onOpenWhatsNew: { state.showWhatsNewSheet = true }
            )
            .padding(12)
        }
    }
}

struct SidebarRow: View {
    let section: SidebarSection
    let setupNeedsAttention: Bool
    let shaderBadgeCount: Int
    let shadersActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(section.title, systemImage: section.symbol)
            Spacer(minLength: 4)
            if section == .overview && setupNeedsAttention {
                Circle()
                    .fill(NotRecallTheme.warning)
                    .frame(width: 7, height: 7)
            } else if section == .shaders && shadersActive {
                Circle()
                    .fill(NotRecallTheme.brand)
                    .frame(width: 7, height: 7)
            } else if section == .shaders && shaderBadgeCount > 0 {
                Text("\(shaderBadgeCount)")
                    .font(NotRecallTheme.font(10.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(.primary.opacity(0.08), in: Capsule())
            }
        }
    }
}

struct SidebarStatusFooter: View {
    let isReadyToPlay: Bool
    let hasMissingPrerequisites: Bool
    let installedRecallVersion: String?
    let availableUpdateVersion: String?
    let onOpenWhatsNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isReadyToPlay ? NotRecallTheme.healthy : (hasMissingPrerequisites ? NotRecallTheme.warning : NotRecallTheme.brand))
                    .frame(width: 7, height: 7)
                Text(isReadyToPlay ? "Ready to Play" : (hasMissingPrerequisites ? "Setup Required" : "Installed"))
                    .font(NotRecallTheme.font(11.5, .semibold))
                    .foregroundStyle(.primary)
            }

            if let updateVer = availableUpdateVersion {
                Button("Recall \(updateVer) available →", action: onOpenWhatsNew)
                    .buttonStyle(.borderless)
                    .font(NotRecallTheme.font(11, .medium))
                    .foregroundStyle(NotRecallTheme.brand)
            } else if let recallVer = installedRecallVersion {
                Text("Recall Runtime \(recallVer)")
                    .font(NotRecallTheme.font(11))
                    .foregroundStyle(.secondary)
            } else {
                Text("No runtime staged")
                    .font(NotRecallTheme.font(11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detail Router & Status Footer

struct DetailContentRouter: View {
    @ObservedObject var state: AppState

    var body: some View {
        switch state.selectedSection {
        case .overview:
            OverviewView(state: state)
        case .shaders:
            ShadersView(state: state)
        case .logs:
            LogsView(state: state)
        }
    }
}

struct StatusFooterBar: View {
    let message: String
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(NotRecallTheme.brand)
            Text(message)
                .font(NotRecallTheme.font(12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Dismiss status message")
            .accessibilityLabel("Dismiss status message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(NotRecallTheme.cardFill(scheme))
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
