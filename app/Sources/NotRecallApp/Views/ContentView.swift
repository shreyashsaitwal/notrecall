import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView(selection: $state.selectedTab) {
            statusTab
                .tabItem { Label("Status", systemImage: "checkmark.shield") }
                .tag(0)
            shaderCachesTab
                .tabItem { Label("Shader Caches", systemImage: "cpu") }
                .tag(1)
            logsTab
                .tabItem { Label("Logs", systemImage: "doc.text") }
                .tag(2)
        }
        .padding()
    }

    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("NotRecall for Steam")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        state.copyDiagnostics()
                    } label: {
                        Label("Copy Diagnostics", systemImage: "doc.on.clipboard")
                    }
                    .controlSize(.small)
                }

                Text("Runs Recall's patched Wine + DXMT runtime as a Steam Play compatibility tool on top of stock NotProton.")
                    .foregroundStyle(.secondary)

                if state.hasMissingPrerequisites {
                    prerequisiteCallout
                }

                GroupBox("Environment Checks") {
                    VStack(alignment: .leading, spacing: 8) {
                        statusRow("Rosetta 2", ok: state.rosettaInstalled, detail: state.rosettaInstalled ? "Installed" : "Required to run x86_64 Wine on Apple Silicon")
                        statusRow("Steam", ok: state.steamAppURL != nil, detail: state.steamAppURL?.path ?? "Not found in /Applications")
                        statusRow("NotProton Steamworks Bridge", ok: state.notProtonBridgeReady, detail: state.notProtonSupport.appending(path: "bridge").path)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: state.activeRuntimeSource != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(state.activeRuntimeSource != nil ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.customRuntimeURL != nil ? "Custom Recall Runtime" : "Bundled / Source Recall Runtime")
                                    .font(.body)
                                Text(state.activeRuntimeSource?.path ?? "Not found (run 'make build-runtime' or choose a local runtime)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Select…") { state.selectLocalRuntime() }
                                .controlSize(.small)
                            if state.customRuntimeURL != nil {
                                Button("Reset") { state.clearCustomRuntime() }
                                    .controlSize(.small)
                            }
                        }
                        statusRow(
                            "Staged NotRecall Runtime",
                            ok: state.stagedRuntimeReady,
                            detail: state.stagedRuntimeVersion.map { "\($0) — \(state.notRecallSupport.appending(path: "runtime").path)" }
                                ?? state.notRecallSupport.appending(path: "runtime").path
                        )
                        statusRow("Steam Compatibility Tool (notrecall-proton)", ok: state.steamToolInstalled, detail: state.steamCompatTool.path)
                        statusRow("NotProton UI Plugin (50-notrecall.conf)", ok: state.pluginInstalled, detail: state.pluginFile.path)
                        statusRow("Offline Shader Precompiler (portable-pipeline)", ok: state.helpersInstalled, detail: state.notRecallSupport.appending(path: "helpers/portable-pipeline").path)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Input Monitoring Permission (Raw HID Mouse)").font(.body)
                                Text("Optional — only needed for 8,000 Hz Raw HID mouse mode. Grant Input Monitoring to Steam.app in System Settings.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reveal Steam") { state.revealSteamInFinder() }
                                .controlSize(.small)
                            Button("Open Settings") { state.openInputMonitoringSettings() }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack(spacing: 8) {
                    Button("Install / Update") {
                        Task {
                            var args: [String] = []
                            if let rt = state.activeRuntimeSource { args += ["--runtime", rt.path] }
                            await state.runProjectScript("scripts/install.sh", extraArgs: args)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)

                    if state.stagedRuntimeReady {
                        Button("Update Runtime Only") {
                            Task {
                                var args = ["--runtime-only"]
                                if let rt = state.activeRuntimeSource { args += ["--runtime", rt.path] }
                                await state.runProjectScript("scripts/install.sh", extraArgs: args)
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

    private var prerequisiteCallout: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prerequisites Needed")
                        .font(.headline)
                    if !state.rosettaInstalled {
                        Text("Rosetta 2 is required to run Windows x86_64 games through Wine.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !state.notProtonBridgeReady {
                        Text("Open NotProton and click Install first so its Steamworks bridge is staged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if state.steamAppURL == nil {
                        Text("Install Steam for macOS into /Applications before running NotRecall.")
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

    private var shaderCachesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Per-Game DXMT Shader Caches")
                        .font(.title3.weight(.semibold))
                    Text("Scanned \(state.steamLibraryCount) Steam \(state.steamLibraryCount == 1 ? "library" : "libraries")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await state.refresh() } }
            }
            if state.shaderCaches.isEmpty {
                ContentUnavailableView(
                    "No Shader Caches Yet",
                    systemImage: "cpu",
                    description: Text("Launch a DX11 Steam game using NotRecall to build its per-AppID shader pack.")
                )
            } else {
                List(state.shaderCaches) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.displayTitle).font(.headline)
                                if entry.rebuildPending {
                                    Text("Rebuild Queued")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }
                            Text("AppID \(entry.appID) • \(entry.archiveCount) .metallib archive(s) • \(entry.formattedSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rebuild Shaders") {
                            Task { await state.requestRebuildShaders(entry) }
                        }
                        .disabled(entry.rebuildPending)
                        Button("Clear Cache", role: .destructive) {
                            Task { await state.clearShaderCache(entry) }
                        }
                    }
                }
            }
        }
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latest Launch Log")
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
