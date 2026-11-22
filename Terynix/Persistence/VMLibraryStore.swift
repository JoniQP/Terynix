import Foundation
import Combine

// This file intentionally has no `import SwiftUI`. It is pure storage
// management, kept separate from the UI and from the emulation engine,
// per the project's layering (see README "Architecture").

extension JSONEncoder {
    static var virtualPC: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var virtualPC: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Loads, saves, and mutates the list of virtual machines. This is the
/// single source of truth for VM configuration — views read from it via
/// `@EnvironmentObject` rather than keeping their own copies.
@MainActor
final class VMLibraryStore: ObservableObject {
    @Published private(set) var virtualMachines: [VirtualMachine] = []
    @Published var loadError: String?

    private let fileManager = FileManager.default
    private let storeURL: URL
    private static let hasSeededKey = "VirtualPC.hasSeededSampleVM"

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("VirtualPC", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.storeURL = directory.appendingPathComponent("vm_library.json")

        load()

        if !UserDefaults.standard.bool(forKey: Self.hasSeededKey) {
            seedSampleVM()
            UserDefaults.standard.set(true, forKey: Self.hasSeededKey)
        }
    }

    func load() {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            virtualMachines = []
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            virtualMachines = try JSONDecoder.virtualPC.decode([VirtualMachine].self, from: data)
            loadError = nil
        } catch {
            loadError = "Could not load saved virtual machines: \(error.localizedDescription)"
            virtualMachines = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder.virtualPC.encode(virtualMachines)
            try data.write(to: storeURL, options: .atomic)
            loadError = nil
        } catch {
            loadError = "Could not save your changes: \(error.localizedDescription)"
        }
    }

    func add(_ vm: VirtualMachine) {
        virtualMachines.append(vm)
        save()
    }

    func update(_ vm: VirtualMachine) {
        guard let idx = virtualMachines.firstIndex(where: { $0.id == vm.id }) else { return }
        virtualMachines[idx] = vm
        save()
    }

    /// Updates just the runtime-state field, used by an open session screen
    /// to reflect boot/run/pause/stop transitions without touching the
    /// rest of the configuration.
    func updateRuntimeState(id: UUID, to newState: VMRuntimeState) {
        guard let idx = virtualMachines.firstIndex(where: { $0.id == id }) else { return }
        guard virtualMachines[idx].runtimeState != newState else { return }
        virtualMachines[idx].runtimeState = newState
        if newState == .running {
            virtualMachines[idx].lastStartedAt = Date()
        }
        save()
    }

    /// Deletes a VM's configuration *and* its virtual disk file. Callers
    /// (views) are responsible for confirming with the user first — this
    /// method itself does not ask, it only acts once asked.
    func delete(_ vm: VirtualMachine) {
        try? VirtualDiskManager.shared.deleteDisk(fileName: vm.diskFileName)
        virtualMachines.removeAll { $0.id == vm.id }
        save()
    }

    private func seedSampleVM() {
        var sample = VirtualMachine(
            name: "Demo PC",
            osProfileID: "linux-generic",
            ramMB: 2048,
            cpuCoreCount: 2,
            diskMaxSizeGB: 8
        )
        do {
            try VirtualDiskManager.shared.createDisk(fileName: sample.diskFileName, maximumSizeGB: sample.diskMaxSizeGB)
        } catch {
            // If disk creation fails (e.g. a nearly-full iPad on first
            // launch), still seed the VM entry rather than silently
            // skipping the sample — settings will surface the problem.
            loadError = "Could not create the sample VM's disk: \(error.localizedDescription)"
        }
        sample.runtimeState = .stopped
        virtualMachines.append(sample)
        save()
    }
}
