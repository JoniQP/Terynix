import SwiftUI

/// Design tokens for Virtual PC. The palette is deliberately a "systems
/// tool" one — a cool blue-charcoal chrome for the app itself, and an
/// authentic green-phosphor monospace treatment reserved specifically
/// for the simulated BIOS/bootloader and CPU-monitor screens, where it's
/// evoking a real referent (old firmware/terminal text) rather than
/// decorating for its own sake.
enum VPCTheme {
    static let accent = Color(red: 0.31, green: 0.49, blue: 0.95)        // indigo-blue, primary actions
    static let accentSecondary = Color(red: 0.24, green: 0.78, blue: 0.76) // teal, "active" accents

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.047, green: 0.059, blue: 0.082)   // #0C0F15
            : Color(red: 0.96, green: 0.965, blue: 0.975)
    }

    static func surfaceElevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.102, green: 0.118, blue: 0.153)   // #1A1E27
            : Color.white
    }

    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.88)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5)
    }

    static func stateColor(_ state: VMRuntimeState) -> Color {
        switch state {
        case .running: return Color(red: 0.30, green: 0.78, blue: 0.47)
        case .paused: return Color(red: 0.95, green: 0.70, blue: 0.20)
        case .starting: return accentSecondary
        case .stopped: return Color.gray
        }
    }

    static func supportBadge(_ level: EmulationSupportLevel) -> Color {
        switch level {
        case .demoOnly: return accent
        case .untested: return Color(red: 0.95, green: 0.70, blue: 0.20)
        case .unsupported: return Color(red: 0.86, green: 0.30, blue: 0.30)
        }
    }
}

/// A single reusable card treatment: a slightly elevated surface with a
/// hairline border, rather than a drop shadow, so cards read as physical
/// panels appropriate to a "hardware" dashboard.
private struct VPCCardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(VPCTheme.surfaceElevated(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func vpcCard() -> some View {
        modifier(VPCCardBackground())
    }
}
