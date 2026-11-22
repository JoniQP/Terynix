import SwiftUI

/// Shows one ISO 9660 directory's real contents, fetched fresh each time
/// since `ISODirectoryBrowser.listDirectory` only reads the one
/// directory's extent rather than caching a whole-disc tree. Tapping a
/// subdirectory pushes another instance of this same view onto the
/// navigation stack for that entry — the standard self-referential
/// pattern for a SwiftUI tree browser.
struct ISODirectoryBrowserView: View {
    let directory: ISODirectoryEntry
    let isoURL: URL
    let title: String

    @State private var entries: [ISODirectoryEntry] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            } else if entries.isEmpty {
                Text("This folder is empty.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    if entry.isDirectory {
                        NavigationLink {
                            ISODirectoryBrowserView(directory: entry, isoURL: isoURL, title: entry.name)
                        } label: {
                            Label(entry.name, systemImage: "folder")
                        }
                    } else {
                        NavigationLink {
                            ISOFileDetailView(entry: entry, isoURL: isoURL)
                        } label: {
                            HStack {
                                Label(entry.name, systemImage: "doc")
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                entries = try await Task.detached(priority: .utility) {
                    try ISODirectoryBrowser.listDirectory(directory, fileURL: isoURL)
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
