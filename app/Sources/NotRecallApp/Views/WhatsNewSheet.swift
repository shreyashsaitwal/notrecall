import AppKit
import SwiftUI

struct ReleaseNoteLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case spacer
        case heading2(String)
        case heading3(String)
        case body(String)
    }

    let id: String
    let kind: Kind

    static func parse(_ markdown: String) -> [ReleaseNoteLine] {
        markdown.components(separatedBy: "\n").enumerated().map { idx, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let kind: Kind
            if trimmed.isEmpty {
                kind = .spacer
            } else if trimmed.hasPrefix("## ") {
                kind = .heading2(String(trimmed.dropFirst(3)))
            } else if trimmed.hasPrefix("### ") {
                kind = .heading3(String(trimmed.dropFirst(4)))
            } else {
                kind = .body(trimmed)
            }
            return ReleaseNoteLine(id: "rn-\(idx)", kind: kind)
        }
    }
}

struct WhatsNewSheet: View {
    let release: RecallReleaseInfo
    let installedVersion: String?
    let isBusy: Bool
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var lines: [ReleaseNoteLine] {
        ReleaseNoteLine.parse(release.whatsNewMarkdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                NotRecallEmblem(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("What’s New in \(release.title)")
                        .font(NotRecallTheme.font(18, .bold))
                        .tracking(-0.3)
                    Text(metadataSubtitle)
                        .font(NotRecallTheme.font(12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("View on GitHub") {
                    NSWorkspace.shared.open(release.releasePageURL)
                }
                .buttonStyle(SubtleButtonStyle(compact: true))
            }

            SurfaceCard(padding: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(lines) { line in
                            ReleaseNoteRow(kind: line.kind)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(minHeight: 220, maxHeight: 340)
            }

            HStack(spacing: 12) {
                Text("Downloads \(release.dmgName), verifies checksum, and updates your runtime. Games and settings stay untouched.")
                    .font(NotRecallTheme.font(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Not Now", action: onDismiss)
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Update to \(release.version)", action: onUpdate)
                    .buttonStyle(BrandButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(NotRecallTheme.canvas(scheme))
    }

    private var metadataSubtitle: String {
        var parts: [String] = []
        if let installed = installedVersion {
            parts.append("Installed: \(installed)")
        }
        if let size = release.formattedSize {
            parts.append("Download: \(size)")
        }
        if let minOS = release.minimumMacOS {
            parts.append("Requires macOS \(minOS)+")
        }
        return parts.joined(separator: " · ")
    }
}

struct ReleaseNoteRow: View {
    let kind: ReleaseNoteLine.Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch kind {
            case .spacer:
                Spacer().frame(height: 2)
            case .heading2(let text):
                Text(text)
                    .font(NotRecallTheme.font(14.5, .semibold))
                    .padding(.top, 5)
            case .heading3(let text):
                Text(text)
                    .font(NotRecallTheme.font(13, .semibold))
                    .padding(.top, 3)
            case .body(let text):
                if let attributed = try? AttributedString(markdown: text) {
                    Text(attributed)
                        .font(NotRecallTheme.font(12.5))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(text)
                        .font(NotRecallTheme.font(12.5))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
