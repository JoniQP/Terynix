import Foundation

// MARK: - What this file is, and isn't
//
// Real, standards-based inspection of an ISO 9660 image's boot
// structures: the Primary Volume Descriptor, the El Torito boot catalog
// (if present), and the first bytes of whatever boot image that catalog
// points to — including the same 0x55AA boot-signature check a real BIOS
// performs before handing off control to a boot sector.
//
// This reads and validates real bytes from the real ISO file on disk.
// It does NOT execute any of them. Nothing here boots or interprets
// x86/ARM machine code — see DemoPCEngine for what the session screen
// actually runs after this. This file is the step before that: honestly
// confirming what a real engine would need to load, and from where,
// without pretending to be the engine itself.
//
// Scope: this follows the overwhelming real-world convention that the
// Primary Volume Descriptor sits at logical sector 16 and, when present,
// the El Torito Boot Record sits in the volume descriptor set starting
// at sector 17 — true of every mainstream authoring tool (mkisofs,
// genisoimage, xorriso, Disk Utility). It does not attempt a fully
// general, order-independent parse of the ISO 9660 spec.

private let isoLogicalSectorSize = 2048

enum ElToritoPlatform: UInt8, Sendable {
    case x86 = 0x00
    case powerPC = 0x01
    case mac = 0x02
    case efi = 0xEF

    var description: String {
        switch self {
        case .x86: return "x86"
        case .powerPC: return "PowerPC"
        case .mac: return "Mac"
        case .efi: return "UEFI"
        }
    }
}

struct ElToritoBootEntry: Sendable {
    let platform: ElToritoPlatform?
    let rawPlatformID: UInt8
    let catalogSignatureValid: Bool
    let bootImageLBA: UInt32
    let sectorCountField: UInt16
    let bootImageSignatureValid: Bool
    /// The real 512 bytes read from `bootImageLBA`, already validated above —
    /// what a CPU loading this boot sector would load, verbatim.
    let bootImageBytes: [UInt8]

    var platformDescription: String {
        platform?.description ?? "Unknown (0x\(String(format: "%02X", rawPlatformID)))"
    }
}

/// Which addressing convention a boot path implies for subsequent disk
/// reads — El Torito addresses the ISO in its native 2048-byte CD
/// sectors, while a hybrid-MBR boot treats the file as a raw block
/// device with classic 512-byte sectors. `X86BIOSServices` needs to know
/// which one applies to correctly service `INT 13h` reads afterward.
enum BootSectorConvention: Sendable {
    case elTorito(lba: UInt32)
    case hybridMBR
}

struct ISOBootInspectionResult: Sendable {
    let isValidISO9660: Bool
    let volumeLabel: String?
    let hybridMBRSignatureValid: Bool
    /// The real 512 bytes read from file offset 0, regardless of whether
    /// they turned out to be a valid MBR — so a caller can load them
    /// without a second read.
    let hybridMBRBytes: [UInt8]
    let elTorito: ElToritoBootEntry?
    let log: [String]

    var isBootable: Bool {
        (elTorito?.bootImageSignatureValid ?? false) || hybridMBRSignatureValid
    }

    /// What a CPU should actually load to execute this disc's boot
    /// sector, and which sector-size convention governs further reads —
    /// nil if nothing bootable was found. El Torito is preferred when
    /// both are present, since that's the path a real CD-boot BIOS takes.
    var bootLoadPlan: (bytes: [UInt8], convention: BootSectorConvention)? {
        if let et = elTorito, et.bootImageSignatureValid {
            return (et.bootImageBytes, .elTorito(lba: et.bootImageLBA))
        } else if hybridMBRSignatureValid {
            return (hybridMBRBytes, .hybridMBR)
        }
        return nil
    }

    var summary: String {
        if let et = elTorito, et.bootImageSignatureValid {
            return "El Torito boot image found (\(et.platformDescription)), boot signature valid."
        } else if hybridMBRSignatureValid {
            return "No El Torito catalog, but the image starts with a valid MBR boot signature (hybrid ISO)."
        } else if isValidISO9660 {
            return "Valid ISO 9660 image, but no bootable structure was found."
        } else {
            return "This doesn't look like a valid ISO 9660 image."
        }
    }
}

enum ISOBootInspectorError: LocalizedError, Sendable {
    case cannotOpenFile(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let reason):
            return "Could not read the ISO file: \(reason)"
        }
    }
}

enum ISOBootInspector {

    /// Reads just the handful of sectors needed to validate an ISO 9660
    /// image and, if present, its El Torito boot catalog and boot image —
    /// a few KB of I/O regardless of the ISO's total size, since this
    /// never reads the whole file. Intended to be called off the main
    /// thread (it's synchronous, blocking file I/O).
    static func inspect(fileURL: URL) throws -> ISOBootInspectionResult {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw ISOBootInspectorError.cannotOpenFile("The file couldn't be opened.")
        }
        defer { try? handle.close() }

        var log: [String] = []

        // --- Hybrid MBR check: byte 0 of the file itself ---
        // Most modern Linux live/install ISOs are "hybrid" images with a
        // real MBR at the very start, so they can also be dd'd straight
        // to a USB drive and BIOS-boot from there.
        let mbrBytes = try readBytes(handle, at: 0, count: 512)
        let hybridMBRValid = checkBootSignature(mbrBytes)
        log.append(hybridMBRValid
            ? "Byte 0: valid MBR boot signature (0x55AA) — this image is also directly USB-bootable."
            : "Byte 0: no MBR boot signature at the start of the file.")

