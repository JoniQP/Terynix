import Foundation
import Combine

/// A single ISO file Virtual PC has imported into its own sandboxed
/// storage (as opposed to a reference to a file still living in Files).
struct ImportedISO: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    let fileName: String
    var fileSizeBytes: Int64
    let importedAt: Date
}

/// Tracks ISO files the user has imported through the Files picker,
/// copying each into the app's own storage so it survives even if the
/// original is later removed from iCloud Drive or wherever it came from.
@MainActor
final class ISOLibrary: ObservableObject {
    @Published private(set) var isos: [ImportedISO] = []
    @Published var lastError: String?
    @Published private(set) var isImporting = false

    private let fileManager = FileManager.default
    private let indexURL: URL

    var isoDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("VirtualPC/ISOs", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("VirtualPC", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.indexURL = dir.appendingPathComponent("iso_library.json")
        load()
    }

    func load() {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            isos = []
            return
        }
        do {
            let data = try Data(contentsOf: indexURL)
            isos = try JSONDecoder.virtualPC.decode([ImportedISO].self, from: data)
        } catch {
            lastError = "Could not load the media library: \(error.localizedDescription)"
            isos = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder.virtualPC.encode(isos)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            lastError = "Could not save the media library: \(error.localizedDescription)"
        }
    }

    /// Copies a user-selected ISO (from `.fileImporter`, backed by the
    /// Files app) into Virtual PC's own storage. The copy runs off the
    /// main thread since ISOs can be gigabytes in size — see
    /// "Use asynchronous tasks for lengthy operations" in the spec.
    func importISO(from sourceURL: URL) {
        isImporting = true
        let targetDirectory = isoDirectory

        Task {
            do {
                let entry = try await Task.detached(priority: .utility) { () -> ImportedISO in
                    let fileManager = FileManager.default
                    let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
                    defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }

                    let fileName = "\(UUID().uuidString).iso"
                    let destinationURL = targetDirectory.appendingPathComponent(fileName)
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)

                    let attrs = try fileManager.attributesOfItem(atPath: destinationURL.path)
                    let size = (attrs[.size] as? Int64) ?? 0

                    return ImportedISO(
                        id: UUID(),
                        displayName: sourceURL.lastPathComponent,
                        fileName: fileName,
                        fileSizeBytes: size,
                        importedAt: Date()
                    )
                }.value

                self.isos.append(entry)
                self.save()
            } catch {
                self.lastError = "Could not import \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            }
            self.isImporting = false
        }
    }

    /// Where a given library entry's file actually lives on disk.
    func fileURL(for iso: ImportedISO) -> URL {
        isoDirectory.appendingPathComponent(iso.fileName)
    }

    func delete(_ iso: ImportedISO) {
        try? fileManager.removeItem(at: fileURL(for: iso))
        isos.removeAll { $0.id == iso.id }
        save()
    }

    func iso(for id: UUID?) -> ImportedISO? {
        guard let id else { return nil }
        return isos.first { $0.id == id }
    }
}
