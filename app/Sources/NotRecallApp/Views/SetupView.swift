import SwiftUI

struct SetupView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SurfaceCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(
                            title: "Recall Runtime Source",
                            subtitle: "Choose a local Recall .dmg, Recall.app, or let NotRecall download and verify the latest GitHub release.",
                            symbol: "shippingbox"
                        )

                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: state.activeRuntimeSource != nil ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(state.activeRuntimeSource != nil ? NotRecallTheme.healthy : NotRecallTheme.brand)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.customRuntimeURL != nil ? "Custom Recall File" : (state.activeRuntimeSource != nil ? "Local Recall Copy" : "GitHub Release Download"))
                                    .font(NotRecallTheme.font(13, .semibold))
                                Text(
                                    state.activeRuntimeSource?.path
                                        ?? "Downloads \(state.preferredDownloadRelease.title) from GitHub\(state.preferredDownloadRelease.formattedSize.map { " (\($0))" } ?? "")"
                                )
                                .font(NotRecallTheme.font(11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)

                            HStack(spacing: 6) {
                                Button("Choose…") { state.selectLocalRuntime() }
                                    .buttonStyle(SubtleButtonStyle(compact: true))
                                    .disabled(state.isBusy)
                                if state.customRuntimeURL != nil {
                                    Button("Reset") { state.clearCustomRuntime() }
                                        .buttonStyle(SubtleButtonStyle(compact: true))
                                        .disabled(state.isBusy)
                                }
                            }
                        }

                        if let progress = state.downloadProgress {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(state.downloadStatusText)
                                        .font(NotRecallTheme.font(12, .medium))
                                        .contentTransition(.numericText())
                                    Spacer()
                                    Button("Cancel") { state.cancelDownload() }
                                        .buttonStyle(SubtleButtonStyle(compact: true))
                                }
                                SmoothProgressBar(fraction: progress)
                            }
                        }

                        Divider()

                        HStack(spacing: 8) {
                            Button(state.activeRuntimeSource != nil ? "Install / Update" : "Download & Install") {
                                if let rt = state.activeRuntimeSource {
                                    Task { await state.runProjectScript("scripts/install.sh", extraArgs: ["--runtime", rt.path]) }
                                } else {
                                    state.downloadAndInstallRecall(state.preferredDownloadRelease, runtimeOnly: false)
                                }
                            }
                            .buttonStyle(BrandButtonStyle(compact: true))
                            .disabled(state.isBusy)

                            if state.stagedRuntimeReady {
                                Button("Update Runtime Only") {
                                    if let rt = state.activeRuntimeSource {
                                        Task { await state.runProjectScript("scripts/install.sh", extraArgs: ["--runtime-only", "--runtime", rt.path]) }
                                    } else {
                                        state.downloadAndInstallRecall(state.preferredDownloadRelease, runtimeOnly: true)
                                    }
                                }
                                .buttonStyle(SubtleButtonStyle(compact: true))
                                .disabled(state.isBusy)
                            }

                            Button("Dry Run") {
                                Task {
                                    var args = ["--dry-run"]
                                    if let rt = state.activeRuntimeSource { args += ["--runtime", rt.path] }
                                    await state.runProjectScript("scripts/install.sh", extraArgs: args, switchToLogs: true)
                                }
                            }
                            .buttonStyle(SubtleButtonStyle(compact: true))
                            .disabled(state.isBusy)

                            Spacer()

                            Button("Restart Steam") {
                                Task { await state.restartSteam() }
                            }
                            .buttonStyle(SubtleButtonStyle(compact: true))
                            .disabled(state.isBusy || state.steamAppURL == nil)

                            Button("Uninstall…") {
                                state.confirmUninstall = true
                            }
                            .buttonStyle(SubtleButtonStyle(destructive: true, compact: true))
                            .disabled(state.isBusy)
                        }
                    }
                }

                SurfaceCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(
                            title: "Full Compatibility Stack",
                            subtitle: "Every component NotRecall checks before Steam launches a game.",
                            symbol: "checklist"
                        )

                        StackStatusRow(
                            title: "Rosetta 2",
                            detail: state.rosettaInstalled ? "Ready (verified x86_64 execution)" : "Needed to run Windows games on Apple Silicon",
                            ok: state.rosettaInstalled,
                            actionTitle: state.rosettaInstalled ? nil : "Install",
                            action: { state.installRosetta() }
                        )
                        Divider()
                        StackStatusRow(
                            title: "Steam",
                            detail: state.steamAppURL?.path ?? "Install Steam in Applications first",
                            ok: state.steamAppURL != nil
                        )
                        Divider()
                        StackStatusRow(
                            title: "NotProton Bridge",
                            detail: state.notProtonBridgeReady ? state.notProtonSupport.path : "Open NotProton and click Install first",
                            ok: state.notProtonBridgeReady,
                            actionTitle: state.notProtonBridgeReady ? nil : "Open NotProton",
                            action: { state.openNotProton() }
                        )
                        Divider()
                        StackStatusRow(
                            title: "Recall Runtime",
                            detail: state.stagedRuntimeReady ? "\(state.stagedRuntimeSummary) — \(state.notRecallSupport.appending(path: "runtime").path)" : "Not installed yet",
                            ok: state.stagedRuntimeReady
                        )
                        Divider()
                        StackStatusRow(
                            title: "Steam Compatibility Tool",
                            detail: state.steamToolInstalled ? state.steamCompatTool.path : "Not installed yet",
                            ok: state.steamToolInstalled
                        )
                        Divider()
                        StackStatusRow(
                            title: "Steam Settings Panel (NotProton Plugin)",
                            detail: state.pluginInstalled ? "Installed — adds NotRecall options to Steam’s Compatibility tab" : "Not installed yet",
                            ok: state.pluginInstalled
                        )
                        Divider()
                        StackStatusRow(
                            title: "Background Shader Optimizer",
                            detail: state.helpersInstalled ? "Ready — compiles shaders between matches to reduce stutters" : "Not installed yet",
                            ok: state.helpersInstalled
                        )
                    }
                }
            }
            .padding(20)
        }
        .alert("Uninstall NotRecall?", isPresented: $state.confirmUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                Task { await state.runProjectScript("scripts/uninstall.sh") }
            }
        } message: {
            Text("This removes NotRecall’s Steam compatibility tool, NotProton plugin, and staged runtime. Your Steam games and saved highlights stay untouched.")
        }
    }
}
