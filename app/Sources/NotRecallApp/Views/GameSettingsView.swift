import SwiftUI

struct GameSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InlineBanner(
                    symbol: "checkmark.seal.fill",
                    title: "Applied automatically on every Steam launch",
                    message: "Leave Steam’s Launch Options blank to avoid macOS Steam OS Error 260. If you ever pass custom options in Steam, use /usr/bin/env KEY=VAL %command%.",
                    tint: NotRecallTheme.brand
                )

                GraphicsSettingsCard(state: state)
                InputSettingsCard(state: state)
                SystemAndLoggingCard(state: state)

                HStack {
                    Text("Saved to ~/Library/Application Support/notrecall/settings.env")
                        .font(NotRecallTheme.font(11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") {
                        state.resetGameSettingsToDefaults()
                    }
                    .buttonStyle(SubtleButtonStyle(compact: true))
                }
            }
            .padding(20)
        }
    }
}

struct GraphicsSettingsCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    title: "Graphics & Performance",
                    subtitle: "Changes take effect the next time you launch a game from Steam.",
                    symbol: "sparkles.tv"
                )

                SettingsToggleRow(
                    title: "MetalFX Upscaling",
                    detail: "Adds NVIDIA DLSS to Overwatch’s Video options and runs it on Apple’s MetalFX.",
                    isOn: $state.metalFXUpscaling
                )

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sharpening")
                            .font(NotRecallTheme.font(13, .medium))
                            .foregroundStyle(state.gameSettings.metalFXUpscaling ? .primary : .secondary)
                        Text("Makes the upscaled picture crisper when MetalFX is enabled.")
                            .font(NotRecallTheme.font(11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Sharpening", selection: $state.metalFXSharpness) {
                        ForEach(MetalFXSharpness.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!state.gameSettings.metalFXUpscaling)
                }

                Divider()

                SettingsToggleRow(
                    title: "Metal Performance HUD",
                    detail: "Shows Apple’s FPS, frame time, memory, and shader compilation overlay in game.",
                    isOn: $state.metalHUD
                )

                Divider()

                SettingsToggleRow(
                    title: "Lower Input Lag (Frame Pacing)",
                    detail: "Waits briefly between frames so each frame samples fresher mouse input.",
                    isOn: $state.framePacing
                )

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Frame Rate Limit")
                            .font(NotRecallTheme.font(13, .medium))
                        Text("Caps DXMT frame rate. Leave Off to use the game’s own FPS cap.")
                            .font(NotRecallTheme.font(11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Frame Rate Limit", selection: $state.fpsLimit) {
                        ForEach(GameSettings.fpsChoices, id: \.self) { fps in
                            Text(fps == 0 ? "Off" : "\(fps) FPS").tag(fps)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shader Memory")
                            .font(NotRecallTheme.font(13, .medium))
                        Text("How much of your shader cache loads at launch. Only lower on 8 GB Macs.")
                            .font(NotRecallTheme.font(11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Shader Memory", selection: $state.shaderMemory) {
                        ForEach(ShaderMemoryBudget.allCases) { budget in
                            Text(budget.title).tag(budget)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}

struct InputSettingsCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    title: "Mouse & Input",
                    subtitle: "Configure raw HID mouse polling and controller routing.",
                    symbol: "cursorarrow.motionlines"
                )

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mouse Mode")
                            .font(NotRecallTheme.font(13, .medium))
                        Text(state.gameSettings.mouseMode.detail)
                            .font(NotRecallTheme.font(11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("Mouse Mode", selection: $state.mouseMode) {
                        ForEach(MouseMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mouse Polling Limit")
                            .font(NotRecallTheme.font(13, .medium))
                        Text("Caps mouse reports per second in High-Precision or Standard mode.")
                            .font(NotRecallTheme.font(11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Mouse Polling Limit", selection: $state.mouseRate) {
                        ForEach(MousePollingLimit.allCases) { rate in
                            Text(rate.title).tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                Divider()

                SettingsToggleRow(
                    title: "Faster Key Response (Experimental)",
                    detail: "Keys reach the game 1–3 ms sooner. Menus may hitch slightly with high-polling mice.",
                    isOn: $state.fastKeys
                )

                Divider()

                SettingsToggleRow(
                    title: "Raw Controllers (Bypass Steam Input)",
                    detail: "Lets games read controllers directly. May cause double inputs if Steam Input is active.",
                    isOn: $state.rawControllers
                )
            }
        }
    }
}

struct SystemAndLoggingCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    title: "System & Diagnostic Logging",
                    subtitle: "Advanced runtime controls and bug-report logging presets.",
                    symbol: "wrench.and.screwdriver"
                )

                SettingsToggleRow(
                    title: "macOS Game Mode",
                    detail: "Gives your game CPU and GPU priority while fullscreen.",
                    isOn: $state.gameMode
                )
                Divider()
                SettingsToggleRow(
                    title: "Background Shader Optimization",
                    detail: "Compiles newly learned shaders after each session so future matches stay smooth.",
                    isOn: $state.backgroundShaderPrep
                )
                Divider()
                SettingsToggleRow(
                    title: "MSync",
                    detail: "Fast macOS synchronization primitive. Leave on unless troubleshooting startup hangs.",
                    isOn: $state.msync
                )
                Divider()
                SettingsToggleRow(
                    title: "Detect Network Proxy Automatically",
                    detail: "Only needed on some work or school networks.",
                    isOn: $state.proxyAutoDetect
                )
                Divider()
                SettingsToggleRow(
                    title: "Log Crashes & Freezes",
                    detail: "Records Wine errors and loaded DLLs for bug reports. May lower FPS.",
                    isOn: $state.logCrashes
                )
                Divider()
                SettingsToggleRow(
                    title: "Log Graphics (DXMT)",
                    detail: "Writes detailed graphics logs to dxmt-logs/. May lower FPS.",
                    isOn: $state.logGraphics
                )
                Divider()
                SettingsToggleRow(
                    title: "Log Mouse Input",
                    detail: "Records mouse polling stats to input-logs/. May lower FPS.",
                    isOn: $state.logMouse
                )
            }
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NotRecallTheme.font(13, .medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(NotRecallTheme.font(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(NotRecallTheme.brand)
        }
    }
}
