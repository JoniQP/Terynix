import Foundation
import CoreGraphics

/// The lifecycle state of a virtual machine, as persisted in the library.
/// This mirrors what the dashboard shows, and is kept in sync with
/// `VMSessionViewModel.SessionPhase` while a session is open.
enum VMRuntimeState: String, Codable {
    case stopped
    case starting
    case running
    case paused
}

/// Network configuration for a VM. Virtual PC does not implement a real
/// guest networking stack (there is no real guest OS to attach one to),
/// so this models the *setting* a user would configure, not a live
/// network connection. See `helpText`.
enum NetworkMode: String, Codable, CaseIterable, Identifiable {
    case disabled = "Disabled"
    case natSimulated = "NAT (Simulated)"

    var id: String { rawValue }

    var helpText: String {
        switch self {
        case .disabled:
            return "The virtual machine has no network access."
        case .natSimulated:
            return "Reserved for a future real networking stack. In Demo Mode no actual network traffic is sent or received."
        }
    }
}

/// A device Virtual PC can boot from, used to build a boot order list.
enum BootDevice: String, Codable, CaseIterable, Identifiable {
    case opticalDrive = "Optical Drive (ISO)"
    case hardDisk = "Hard Disk"

    var id: String { rawValue }
}

/// Display resolutions offered when configuring a VM's virtual monitor.
enum DisplayResolution: String, Codable, CaseIterable, Identifiable {
    case r800x600
    case r1024x768
    case r1280x720
    case r1920x1080

    var id: String { rawValue }

    var label: String {
        switch self {
        case .r800x600: return "800 × 600"
        case .r1024x768: return "1024 × 768"
        case .r1280x720: return "1280 × 720 (HD)"
        case .r1920x1080: return "1920 × 1080 (Full HD)"
        }
    }

    /// Used to letterbox the session screen's monitor area to the right
    /// aspect ratio for the chosen resolution.
    var pixelSize: CGSize {
        switch self {
        case .r800x600: return CGSize(width: 800, height: 600)
        case .r1024x768: return CGSize(width: 1024, height: 768)
        case .r1280x720: return CGSize(width: 1280, height: 720)
        case .r1920x1080: return CGSize(width: 1920, height: 1080)
        }
    }
}

/// A user-configured virtual machine. This struct only ever holds
/// configuration — it never represents an actually-running process.
/// Runtime/session state lives in `VMSessionViewModel`.
struct VirtualMachine: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var osProfileID: String
    var ramMB: Int
    var cpuCoreCount: Int
    var diskMaxSizeGB: Int
    let diskFileName: String
    var displayResolution: DisplayResolution
    var networkMode: NetworkMode
    var bootOrder: [BootDevice]
    var attachedISOID: UUID?
    let createdAt: Date
    var lastStartedAt: Date?
    var runtimeState: VMRuntimeState

    // MARK: Sane, honest bounds.
    // These are app-level ceilings, independent of what any emulation
    // engine could actually use — see GuestOSCatalog and the README for
    // why no profile is backed by real hardware partitioning today.
    static let ramRangeMB = 512...8192
    static let cpuCoreRange = 1...8
    static let diskRangeGB = 1...256

    /// The most cores Virtual PC will ever let a VM "claim", clamped to
    /// what this iPad actually reports. The demo engine itself always
    /// runs on a single thread regardless of this setting — see
    /// `DemoPCEngine` — so this bound exists purely so the UI never
    /// implies more hardware than the device has.
    static func maxSelectableCores(deviceCores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        min(cpuCoreRange.upperBound, max(cpuCoreRange.lowerBound, deviceCores))
    }

    init(
        name: String,
        osProfileID: String,
        ramMB: Int = 2048,
        cpuCoreCount: Int = 2,
        diskMaxSizeGB: Int = 16,
        displayResolution: DisplayResolution = .r1024x768,
        networkMode: NetworkMode = .disabled,
        bootOrder: [BootDevice] = [.opticalDrive, .hardDisk]
    ) {
        let generatedID = UUID()
        self.id = generatedID
        self.name = name
        self.osProfileID = osProfileID
        self.ramMB = ramMB
        self.cpuCoreCount = cpuCoreCount
        self.diskMaxSizeGB = diskMaxSizeGB
        self.diskFileName = "\(generatedID.uuidString).vpcdisk"
        self.displayResolution = displayResolution
        self.networkMode = networkMode
        self.bootOrder = bootOrder
        self.attachedISOID = nil
        self.createdAt = Date()
        self.lastStartedAt = nil
        self.runtimeState = .stopped
    }
}
