import SwiftUI

struct ImportFromRecallSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var inspection: RecallInspection? { state.recallInspection }

    private var effectiveOptions: RecallImportOptions {
        guard let info = inspection else {
            return RecallImportOptions(
                importShaders: false,
                importSettings: false,
                importHighlights: false,
                importCustomDXMT: false,
                queueShaderRebuild: true
            )
        }
        return RecallImportOptions(
            importShaders: state.recallImportOptions.importShaders && info.hasShaderCache,
            importSettings: state.recallImportOptions.importSettings && info.settingsINIURL != nil,
            importHighlights: state.recallImportOptions.importHighlights && info.highlightFileCount > 0,
            importCustomDXMT: state.recallImportOptions.importCustomDXMT && info.customDXMTLines != nil,
            queueShaderRebuild: true
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                CardHeader(
                    title: "Import from Recall",
                    subtitle: "Bring your existing Overwatch shaders, settings, and highlights into Steam.",
                    symbol: "square.and.arrow.down"
                )
                Spacer()
            }

            SurfaceCard(padding: 13) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: (inspection?.isValidRecallFolder == true) ? "checkmark.circle.fill" : "folder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle((inspection?.isValidRecallFolder == true) ? NotRecallTheme.healthy : NotRecallTheme.warning)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recall Data Folder")
                            .font(NotRecallTheme.font(12.5, .semibold))
                        Text(inspection?.rootURL.path ?? "~/Library/Application Support/Overwatch2Mac")
                            .font(NotRecallTheme.font(11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    Button("Choose Folder…") {
                        state.selectRecallFolder()
                    }
                    .buttonStyle(SubtleButtonStyle(compact: true))
                    .disabled(state.isBusy)
                }
            }

            if let info = inspection, info.isValidRecallFolder {
                SurfaceCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        ImportOptionRow(
                            isOn: $state.recallImportOptions.importShaders,
                            enabled: info.hasShaderCache,
                            title: "Learned Shaders & Pipeline Cache",
                            detail: info.hasShaderCache
                                ? "\(info.formattedShaderSize) · \(info.shaderArchiveCount) \(info.shaderArchiveCount == 1 ? "pack" : "packs"). Queues a rebuild so recipes recompile for NotRecall’s DXMT."
                                : "No shader cache found in this Recall folder."
                        )

                        Divider()

                        ImportOptionRow(
                            isOn: $state.recallImportOptions.importSettings,
                            enabled: info.settingsINIURL != nil,
                            title: "Overwatch Video & In-Game Settings",
                            detail: info.settingsINIURL != nil
                                ? "Copies Settings_v0.ini into Steam’s Overwatch prefix (backs up any existing file)."
                                : "No Settings_v0.ini found in Recall’s Wine prefix."
                        )

                        Divider()

                        ImportOptionRow(
                            isOn: $state.recallImportOptions.importHighlights,
                            enabled: info.highlightFileCount > 0,
                            title: "Saved Highlights",
                            detail: info.highlightFileCount > 0
                                ? "\(info.highlightFileCount) \(info.highlightFileCount == 1 ? "clip" : "clips") will be copied into ~/Movies/Overwatch."
                                : (info.highlightsAlreadyInMovies
                                    ? "Already linked to ~/Movies/Overwatch — NotRecall shares that folder automatically."
                                    : "No highlight clips found inside Recall’s Wine prefix.")
                        )

                        if info.customDXMTLines != nil {
                            Divider()

                            ImportOptionRow(
                                isOn: $state.recallImportOptions.importCustomDXMT,
                                enabled: true,
                                title: "Custom dxmt.conf Settings",
                                detail: "Appends Recall’s custom renderer lines to compatdata/2357570/dxmt.conf."
                            )
                        }
                    }
                }
            } else {
                SurfaceCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recall Installation Not Found")
                            .font(NotRecallTheme.font(13, .semibold))
                        Text("No Recall data folder was found at the default location. If you installed Recall on an external drive or another folder, click Choose Folder… and select its Overwatch2Mac directory.")
                            .font(NotRecallTheme.font(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(SubtleButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button("Import Selected") {
                    let opts = effectiveOptions
                    Task {
                        await state.importFromRecall(options: opts)
                        dismiss()
                    }
                }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(state.isBusy || !(inspection?.isValidRecallFolder ?? false) || !effectiveOptions.hasSelection)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 500)
    }
}

private struct ImportOptionRow: View {
    @Binding var isOn: Bool
    let enabled: Bool
    let title: String
    let detail: String

    var body: some View {
        Toggle(isOn: enabled ? $isOn : .constant(false)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NotRecallTheme.font(13, .medium))
                    .foregroundStyle(enabled ? .primary : .secondary)
                Text(detail)
                    .font(NotRecallTheme.font(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled)
    }
}
