import Foundation

// MARK: - What this file is
//
// Real parsing of an ISO 9660 image's directory tree — the actual files
// and folders on the disc, read from the Primary Volume Descriptor's
// embedded root directory record and then each directory's own extent
// in turn. This covers plain ISO 9660 (Level 1/2) names only: Joliet
// (long UTF-16 names) and Rock Ridge (POSIX names) extensions, if
// present on a given disc, aren't parsed. That's a deliberate scoping
// choice, not an oversight — plain ISO 9660 names are the one thing
// every ISO 9660 disc has regardless of which extensions it also
// carries, so names may show in their shorter, often all-caps form
// rather than whatever a modern OS would normally display.

struct ISODirectoryEntry: Sendable, Identifiable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let sizeBytes: Int64
    /// Where this entry's own data (file contents, or — for a directory
    /// — its own listing of directory records) starts.
    let extentLBA: UInt32
}

enum ISODirectoryBrowserError: LocalizedError, Sendable {
    case notISO9660
    case cannotOpenFile(String)

    var errorDescription: String? {
        switch self {
        case .notISO9660: return "This doesn't look like a valid ISO 9660 image."
        case .cannotOpenFile(let reason): return "Could not read the ISO file: \(reason)"
        }
    }
}

enum ISODirectoryBrowser {
    private static let sectorSize = 2048

    /// The root directory's own entry — the starting point for browsing.
    /// Its directory record is embedded directly in the Primary Volume
    /// Descriptor at a fixed 34-byte field, offset 156, rather than
    /// needing to be looked up anywhere else.
    static func rootDirectory(fileURL: URL) throws -> ISODirectoryEntry {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw ISODirectoryBrowserError.cannotOpenFile("The file couldn't be opened.")
        }
        defer { try? handle.close() }

        let pvd = try readBytes(handle, at: UInt64(16 * sectorSize), count: sectorSize)
        guard pvd[0] == 1, String(bytes: pvd[1..<6], encoding: .ascii) == "CD001" else {
            throw ISODirectoryBrowserError.notISO9660
        }

