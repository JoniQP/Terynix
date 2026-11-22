import SwiftUI
import UniformTypeIdentifiers

struct MediaLibraryView: View {
    @EnvironmentObject private var isoLibrary: ISOLibrary
    @State private var showingImporter = false
    @State private var isoPendingDeletion: ImportedISO?
    @State private var inspectingISO: ImportedISO?

    var body: some View {
        List {
            if isoLibrary.isImporting {
                HStack {
                    ProgressView()
                    Text("Importing…")
                        .foregroundStyle(.secondary)
                }
            }

            if isoLibrary.isos.isEmpty && !isoLibrary.isImporting {
                Text("No ISO files imported yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach(isoLibrary.isos) { iso in
                HStack(spacing: 12) {
                    Image(systemName: "opticaldiscdrive")
                        .foregroundStyle(VPCTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(iso.displayName)
                            .font(.body)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(ByteCountFormatter.string(fromByteCount: iso.fileSizeBytes, countStyle: .file))
                            Text("·")
                            Text(iso.importedAt, style: .date)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { inspectingISO = iso }
                .swipeActions {
                    Button(role: .destructive) {
                        isoPendingDeletion = iso
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Virtual Media Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import ISO", systemImage: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    isoLibrary.importISO(from: url)
                }
            case .failure(let error):
                isoLibrary.lastError = error.localizedDescription
            }
        }
        .alert(
            "Delete “\(isoPendingDeletion?.displayName ?? "")”?",
            isPresented: Binding(
                get: { isoPendingDeletion != nil },
                set: { if !$0 { isoPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { isoPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let iso = isoPendingDeletion {
                    isoLibrary.delete(iso)
                }
                isoPendingDeletion = nil
            }
        } message: {
            Text("This removes the ISO from Virtual PC's storage. The original file in Files is not affected.")
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { isoLibrary.lastError != nil },
                set: { if !$0 { isoLibrary.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(isoLibrary.lastError ?? "")
        }
        .sheet(item: $inspectingISO) { iso in
            ISOBootInspectionView(iso: iso)
                .environmentObject(isoLibrary)
        }
    }
}

/// Runs `ISOBootInspector` against one library entry and shows its real
/// findings. This is the same inspection a VM session runs during boot —
/// surfaced here too so a disc can be checked without starting a session.
private struct ISOBootInspectionView: View {
    let iso: ImportedISO
    @EnvironmentObject private var isoLibrary: ISOLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var result: ISOBootInspectionResult?
    @State private var errorMessage: String?
    @State private var rootDirectory: ISODirectoryEntry?

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    List {
                        Section {
                            Label(result.summary, systemImage: result.isBootable ? "checkmark.seal" : "exclamationmark.triangle")
                                .foregroundStyle(result.isBootable ? .green : .orange)
                        }

                        Section("Volume") {
                            LabeledContent("Label", value: result.volumeLabel ?? "—")
                            LabeledContent("Hybrid MBR Signature", value: result.hybridMBRSignatureValid ? "Valid" : "Not present")
                        }

                        if let et = result.elTorito {
                            Section("El Torito Boot Catalog") {
                                LabeledContent("Platform", value: et.platformDescription)
                                LabeledContent("Boot Image LBA", value: "\(et.bootImageLBA)")
                                LabeledContent("Boot Signature", value: et.bootImageSignatureValid ? "Valid (0x55AA)" : "Invalid")
                            }
                        }

                        if let rootDirectory {
                            Section {
                                NavigationLink {
                                    ISODirectoryBrowserView(directory: rootDirectory, isoURL: isoLibrary.fileURL(for: iso), title: iso.displayName)
                                } label: {
                                    Label("Browse Files", systemImage: "folder")
                                }
                            }
                        }

                        Section("Read Log") {
                            ForEach(Array(result.log.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                } else if let errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Reading boot structures…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(iso.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                let url = isoLibrary.fileURL(for: iso)
                do {
                    result = try await Task.detached(priority: .utility) {
                        try ISOBootInspector.inspect(fileURL: url)
                    }.value
                } catch {
                    errorMessage = error.localizedDescription
                }
                // Independent of boot-sector validity — a disc can have a
                // perfectly browsable filesystem with no valid boot
                // sector at all — so this doesn't share the error state
                // above; it simply doesn't offer "Browse Files" if it fails.
                rootDirectory = try? await Task.detached(priority: .utility) {
                    try ISODirectoryBrowser.rootDirectory(fileURL: url)
                }.value
            }
        }
    }
}
