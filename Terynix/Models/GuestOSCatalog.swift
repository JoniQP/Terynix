import Foundation

/// How far Virtual PC's *real* emulation support goes for a given guest OS
/// profile. Virtual PC does include a real x86 real-mode interpreter
/// (`X86CPU`) that genuinely executes an attached disc's boot sector when
/// one validates — see the README for exactly what it covers. What a
/// *profile* controls is narrower than that: only which firmware/
/// bootloader flavor text is shown. No profile here claims full OS
/// support, since nothing in this app can carry a boot chain past real
/// mode into an actual running operating system.
enum EmulationSupportLevel: String, Codable {
    case demoOnly = "Demo Simulation"
    case untested = "Untested"
    case unsupported = "Unsupported"

    var explanation: String {
        switch self {
        case .demoOnly:
            return "This profile only selects the firmware/bootloader flavor text shown at startup — it doesn't decide whether real execution happens. If the attached disc has a valid boot sector, Virtual PC's x86 interpreter genuinely runs it (see the README for what it covers); otherwise the screen falls back to an illustrative demo CPU. Either way, no full operating system runs."
        case .untested:
            return "This profile's flavor text hasn't been checked for accuracy yet, and may not match what a real bootloader for this OS actually prints."
        case .unsupported:
            return "This profile needs capabilities (such as GPU passthrough) that cannot be provided here."
        }
    }
}

/// A selectable guest OS "personality". Selecting one does not install or
/// run that operating system — see `EmulationSupportLevel`. It only
/// determines which boot-splash flavor text the demo firmware/bootloader
/// screens show, so the demo at least looks like the kind of machine the
/// user picked.
struct GuestOSProfile: Identifiable, Hashable {
    let id: String
    let displayName: String
    let family: String
    let supportLevel: EmulationSupportLevel
    let bootSplashLines: [String]
}

enum GuestOSCatalog {
    static let profiles: [GuestOSProfile] = [
        GuestOSProfile(
            id: "linux-generic",
            displayName: "Linux (generic)",
            family: "Linux",
            supportLevel: .demoOnly,
            bootSplashLines: [
                "GRUB loading stage2...",
                "Loading Linux kernel...",
                "Mounting root filesystem..."
            ]
        ),
        GuestOSProfile(
            id: "dos-generic",
            displayName: "DOS-compatible",
            family: "DOS",
            supportLevel: .demoOnly,
            bootSplashLines: [
                "Starting MS-DOS...",
                "HIMEM is testing extended memory... done."
            ]
        ),
        GuestOSProfile(
            id: "bsd-generic",
            displayName: "BSD (generic)",
            family: "BSD",
            supportLevel: .demoOnly,
            bootSplashLines: [
                "Booting BSD kernel...",
                "Probing devices..."
            ]
        ),
        GuestOSProfile(
            id: "windows-generic",
            displayName: "Windows-compatible",
            family: "Windows",
            supportLevel: .untested,
            bootSplashLines: [
                "Starting Windows...",
                "Loading drivers..."
            ]
        ),
        GuestOSProfile(
            id: "other-custom",
            displayName: "Other / Custom ISO",
            family: "Other",
            supportLevel: .untested,
            bootSplashLines: [
                "Reading boot sector...",
                "Handing off to bootloader..."
            ]
        )
    ]

    static func profile(for id: String) -> GuestOSProfile {
        profiles.first { $0.id == id } ?? profiles[0]
    }

    /// Family names in the order they first appear in `profiles`, each
    /// listed once — derived from that single source of truth rather
    /// than a separately-maintained list that could drift out of sync
    /// with it as profiles are added or reordered.
    static let familiesInOrder: [String] = {
        var seen = Set<String>()
        var ordered: [String] = []
        for profile in profiles where !seen.contains(profile.family) {
            seen.insert(profile.family)
            ordered.append(profile.family)
        }
        return ordered
    }()
}