        let rootRecord = Array(pvd[156..<190])
        let lba = readUInt32LE(rootRecord, at: 2)
        let length = readUInt32LE(rootRecord, at: 10)
        return ISODirectoryEntry(name: "/", isDirectory: true, sizeBytes: Int64(length), extentLBA: lba)
    }

    /// Lists one directory's immediate contents (not recursive) — call
    /// again with a returned subdirectory's own entry to go deeper. Only
    /// reads that one directory's extent, not the whole image, the same
    /// "a few KB regardless of file size" approach as ISOBootInspector.
    static func listDirectory(_ directory: ISODirectoryEntry, fileURL: URL) throws -> [ISODirectoryEntry] {
        guard directory.isDirectory, directory.sizeBytes > 0 else { return [] }
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw ISODirectoryBrowserError.cannotOpenFile("The file couldn't be opened.")
        }
        defer { try? handle.close() }

        let extentBytes = try readBytes(
            handle,
            at: UInt64(directory.extentLBA) * UInt64(sectorSize),
            count: Int(directory.sizeBytes)
        )

        var entries: [ISODirectoryEntry] = []
        var offset = 0
        while offset < extentBytes.count {
            let recordLength = Int(extentBytes[offset])

            // Directory records never span a sector boundary: a 0-length
            // "record" here is really the zero-padding that fills the
            // rest of the current sector, with the next real record
            // starting at the next sector. Skip to it rather than
            // treating this as the end of the listing.
            if recordLength == 0 {
                let consumedInSector = offset % sectorSize
                offset += (sectorSize - consumedInSector)
                continue
            }
            guard offset + recordLength <= extentBytes.count else { break }

            let record = Array(extentBytes[offset..<(offset + recordLength)])
            let lba = readUInt32LE(record, at: 2)
            let size = readUInt32LE(record, at: 10)
            let isDir = (record[25] & 0x02) != 0
            let nameLength = Int(record[32])

            if nameLength > 0, offset + 33 + nameLength <= extentBytes.count {
                let nameBytes = Array(record[33..<(33 + nameLength)])
                // The first two records in every directory are always the
                // "." and ".." entries, identified by a single 0x00 or
                // 0x01 byte rather than a real name — not useful to show.
                let isDotEntry = nameLength == 1 && (nameBytes[0] == 0x00 || nameBytes[0] == 0x01)
                if !isDotEntry {
                    var name = String(bytes: nameBytes, encoding: .ascii) ?? "?"
                    if !isDir, let semicolon = name.firstIndex(of: ";") {
                        name = String(name[..<semicolon]) // drop the ";1" version suffix files carry
                    }
                    entries.append(ISODirectoryEntry(name: name, isDirectory: isDir, sizeBytes: Int64(size), extentLBA: lba))
                }
            }

            offset += recordLength
        }
        return entries
    }

    /// A bounded preview of a file's actual content — at most `maxBytes`,
    /// regardless of the file's real size, specifically so a multi-GB
    /// kernel or squashfs image can't be read fully into memory just to
    /// preview it. Also reports whether the sample looks like text, via
    /// a simple heuristic: any NUL byte strongly suggests binary content,
    /// otherwise >90% printable ASCII/whitespace counts as text-like.
    static func readPreview(_ entry: ISODirectoryEntry, fileURL: URL, maxBytes: Int = 65536) throws -> (bytes: [UInt8], isLikelyText: Bool) {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw ISODirectoryBrowserError.cannotOpenFile("The file couldn't be opened.")
        }
        defer { try? handle.close() }

        let readCount = Int(min(Int64(maxBytes), entry.sizeBytes))
        try handle.seek(toOffset: UInt64(entry.extentLBA) * UInt64(sectorSize))
        let data = (try handle.read(upToCount: readCount)) ?? Data()
        let bytes = Array(data)
        return (bytes, isTextLike(bytes))
    }

    private static func isTextLike(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        let sample = bytes.prefix(4096)
        var printable = 0
        for b in sample {
            if b == 0 { return false } // a NUL byte strongly suggests binary content
            if b == 0x09 || b == 0x0A || b == 0x0D || (b >= 0x20 && b < 0x7F) {
                printable += 1
            }
        }
        return Double(printable) / Double(sample.count) > 0.90
    }

    /// Copies a file out of the ISO to a real destination on disk — in
    /// 1 MB chunks, never loading the whole file into memory at once.
    /// This matters: a casper/ or LiveOS/ squashfs root filesystem on a
    /// real Linux ISO can easily be 1-3+ GB, and loading that fully into
    /// memory would risk iPadOS killing the app outright.
    static func exportFile(_ entry: ISODirectoryEntry, fileURL: URL, to destinationURL: URL) throws {
        guard let sourceHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw ISODirectoryBrowserError.cannotOpenFile("The file couldn't be opened.")
        }
        defer { try? sourceHandle.close() }

        try? FileManager.default.removeItem(at: destinationURL) // clear any leftover from a previous export
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw ISODirectoryBrowserError.cannotOpenFile("Could not create the destination file.")
        }
        guard let destHandle = FileHandle(forWritingAtPath: destinationURL.path) else {
            throw ISODirectoryBrowserError.cannotOpenFile("Could not open the destination file.")
        }
        defer { try? destHandle.close() }

        let chunkSize = 1_048_576 // 1 MB — keeps memory flat regardless of file size
        var remaining = entry.sizeBytes
        var offset = UInt64(entry.extentLBA) * UInt64(sectorSize)

        while remaining > 0 {
            let thisChunk = Int(min(Int64(chunkSize), remaining))
            try sourceHandle.seek(toOffset: offset)
            guard let data = try sourceHandle.read(upToCount: thisChunk), !data.isEmpty else { break }
            try destHandle.write(contentsOf: data)
            offset += UInt64(data.count)
            remaining -= Int64(data.count)
        }
    }

    // MARK: - Byte-level helpers (same shape as ISOBootInspector's)

    private static func readBytes(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let data = (try handle.read(upToCount: count)) ?? Data()
        var bytes = Array(data)
        if bytes.count < count {
            bytes.append(contentsOf: Array(repeating: 0, count: count - bytes.count))
        }
        return bytes
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
