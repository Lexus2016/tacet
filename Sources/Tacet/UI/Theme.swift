import AppKit
import SwiftUI

/// The visual language of the app: layered surfaces, soft gradients, one light
/// source at the top, shadows that fall down. Nothing here is decorative for its
/// own sake — depth is used to group controls and to show state.
enum Theme {
    static let accentStart = Color(red: 0.17, green: 0.55, blue: 0.81)
    static let accentEnd = Color(red: 0.08, green: 0.33, blue: 0.67)
    static let accent = Color(red: 0.20, green: 0.48, blue: 0.82)

    static let dangerStart = Color(red: 1.00, green: 0.45, blue: 0.47)
    static let dangerEnd = Color(red: 0.95, green: 0.24, blue: 0.36)
    static let danger = Color(red: 0.98, green: 0.32, blue: 0.40)

    static let success = Color(red: 0.30, green: 0.82, blue: 0.55)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.30)

    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 8
    static let settingsControlWidth: CGFloat = 176

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


}

// MARK: - Window

struct SoftWindowBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Theme.windowBackground(scheme)
            .ignoresSafeArea()
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
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
                    .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.06), radius: 5, x: 0, y: 2)
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
    }
}

struct SettingsPicker: View {
    struct Option: Equatable {
        let id: String
        let title: String

        init(_ id: String, _ title: String) {
            self.id = id
            self.title = NSLocalizedString(title, comment: "")
        }

        init(_ id: String, name: String) {
            self.id = id
            self.title = name
        }
    }

    let title: String
    @Binding var selection: String
    let options: [Option]
    var width = Theme.settingsControlWidth

    var body: some View {
        SettingsPopUp(title: title, selection: $selection, options: options)
            .frame(width: width, height: 27)
    }
}

private struct SettingsPopUp: NSViewRepresentable {
    let title: String
    @Binding var selection: String
    let options: [SettingsPicker.Option]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.bezelStyle = .rounded
        control.font = .systemFont(ofSize: 12)
        control.cell?.lineBreakMode = .byTruncatingTail
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(NSLocalizedString(title, comment: ""))
        control.target = context.coordinator
        control.action = #selector(Coordinator.select(_:))
        return control
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ control: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection

        let entries = options.contains { $0.id == selection } ? options :
            [SettingsPicker.Option(selection, title)] + options
        if coordinator.options != entries {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for option in entries {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.id
                item.isEnabled = options.contains { $0.id == option.id }
                menu.addItem(item)
            }
            control.menu = menu
            coordinator.options = entries
        }
        if let index = entries.firstIndex(where: { $0.id == selection }),
           control.indexOfSelectedItem != index {
            control.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>
        var options: [SettingsPicker.Option]?

        init(selection: Binding<String>) { self.selection = selection }

        @objc func select(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            selection.wrappedValue = value
        }
    }
}

struct PendingActionLabel: View {
    let title: LocalizedStringKey
    let pendingTitle: LocalizedStringKey
    let isPending: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(isPending ? pendingTitle : title)
        }
        .accessibilityElement(children: .combine)
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
