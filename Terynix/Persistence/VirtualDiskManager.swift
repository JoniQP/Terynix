import Foundation

enum VirtualDiskError: LocalizedError {
    case insufficientSpace(availableBytes: Int64)
    case creationFailed(String)

    var errorDescription: String? {
        switch self {
        case .insufficientSpace(let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Only \(formatter.string(fromByteCount: available)) is free on this iPad, which isn't enough to create this disk."
        case .creationFailed(let reason):
            return "Could not create the virtual disk: \(reason)"
        }
    }
}

/// Creates and manages virtual hard disk files on local, sandboxed storage.
///
/// Disks are created as *sparse* files: a disk declared as 64 GB does not
/// consume 64 GB on the iPad immediately. Only the bytes actually written
/// take up real space, exactly like VirtualBox's "dynamically allocated"
/// disk format or QEMU's qcow2. `declaredMaximumBytes` reports the
/// configured ceiling; `actualAllocatedBytes` reports real consumption.
final class VirtualDiskManager {
    static let shared = VirtualDiskManager()
    private let fileManager = FileManager.default

    private init() {}

    var disksDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("VirtualPC/Disks", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func url(for fileName: String) -> URL {
        disksDirectory.appendingPathComponent(fileName)
    }

    /// Creates a sparse placeholder file for a disk's maximum size. This is
    /// a single seek-and-write-one-byte operation regardless of the
    /// declared size, so it's safe to call synchronously.
    func createDisk(fileName: String, maximumSizeGB: Int) throws {
        let maxBytes = Int64(maximumSizeGB) * 1_073_741_824
        let minimumHeadroom: Int64 = 100 * 1_048_576 // 100 MB

        let available = availableDeviceBytes()
        guard available > minimumHeadroom else {
            throw VirtualDiskError.insufficientSpace(availableBytes: available)
        }

        let url = url(for: fileName)
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw VirtualDiskError.creationFailed("The disk file could not be created.")
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            if maxBytes > 0 {
                try handle.seek(toOffset: UInt64(maxBytes - 1))
                try handle.write(contentsOf: Data([0]))
            }
        } catch {
            try? fileManager.removeItem(at: url)
            throw VirtualDiskError.creationFailed(error.localizedDescription)
        }
    }

    func deleteDisk(fileName: String) throws {
        let url = url(for: fileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Copies a VM's virtual disk file out to a real destination, for
    /// the Files app or anywhere else via the share sheet. Uses
    /// `copyItem` directly rather than the chunked streaming approach
    /// used for ISO file export: this disk has only ever been created
    /// as a sparse placeholder (nothing in the app writes real guest
    /// data to it today — see the README), and `copyItem` preserves a
    /// sparse file's sparseness on APFS rather than inflating it to its
    /// full declared size, so this stays cheap regardless of how large a
    /// disk was configured to be.
    func exportDisk(fileName: String, to destinationURL: URL) throws {
        let sourceURL = url(for: fileName)
        try? fileManager.removeItem(at: destinationURL) // clear any leftover from a previous export
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    /// The disk's configured maximum size, in bytes.
    func declaredMaximumBytes(fileName: String) -> Int64 {
        let url = url(for: fileName)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    /// The real, on-device storage the disk file currently consumes.
    func actualAllocatedBytes(fileName: String) -> Int64 {
        let url = url(for: fileName)
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let allocated = values.totalFileAllocatedSize else {
            return 0
        }
        return Int64(allocated)
    }

    func availableDeviceBytes() -> Int64 {
        guard let values = try? disksDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return available
    }
}
