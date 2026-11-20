import SwiftUI

struct ShadersView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SurfaceCard(padding: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        CardHeader(
                            title: "Game Shader Caches",
                            subtitle: "Your Mac learns shaders as you play and optimizes them in the background so future matches stay smooth.",
                            symbol: "cpu"
                        )
                        Spacer()
                        if !state.shaderCaches.isEmpty {
                            StatusTag(
                                text: "\(state.totalShaderCacheFormatted) · \(state.totalShaderPackCount) \(state.totalShaderPackCount == 1 ? "pack" : "packs")",
                                color: NotRecallTheme.brand
                            )
                        }
                    }
                }

                if state.shaderCaches.isEmpty {
                    SurfaceCard(padding: 32) {
                        ContentUnavailableView(
                            "No Shaders Saved Yet",
                            systemImage: "cpu",
                            description: Text("Play a game with NotRecall and your Mac will build its shader cache automatically.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(state.shaderCaches) { entry in
                            ShaderGameCard(
                                entry: entry,
                                helpersInstalled: state.helpersInstalled,
                                onOptimize: { Task { await state.optimizeShadersNow(entry) } },
                                onRebuild: { state.pendingRebuildShaderEntry = entry },
                                onClear: { state.pendingClearShaderEntry = entry }
                            )
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct ShaderGameCard: View {
    let entry: ShaderCacheEntry
    let helpersInstalled: Bool
    let onOptimize: () -> Void
    let onRebuild: () -> Void
    let onClear: () -> Void

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(entry.displayTitle)
                                .font(NotRecallTheme.font(14.5, .semibold))
                            if entry.isCompiling {
                                StatusTag(text: "Optimizing", color: NotRecallTheme.brand, symbol: "bolt.fill")
                            } else if entry.needsMacOSOptimization {
                                StatusTag(text: "Optimize for macOS", color: NotRecallTheme.warning, symbol: "exclamationmark.triangle.fill")
                            } else if entry.rebuildPending {
                                StatusTag(text: "Rebuilding Next Launch", color: NotRecallTheme.warning)
                            }
                        }
                        Text("\(entry.formattedSize) · \(entry.archiveCount) shader \(entry.archiveCount == 1 ? "pack" : "packs") · AppID \(entry.appID)")
                            .font(NotRecallTheme.font(12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 10)

                    HStack(spacing: 6) {
                        Button("Optimize Now", action: onOptimize)
                            .buttonStyle(BrandButtonStyle(compact: true))
                            .disabled(entry.isCompiling || !helpersInstalled)

                        Button("Rebuild Shaders", action: onRebuild)
                            .buttonStyle(SubtleButtonStyle(compact: true))
                            .help("Builds your shaders again without forgetting any. Try it if FPS drops or graphics look wrong.")
                            .disabled(entry.rebuildPending || entry.isCompiling)

                        Button("Clear Cache", action: onClear)
                            .buttonStyle(SubtleButtonStyle(destructive: true, compact: true))
                            .help("Deletes saved shaders if a game crashes or shows graphics glitches.")
                            .disabled(entry.isCompiling)
                    }
                }

                if entry.isCompiling {
                    if let ready = entry.preparingReady, let learned = entry.preparingLearned, learned > 0 {
                        VStack(alignment: .leading, spacing: 5) {
                            SmoothProgressBar(fraction: Double(min(ready, learned)) / Double(learned))
                            Text("Optimizing \(ready.formatted()) of \(learned.formatted()) shaders in the background…")
                                .font(NotRecallTheme.font(11.5))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Optimizing shaders in the background…")
                                .font(NotRecallTheme.font(11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