        // --- Primary Volume Descriptor: logical sector 16 ---
        let pvd = try readBytes(handle, at: UInt64(16 * isoLogicalSectorSize), count: isoLogicalSectorSize)
        let identifier = trimmedASCII(pvd[1..<6])
        let isValidISO9660 = pvd[0] == 1 && identifier == "CD001"
        log.append(isValidISO9660
            ? "Sector 16: Primary Volume Descriptor confirmed (\"CD001\")."
            : "Sector 16: no Primary Volume Descriptor found — this file may not be an ISO 9660 image.")

        var volumeLabel: String?
        if isValidISO9660, let label = trimmedASCII(pvd[40..<72]), !label.isEmpty {
            volumeLabel = label
            log.append("Volume label: \"\(label)\"")
        }

        guard isValidISO9660 else {
            return ISOBootInspectionResult(
                isValidISO9660: false,
                volumeLabel: nil,
                hybridMBRSignatureValid: hybridMBRValid,
                hybridMBRBytes: mbrBytes,
                elTorito: nil,
                log: log
            )
        }

        // --- Scan the volume descriptor set for an El Torito Boot Record ---
        var bootCatalogLBA: UInt32?
        var sector = 17
        let maxDescriptorsToScan = 32 // generous; real images use 3-6
        while sector < 17 + maxDescriptorsToScan {
            let descriptor = try readBytes(handle, at: UInt64(sector * isoLogicalSectorSize), count: isoLogicalSectorSize)
            let type = descriptor[0]
            if type == 255 {
                log.append("Sector \(sector): Volume Descriptor Set Terminator.")
                break
            }
            if type == 0, let bootSystemID = trimmedASCII(descriptor[7..<39]), bootSystemID.hasPrefix("EL TORITO") {
                let lba = readUInt32LE(descriptor, at: 71)
                bootCatalogLBA = lba
                log.append("Sector \(sector): El Torito Boot Record found, boot catalog at LBA \(lba).")
            }
            sector += 1
        }

        guard let catalogLBA = bootCatalogLBA else {
            log.append("No El Torito boot catalog in this image.")
            return ISOBootInspectionResult(
                isValidISO9660: true,
                volumeLabel: volumeLabel,
                hybridMBRSignatureValid: hybridMBRValid,
                hybridMBRBytes: mbrBytes,
                elTorito: nil,
                log: log
            )
        }

        // --- Boot catalog: validation entry + initial/default entry ---
        let catalog = try readBytes(handle, at: UInt64(catalogLBA) * UInt64(isoLogicalSectorSize), count: isoLogicalSectorSize)
        let catalogSignatureValid = catalog[0] == 0x01 && catalog[30] == 0x55 && catalog[31] == 0xAA
        let rawPlatformID = catalog[1]
        log.append(catalogSignatureValid
            ? "Boot catalog validation entry OK (0x55AA key present)."
            : "Boot catalog validation entry is malformed or missing its 0x55/0xAA key.")

        // Initial/default entry immediately follows the 32-byte validation entry.
        let initialEntry = Array(catalog[32..<64])
        let bootImageLBA = readUInt32LE(initialEntry, at: 8)
        let sectorCountField = readUInt16LE(initialEntry, at: 6)
        log.append("Initial boot entry: image at LBA \(bootImageLBA), sector count field \(sectorCountField) (512-byte units, per the El Torito spec).")

        let bootImageBytes = try readBytes(handle, at: UInt64(bootImageLBA) * UInt64(isoLogicalSectorSize), count: 512)
        let bootImageSignatureValid = checkBootSignature(bootImageBytes)
        log.append(bootImageSignatureValid
            ? "Boot image at LBA \(bootImageLBA): valid 0x55AA boot signature — a real BIOS would accept this and hand off execution here."
            : "Boot image at LBA \(bootImageLBA): no 0x55AA boot signature at bytes 510–511.")

        let entry = ElToritoBootEntry(
            platform: ElToritoPlatform(rawValue: rawPlatformID),
            rawPlatformID: rawPlatformID,
            catalogSignatureValid: catalogSignatureValid,
            bootImageLBA: bootImageLBA,
            sectorCountField: sectorCountField,
            bootImageSignatureValid: bootImageSignatureValid,
            bootImageBytes: bootImageBytes
        )

        return ISOBootInspectionResult(
            isValidISO9660: true,
            volumeLabel: volumeLabel,
            hybridMBRSignatureValid: hybridMBRValid,
            hybridMBRBytes: mbrBytes,
            elTorito: entry,
            log: log
        )
    }

    // MARK: - Byte-level helpers

    private static func readBytes(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let data = (try handle.read(upToCount: count)) ?? Data()
        var bytes = Array(data)
        if bytes.count < count {
            // Short read (e.g. a truncated or smaller-than-expected image).
            // Pad with zeros so fixed-offset access below never indexes
            // out of bounds; the resulting signature checks simply fail
            // honestly rather than crashing.
            bytes.append(contentsOf: Array(repeating: 0, count: count - bytes.count))
        }
        return bytes
    }

    private static func checkBootSignature(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 512 && bytes[510] == 0x55 && bytes[511] == 0xAA
    }

    private static func trimmedASCII(_ bytes: ArraySlice<UInt8>) -> String? {
        guard let raw = String(bytes: bytes, encoding: .ascii) else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
}
