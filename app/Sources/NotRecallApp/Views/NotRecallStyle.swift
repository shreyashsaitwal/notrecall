import AppKit
import SwiftUI

// MARK: - NotRecall Visual System (Native macOS + Cobalt Identity)

enum NotRecallTheme {
    static let brand = Color(red: 0.16, green: 0.48, blue: 0.96)
    static let brandDeep = Color(red: 0.11, green: 0.36, blue: 0.82)
    static let healthy = Color(red: 0.18, green: 0.72, blue: 0.44)
    static let warning = Color(red: 0.92, green: 0.56, blue: 0.12)
    static let critical = Color(red: 0.88, green: 0.24, blue: 0.24)

    static let cardRadius: CGFloat = 14
    static let innerRadius: CGFloat = 10

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(red: 0.962, green: 0.966, blue: 0.975)
    }

    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.055)
            : Color.white
    }

    static func subtleFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.04)
            : Color.black.opacity(0.03)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.08)
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - Motion Curves

extension Animation {
    static func strongEaseOut(duration: Double = 0.2) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}

// MARK: - Brand Mark

struct NotRecallEmblem: View {
    var size: CGFloat = 28

    private static let bundledIcon: NSImage? = {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
    }()

    var body: some View {
        Group {
            if let bundledIcon = Self.bundledIcon {
                Image(nsImage: bundledIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [NotRecallTheme.brand, NotRecallTheme.brandDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Card Container

struct SurfaceCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotRecallTheme.cardRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotRecallTheme.cardFill(scheme), in: shape)
            .overlay {
                shape.strokeBorder(NotRecallTheme.border(scheme), lineWidth: 1)
            }
            .shadow(color: scheme == .dark ? .clear : .black.opacity(0.03), radius: 6, y: 2)
    }
}

// MARK: - Section Header

struct CardHeader: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(NotRecallTheme.font(13.5, .semibold))
                    .foregroundStyle(.primary)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(NotRecallTheme.font(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Status Badges & Banners

struct StatusTag: View {
    let text: String
    let color: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(text)
                .font(NotRecallTheme.font(11, .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct InlineBanner<Accessory: View>: View {
    let symbol: String
    let title: String
    let message: String
    let tint: Color
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotRecallTheme.innerRadius, style: .continuous)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NotRecallTheme.font(13, .semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(NotRecallTheme.font(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(tint.opacity(0.09), in: shape)
        .overlay {
            shape.strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }
}

extension InlineBanner where Accessory == EmptyView {
    init(symbol: String, title: String, message: String, tint: Color) {
        self.init(symbol: symbol, title: title, message: message, tint: tint) { EmptyView() }
    }
}

// MARK: - Progress Bar

struct SmoothProgressBar: View {
    let fraction: Double
    var tint: Color = NotRecallTheme.brand

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { proxy in
            Capsule()
                .fill(.primary.opacity(0.10))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(clamped > 0 ? 6 : 0, proxy.size.width * clamped))
                }
        }
        .frame(height: 6)
    }
}

// MARK: - Tactile Native Button Styles

struct BrandButtonStyle: ButtonStyle {
    var fill: Color = NotRecallTheme.brand
    var compact: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
        configuration.label
            .font(NotRecallTheme.font(compact ? 12.5 : 13.5, .semibold))
            .padding(.horizontal, compact ? 11 : 16)
            .padding(.vertical, compact ? 5.5 : 8.5)
            .foregroundStyle(isEnabled ? .white : .secondary)
            .background(isEnabled ? fill : Color.secondary.opacity(0.16), in: shape)
            .overlay {
                shape.strokeBorder(isFocused ? Color.white.opacity(0.7) : .clear, lineWidth: 1.5)
                    .padding(1.5)
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .strongEaseOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SubtleButtonStyle: ButtonStyle {
    var destructive: Bool = false
    var compact: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
        configuration.label
            .font(NotRecallTheme.font(compact ? 12 : 13, .medium))
            .padding(.horizontal, compact ? 10 : 13)
            .padding(.vertical, compact ? 5 : 7.5)
            .foregroundStyle(
                !isEnabled
                    ? AnyShapeStyle(.tertiary)
                    : (destructive ? AnyShapeStyle(NotRecallTheme.critical) : AnyShapeStyle(.primary))
            )
            .background(
                NotRecallTheme.subtleFill(scheme).opacity(configuration.isPressed ? 1.8 : 1.0),
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    destructive ? NotRecallTheme.critical.opacity(0.28) : NotRecallTheme.border(scheme),
                    lineWidth: 1
                )
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .strongEaseOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Action Row

struct ControlRow: View {
    let title: String
    let detail: String
    let buttonTitle: String
    var destructive: Bool = false
    var disabled: Bool = false
    let action: () -> Void

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
            Spacer(minLength: 8)
            Button(buttonTitle, action: action)
                .buttonStyle(SubtleButtonStyle(destructive: destructive, compact: true))
                .disabled(disabled)
        }
    }
}

// MARK: - Checklist Line

struct StackStatusRow: View {
    let title: String
    let detail: String
    let ok: Bool
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(ok ? NotRecallTheme.healthy : NotRecallTheme.warning)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(NotRecallTheme.font(13, .medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(NotRecallTheme.font(11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SubtleButtonStyle(compact: true))
            }
        }
    }
}
