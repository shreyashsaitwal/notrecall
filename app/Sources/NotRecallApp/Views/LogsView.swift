import SwiftUI

struct LogsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                SurfaceCard(padding: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        CardHeader(
                            title: "Session Log",
                            subtitle: state.recentLogTitle.isEmpty
                                ? "Most recent NotRecall launch log or script output."
                                : state.recentLogTitle,
                            symbol: "terminal"
                        )
                        Spacer()
                        Button {
                            state.copyDiagnostics()
                        } label: {
                            Label(
                                state.diagnosticsCopied ? "Copied" : "Copy Diagnostics",
                                systemImage: state.diagnosticsCopied ? "checkmark" : "doc.on.clipboard"
                            )
                            .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(BrandButtonStyle(compact: true))

                        Button("Reload") {
                            Task { await state.refresh() }
                        }
                        .buttonStyle(SubtleButtonStyle(compact: true))
                        .disabled(state.isBusy)
                    }
                }

                SurfaceCard(padding: 14) {
                    ScrollView {
                        Text(state.recentLogText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
            .padding(20)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
    }
}
