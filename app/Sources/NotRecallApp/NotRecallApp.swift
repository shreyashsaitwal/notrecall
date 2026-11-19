import SwiftUI

@main
struct NotRecallApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("NotRecall") {
            ContentView(state: state)
                .frame(minWidth: 640, minHeight: 460)
                .task { await state.refresh() }
        }
        .windowResizability(.contentMinSize)
    }
}
