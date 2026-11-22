import SwiftUI

/// Shows one file's real content — a bounded preview if it looks like
/// text, otherwise just its size — and offers a genuine export to the
/// Files app or anywhere else via the system share sheet. The preview
/// is capped (`ISODirectoryBrowser.readPreview`'s default 64 KB) no
/// matter how large the file actually is; export streams the full file
/// in chunks rather than holding it all in memory, since a real file on
/// a real Linux ISO can be multiple gigabytes.
struct ISOFileDetailView: View {
    let entry: ISODirectoryEntry
    let isoURL: URL

    @State private var previewText: String?
    @State private var binaryBytes: [UInt8]?
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var exportError: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                errorView(loadError)
            } else if let previewText {
                ScrollView {
                    Text(previewText.isEmpty ? "(empty file)" : previewText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    if entry.sizeBytes > 65536 {
                        Text("Showing the first 64 KB of \(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)) — export to see the rest.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.bottom)
                    }
                }
            } else if let binaryBytes {
                ScrollView([.vertical, .horizontal]) {
                    Text(binaryBytes.isEmpty ? "(empty file)" : Self.hexDump(Array(binaryBytes.prefix(512))))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    if entry.sizeBytes > 512 {
                        Text("First 512 bytes of \(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)) — export to get the rest.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.bottom)
                    }
                }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isExporting {
                    ProgressView()
                } else if let exportedURL {
                    ShareLink(item: exportedURL)
                } else {
                    Button("Export") { exportFile() }
                }
            }
        }
        .alert(
            "Export Failed",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .task {
            do {
                let (bytes, isText) = try await Task.detached(priority: .utility) {
                    try ISODirectoryBrowser.readPreview(entry, fileURL: isoURL)
                }.value
                if isText {
                    previewText = String(decoding: bytes, as: UTF8.self)
                } else {
                    binaryBytes = bytes
                }
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Classic three-column hex dump: 8-digit offset, 16 space-separated
    /// hex bytes (padded to stay aligned on a short final row), then the
    /// same 16 bytes as ASCII with non-printable bytes shown as `.`.
    private static func hexDump(_ bytes: [UInt8]) -> String {
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let row = Array(bytes[offset..<min(offset + 16, bytes.count)])
            let hexPart = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let paddedHex = hexPart.padding(toLength: 47, withPad: " ", startingAt: 0)
            let asciiPart = String(row.map { (0x20...0x7E).contains($0) ? Character(Unicode.Scalar($0)) : "." })
            lines.append(String(format: "%08X", offset) + "  " + paddedHex + "  " + asciiPart)
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    private func exportFile() {
        isExporting = true
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try ISODirectoryBrowser.exportFile(entry, fileURL: isoURL, to: destination)
                }.value
                exportedURL = destination
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }
}
