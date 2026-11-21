import SwiftUI

@main
struct NotRecallApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("NotRecall", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 780, idealWidth: 900, minHeight: 560, idealHeight: 650)
                .task { await state.refresh() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Game") {
                Button("Play Overwatch") {
                    state.playOverwatch()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(state.isBusy || !state.overwatchInstalled || state.steamAppURL == nil)

                Button("Open Highlights Folder") {
                    state.openOverwatchHighlights()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                Button("Restart Steam") {
                    Task { await state.restartSteam() }
                }
                .disabled(state.isBusy || state.steamAppURL == nil)

                Button("Reset Display Settings…") {
                    state.confirmResetDisplay = true
                }
                .disabled(state.isBusy)

                Button("Force Quit Overwatch…") {
                    state.confirmForceQuit = true
                }
                .disabled(state.isBusy)
            }

            CommandMenu("View") {
                Button("Overview") {
                    state.selectedSection = .overview
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Shaders") {
                    state.selectedSection = .shaders
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Logs") {
                    state.selectedSection = .logs
                }
                .keyboardShortcut("3", modifiers: .command)

                Divider()

                Button("Refresh Status") {
                    Task { await state.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isBusy)

                Button("Copy Diagnostics") {
                    state.copyDiagnostics()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }
}
