import SwiftUI

/// Shows and edits one VM's settings. Takes a `vmID` rather than a
/// `VirtualMachine` snapshot and re-reads the live value from
/// `VMLibraryStore` on every render, so edits made elsewhere (or by this
/// view itself) are never shown stale.
struct VMSettingsView: View {
    let vmID: UUID
    @EnvironmentObject private var library: VMLibraryStore
    @EnvironmentObject private var isoLibrary: ISOLibrary

    @State private var showingSession = false
    @State private var isExportingDisk = false
    @State private var exportedDiskURL: URL?
    @State private var exportDiskError: String?

    private var liveVM: VirtualMachine? {
        library.virtualMachines.first { $0.id == vmID }
    }

    var body: some View {
        Group {
            if let vm = liveVM {
                Form {
                    Section("Identity") {
                        TextField("Name", text: bindingName(for: vm))
                        LabeledContent("Guest Profile", value: GuestOSCatalog.profile(for: vm.osProfileID).displayName)
                    }

                    Section("Resources") {
                        Stepper(value: bindingRAM(for: vm), in: Double(VirtualMachine.ramRangeMB.lowerBound)...Double(VirtualMachine.ramRangeMB.upperBound), step: 256) {
                            Text("Memory: \(vm.ramMB) MB")
                        }
                        Stepper(value: bindingCores(for: vm), in: 1...VirtualMachine.maxSelectableCores()) {
                            Text("Processors: \(vm.cpuCoreCount)")
                        }
                    }

                    Section {
                        LabeledContent("Maximum Size", value: "\(vm.diskMaxSizeGB) GB")
                        LabeledContent("Used on Disk", value: usedDiskDescription(for: vm))
                        LabeledContent("Available", value: availableDiskDescription(for: vm))
                        diskExportRow(for: vm)
                    } header: {
                        Text("Virtual Hard Disk")
                    } footer: {
                        Text("The maximum size can't be changed after creation in this version.")
                    }

                    Section {
                        Toggle("Boot from optical drive first", isOn: bindingBootFromOpticalFirst(for: vm))
                    } header: {
                        Text("Boot Order")
                    } footer: {
                        Text("When off, the virtual hard disk is tried before an attached ISO.")
                    }

                    Section("Display & Network") {
                        Picker("Resolution", selection: bindingResolution(for: vm)) {
                            ForEach(DisplayResolution.allCases) { res in
                                Text(res.label).tag(res)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("Network", selection: bindingNetwork(for: vm)) {
                            ForEach(NetworkMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Section("Attached Media") {
                        Picker("ISO", selection: bindingAttachedISO(for: vm)) {
                            Text("None").tag(UUID?.none)
                            ForEach(isoLibrary.isos) { iso in
                                Text(iso.displayName).tag(Optional(iso.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Section {
                        Button {
                            showingSession = true
                        } label: {
                            Label("Start Virtual PC", systemImage: "power")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .navigationTitle(vm.name)
                .navigationBarTitleDisplayMode(.inline)
                .fullScreenCover(isPresented: $showingSession) {
                    VMSessionView(vm: vm)
                        .environmentObject(library)
                        .environmentObject(isoLibrary)
                }
                .alert(
                    "Export Failed",
                    isPresented: Binding(
                        get: { exportDiskError != nil },
                        set: { if !$0 { exportDiskError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(exportDiskError ?? "")
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Virtual Machine Not Found")
                        .font(.headline)
                    Text("It may have been deleted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func usedDiskDescription(for vm: VirtualMachine) -> String {
        let bytes = VirtualDiskManager.shared.actualAllocatedBytes(fileName: vm.diskFileName)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func availableDiskDescription(for vm: VirtualMachine) -> String {
        let maxBytes = Int64(vm.diskMaxSizeGB) * 1_073_741_824
        let usedBytes = VirtualDiskManager.shared.actualAllocatedBytes(fileName: vm.diskFileName)
        return ByteCountFormatter.string(fromByteCount: max(0, maxBytes - usedBytes), countStyle: .file)
    }

    @ViewBuilder
    private func diskExportRow(for vm: VirtualMachine) -> some View {
        if isExportingDisk {
            HStack {
                Text("Exporting…")
                Spacer()
                ProgressView()
            }
        } else if let exportedDiskURL {
            ShareLink("Export Virtual Disk", item: exportedDiskURL)
        } else {
            Button("Export Virtual Disk") { exportDisk(vm) }
        }
    }

    private func exportDisk(_ vm: VirtualMachine) {
        isExportingDisk = true
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(vm.name).vpcdisk")
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try VirtualDiskManager.shared.exportDisk(fileName: vm.diskFileName, to: destination)
                }.value
                exportedDiskURL = destination
            } catch {
                exportDiskError = error.localizedDescription
            }
            isExportingDisk = false
        }
    }

    // MARK: - Bindings that write straight through to the library store

    private func bindingName(for vm: VirtualMachine) -> Binding<String> {
        Binding(
            get: { vm.name },
            set: { newValue in
                var updated = vm
                updated.name = newValue
                library.update(updated)
            }
        )
    }

    private func bindingRAM(for vm: VirtualMachine) -> Binding<Double> {
        Binding(
            get: { Double(vm.ramMB) },
            set: { newValue in
                var updated = vm
                updated.ramMB = Int(newValue)
                library.update(updated)
            }
        )
    }

    private func bindingCores(for vm: VirtualMachine) -> Binding<Int> {
        Binding(
            get: { vm.cpuCoreCount },
            set: { newValue in
                var updated = vm
                updated.cpuCoreCount = newValue
                library.update(updated)
            }
        )
    }

    private func bindingResolution(for vm: VirtualMachine) -> Binding<DisplayResolution> {
        Binding(
            get: { vm.displayResolution },
            set: { newValue in
                var updated = vm
                updated.displayResolution = newValue
                library.update(updated)
            }
        )
    }

    private func bindingNetwork(for vm: VirtualMachine) -> Binding<NetworkMode> {
        Binding(
            get: { vm.networkMode },
            set: { newValue in
                var updated = vm
                updated.networkMode = newValue
                library.update(updated)
            }
        )
    }

    private func bindingBootFromOpticalFirst(for vm: VirtualMachine) -> Binding<Bool> {
        Binding(
            get: { vm.bootOrder.first == .opticalDrive },
            set: { newValue in
                var updated = vm
                updated.bootOrder = newValue ? [.opticalDrive, .hardDisk] : [.hardDisk, .opticalDrive]
                library.update(updated)
            }
        )
    }

    private func bindingAttachedISO(for vm: VirtualMachine) -> Binding<UUID?> {
        Binding(
            get: { vm.attachedISOID },
            set: { newValue in
                var updated = vm
                updated.attachedISOID = newValue
                library.update(updated)
            }
        )
    }
}
