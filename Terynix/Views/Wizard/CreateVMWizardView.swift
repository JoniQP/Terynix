import SwiftUI

/// A four-step wizard for creating a new virtual machine. Deliberately
/// not built on `TabView(.page)`, because swipe-paging would let a user
/// swipe past the name step without entering a name, bypassing the
/// "Next" button's validation — a plain `switch` on `step`, advanced
/// only by the toolbar buttons, avoids that entirely.
struct CreateVMWizardView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (VirtualMachine) -> Void

    @State private var step = 0
    @State private var name = ""
    @State private var selectedOSID = GuestOSCatalog.profiles.first!.id
    @State private var ramMB: Double = 2048
    @State private var cpuCoreCount = 2
    @State private var diskSizeGB: Double = 16
    @State private var resolution: DisplayResolution = .r1024x768
    @State private var networkMode: NetworkMode = .disabled
    @State private var bootFromOpticalFirst = true
    @State private var creationError: String?

    private var maxAvailableCores: Int { VirtualMachine.maxSelectableCores() }

    private var canProceedFromStep0: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step + 1), total: 4)
                    .padding([.horizontal, .top])
                    .padding(.bottom, 4)

                Group {
                    switch step {
                    case 0: identityStep
                    case 1: resourcesStep
                    case 2: deviceStep
                    default: reviewStep
                    }
                }
            }
            .navigationTitle("New Virtual Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step < 3 {
                        Button("Next") { step += 1 }
                            .disabled(step == 0 && !canProceedFromStep0)
                    } else {
                        Button("Create") { createVM() }
                            .fontWeight(.semibold)
                    }
                }
            }
            .alert(
                "Couldn't Create Virtual Machine",
                isPresented: Binding(
                    get: { creationError != nil },
                    set: { if !$0 { creationError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(creationError ?? "")
            }
        }
    }

    // MARK: - Steps

    private var identityStep: some View {
        Form {
            Section("Name") {
                TextField("e.g. Ubuntu Desktop", text: $name)
            }
            Section {
                Picker("Guest OS Profile", selection: $selectedOSID) {
                    ForEach(GuestOSCatalog.familiesInOrder, id: \.self) { family in
                        Section(family) {
                            ForEach(GuestOSCatalog.profiles.filter { $0.family == family }) { profile in
                                Text(profile.displayName).tag(profile.id)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text(GuestOSCatalog.profile(for: selectedOSID).supportLevel.explanation)
            }
        }
    }

    private var resourcesStep: some View {
        Form {
            Section {
                Stepper(value: $ramMB, in: Double(VirtualMachine.ramRangeMB.lowerBound)...Double(VirtualMachine.ramRangeMB.upperBound), step: 256) {
                    Text("Memory: \(Int(ramMB)) MB")
                }
            } footer: {
                Text("Up to \(VirtualMachine.ramRangeMB.upperBound) MB, simulated. iPadOS can still terminate the app if overall memory use gets too high — real emulators on this platform generally stay under ~20% of device RAM for this reason.")
            }

            Section {
                Stepper(value: $cpuCoreCount, in: 1...maxAvailableCores) {
                    Text("Processors: \(cpuCoreCount)")
                }
            } footer: {
                Text("This iPad reports \(maxAvailableCores) usable cores. Virtual PC doesn't reserve real cores — the demo engine runs on a single thread regardless of this setting.")
            }

            Section {
                Stepper(value: $diskSizeGB, in: Double(VirtualMachine.diskRangeGB.lowerBound)...Double(VirtualMachine.diskRangeGB.upperBound), step: 1) {
                    Text("Hard Disk: \(Int(diskSizeGB)) GB")
                }
            } footer: {
                Text("Creates a dynamically-growing disk file up to this size — it only uses as much on-device storage as data actually written to it, the same as VirtualBox's dynamic disks.")
            }
        }
    }

    private var deviceStep: some View {
        Form {
            Section("Display") {
                Picker("Resolution", selection: $resolution) {
                    ForEach(DisplayResolution.allCases) { res in
                        Text(res.label).tag(res)
                    }
                }
                .pickerStyle(.menu)
            }
            Section {
                Picker("Network", selection: $networkMode) {
                    ForEach(NetworkMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text(networkMode.helpText)
            }
            Section {
                Toggle("Boot from optical drive first", isOn: $bootFromOpticalFirst)
            } footer: {
                Text("When on, an attached ISO is tried before the virtual hard disk, matching a typical BIOS boot order.")
            }
        }
    }

    private var reviewStep: some View {
        Form {
            Section("Summary") {
                LabeledContent("Name", value: name)
                LabeledContent("Guest Profile", value: GuestOSCatalog.profile(for: selectedOSID).displayName)
                LabeledContent("Memory", value: "\(Int(ramMB)) MB")
                LabeledContent("Processors", value: "\(cpuCoreCount)")
                LabeledContent("Hard Disk", value: "\(Int(diskSizeGB)) GB")
                LabeledContent("Display", value: resolution.label)
                LabeledContent("Network", value: networkMode.rawValue)
            }
            Section {
                Text(GuestOSCatalog.profile(for: selectedOSID).supportLevel.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func createVM() {
        let bootOrder: [BootDevice] = bootFromOpticalFirst
            ? [.opticalDrive, .hardDisk]
            : [.hardDisk, .opticalDrive]

        let newVM = VirtualMachine(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            osProfileID: selectedOSID,
            ramMB: Int(ramMB),
            cpuCoreCount: cpuCoreCount,
            diskMaxSizeGB: Int(diskSizeGB),
            displayResolution: resolution,
            networkMode: networkMode,
            bootOrder: bootOrder
        )

        do {
            try VirtualDiskManager.shared.createDisk(fileName: newVM.diskFileName, maximumSizeGB: newVM.diskMaxSizeGB)
            onCreate(newVM)
            dismiss()
        } catch {
            creationError = error.localizedDescription
        }
    }
}
