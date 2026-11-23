import AppKit
import SwiftUI

/// The visual language of the app: layered surfaces, soft gradients, one light
/// source at the top, shadows that fall down. Nothing here is decorative for its
/// own sake — depth is used to group controls and to show state.
enum Theme {
    static let accentStart = Color(red: 0.50, green: 0.57, blue: 1.00)
    static let accentEnd = Color(red: 0.34, green: 0.40, blue: 0.97)
    static let accent = Color(red: 0.42, green: 0.48, blue: 0.98)

    static let dangerStart = Color(red: 1.00, green: 0.45, blue: 0.47)
    static let dangerEnd = Color(red: 0.95, green: 0.24, blue: 0.36)
    static let danger = Color(red: 0.98, green: 0.32, blue: 0.40)

    static let success = Color(red: 0.30, green: 0.82, blue: 0.55)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.30)

    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 10

    // MARK: Surfaces

    static func windowBackground(_ scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color(red: 0.075, green: 0.078, blue: 0.095),
                         Color(red: 0.045, green: 0.047, blue: 0.060)],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.965, green: 0.970, blue: 0.985),
                     Color(red: 0.925, green: 0.933, blue: 0.958)],
            startPoint: .top, endPoint: .bottom
        )
    }

    static func cardFill(_ scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color.white.opacity(0.085), Color.white.opacity(0.028)],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color.white.opacity(0.98), Color.white.opacity(0.72)],
            startPoint: .top, endPoint: .bottom
        )
    }

    static func cardStroke(_ scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color.white.opacity(0.18), Color.white.opacity(0.03)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.white.opacity(0.95), Color.black.opacity(0.05)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static func shadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.45) : Color(red: 0.35, green: 0.40, blue: 0.55).opacity(0.20)
    }

    static func trackFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.22) : Color.black.opacity(0.055)
    }

    static func selectionFill(_ scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color.white.opacity(0.22), Color.white.opacity(0.10)],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color.white, Color.white.opacity(0.85)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - Window

struct SoftWindowBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.windowBackground(scheme)

            Circle()
                .fill(Theme.accent.opacity(scheme == .dark ? 0.16 : 0.10))
                .frame(width: 420, height: 420)
                .blur(radius: 140)
                .offset(x: -200, y: -240)

            Circle()
                .fill(Color(red: 0.62, green: 0.36, blue: 1.0).opacity(scheme == .dark ? 0.12 : 0.07))
                .frame(width: 380, height: 380)
                .blur(radius: 140)
                .offset(x: 220, y: 260)
        }
        .ignoresSafeArea()
    }
}

/// Makes the host window translucent so the material surfaces read as glass.
/// Applied once per window.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        GlassReaderView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class GlassReaderView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.styleMask.remove(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}

extension View {
    /// Full-height content with the traffic lights floating over it.
    func glassWindow() -> some View {
        self
            .background(WindowGlass())
            .background(SoftWindowBackground())
    }
}

// MARK: - Card

struct SoftCard<Content: View>: View {
    let title: String?
    let systemImage: String?
    private let content: Content

    @Environment(\.colorScheme) private var scheme

    init(title: String? = nil,
         systemImage: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 7) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(LocalizedStringKey(title))
                        .textCase(.uppercase)
                        .font(.system(size: 11.5, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                shape
                    .fill(Theme.cardFill(scheme))
                    .overlay(shape.stroke(Theme.cardStroke(scheme), lineWidth: 1))
                    .shadow(color: Theme.shadow(scheme), radius: 16, x: 0, y: 8)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.05), radius: 2, x: 0, y: 1)
            }
        }
    }
}

struct SoftRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    private let control: Control

    init(_ title: String,
         subtitle: String? = nil,
         icon: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 14))
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            control
        }
        .padding(.vertical, 5)
    }
}

struct SoftDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 30)
    }
}

// MARK: - Segmented control

struct SoftSegmented<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    @Namespace private var namespace
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items, id: \.self) { item in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        selection = item
                    }
                } label: {
                    Text(LocalizedStringKey(title(item)))
                        .font(.system(size: 12, weight: selection == item ? .semibold : .medium))
                        .foregroundStyle(selection == item ? Color.primary : Color.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background {
                            if selection == item {
                                Capsule(style: .continuous)
                                    .fill(Theme.selectionFill(scheme))
                                    .overlay(Capsule().stroke(Color.white.opacity(scheme == .dark ? 0.14 : 0.9), lineWidth: 0.8))
                                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 4, x: 0, y: 2)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(4)
        .background {
            Capsule()
                .fill(Theme.trackFill(scheme))
                .overlay(Capsule().stroke(Color.white.opacity(scheme == .dark ? 0.06 : 0.5), lineWidth: 0.8))
        }
    }
}

// MARK: - Buttons

struct SoftButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        SoftButtonBody(configuration: configuration, destructive: destructive, scheme: scheme)
    }

    private struct SoftButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let destructive: Bool
        let scheme: ColorScheme

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive ? Theme.danger : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    shape
                        .fill(Theme.cardFill(scheme))
                        .overlay(shape.stroke(Theme.cardStroke(scheme), lineWidth: 1))
                        .shadow(color: Theme.shadow(scheme).opacity(0.7), radius: 5, x: 0, y: 2)
                }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .brightness(configuration.isPressed ? -0.04 : 0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

struct SoftProminentButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        SoftProminentBody(configuration: configuration, scheme: scheme)
    }

    private struct SoftProminentBody: View {
        let configuration: ButtonStyleConfiguration
        let scheme: ColorScheme

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background {
                    shape
                        .fill(LinearGradient(colors: [Theme.accentStart, Theme.accentEnd],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(shape.stroke(Color.white.opacity(0.25), lineWidth: 0.8))
                        .shadow(color: Theme.accent.opacity(scheme == .dark ? 0.45 : 0.35),
                                radius: 8, x: 0, y: 3)
                }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .brightness(configuration.isPressed ? -0.06 : 0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

// MARK: - Small pieces

struct StatusDot: View {
    let ok: Bool

    var body: some View {
        Circle()
            .fill(ok ? Theme.success : Theme.danger)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.7))
            .shadow(color: (ok ? Theme.success : Theme.danger).opacity(0.6), radius: 4)
    }
}

struct SoftChip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(tint.opacity(0.10))
                    .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 0.7))
            )
    }
}
