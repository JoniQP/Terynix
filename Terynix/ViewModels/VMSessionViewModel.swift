import Foundation
import Combine

/// Drives a single open VM session: the simulated firmware/bootloader
/// text, the demo CPU tick loop, and the Start/Pause/Resume/Restart/Shut
/// Down state machine. One instance per open `VMSessionView`.
///
/// Demo sessions only run while their screen is on screen. There is no
/// real background hypervisor process behind this app (iPadOS gives
/// third-party apps no such capability — see the README), so this
/// view model makes no attempt to keep "running" after its view
/// disappears; `tearDown()` is called from `.onDisappear` for exactly
/// that reason.
@MainActor
final class VMSessionViewModel: ObservableObject {
    enum SessionPhase: Hashable {
        case poweredOff
        case firmware
        case bootingLoader
        case running
        case paused
        case shuttingDown
    }

    let vm: VirtualMachine

    @Published private(set) var phase: SessionPhase = .poweredOff
    @Published private(set) var bootLog: [String] = []
    @Published private(set) var cpuState = DemoCPUState()
    @Published private(set) var lastExecutedInstruction: DemoInstruction?
    @Published private(set) var simulatedCPUUsagePercent: Double = 0
    @Published private(set) var simulatedMemoryUsedMB: Int = 0
    @Published private(set) var simulatedDiskActive: Bool = false

    /// Set once per session, during the boot sequence, once it's known
    /// whether a real bootable disc was found. When true, `.running`
    /// drives the real `X86CPU` below instead of the toy `DemoPCEngine`.
    @Published private(set) var usingRealX86 = false
    @Published private(set) var x86Registers: X86Registers?
    @Published private(set) var x86ConsoleOutput: String = ""
    @Published private(set) var x86StopReason: X86StopReason = .running
    @Published private(set) var x86InstructionsExecuted = 0
    @Published private(set) var x86WaitingForKey = false
    @Published private(set) var x86ExecutionTrace: [String] = []

    private let engine = DemoPCEngine()
    private var x86CPU: X86CPU?
    private let osProfile: GuestOSProfile
    private var tickTask: Task<Void, Never>?

    /// Remembered across `restart()` so a restarted session re-inspects
    /// the same attached disc rather than losing track of it.
    private var lastAttachedISOURL: URL?

    /// Bumped on every start/restart/teardown so a previous, still-sleeping
    /// boot-sequence Task can tell it has been superseded and stop
    /// mutating state, even though `phase` itself may cycle back through
    /// the same raw values across attempts.
    private var sessionGeneration = 0

    init(vm: VirtualMachine) {
        self.vm = vm
        self.osProfile = GuestOSCatalog.profile(for: vm.osProfileID)
    }

    /// - Parameter attachedISOURL: the on-disk location of the VM's
    ///   attached ISO, if any — the view resolves this from `ISOLibrary`
    ///   since `attachedISOID` on its own is just an identifier. Pass
    ///   `nil` if no disc is attached.
    func start(attachedISOURL: URL?) {
        guard phase == .poweredOff else { return }
        lastAttachedISOURL = attachedISOURL
        bootLog = []
        engine.reset()
        phase = .firmware
        sessionGeneration += 1
        let generation = sessionGeneration
        Task {
            await runBootSequence(generation: generation, attachedISOURL: attachedISOURL)
        }
    }

    private func runBootSequence(generation: Int, attachedISOURL: URL?) async {
        let firmwareLines = [
            "Virtual PC UEFI — Simulated Firmware v1.0",
            "RAM Check: \(vm.ramMB) MB simulated... OK",
            "Detecting boot devices...",
            vm.bootOrder.first.map { "Boot device: \($0.rawValue)" } ?? "No boot device configured"
        ]
        for line in firmwareLines {
            guard generation == sessionGeneration else { return }
            bootLog.append(line)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        guard generation == sessionGeneration else { return }

        var bootPlan: (bytes: [UInt8], convention: BootSectorConvention)?
        if vm.bootOrder.first == .opticalDrive {
            bootPlan = await runOpticalBootInspection(generation: generation, isoURL: attachedISOURL)
        }

        guard generation == sessionGeneration else { return }
        phase = .bootingLoader

        for line in osProfile.bootSplashLines {
            guard generation == sessionGeneration else { return }
            bootLog.append(line)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        guard generation == sessionGeneration else { return }

        if let plan = bootPlan, let isoURL = attachedISOURL {
            setUpRealX86Engine(bootPlan: plan, isoURL: isoURL)
        } else {
            usingRealX86 = false
            x86CPU = nil
        }

        phase = .running
        startTickLoop()
    }

    /// Loads the real, already-validated boot sector bytes into a fresh
    /// `X86CPU` at the standard BIOS boot address (0000:7C00), wires its
    /// disk services to the real attached ISO using the right sector-size
    /// convention for how the boot image was found, and sets DL to the
    /// conventional boot-drive value most bootloaders expect. From here,
    /// `tick()` steps this CPU instead of the toy engine.
    private func setUpRealX86Engine(bootPlan: (bytes: [UInt8], convention: BootSectorConvention), isoURL: URL) {
        let sectorSize: Int
        switch bootPlan.convention {
        case .elTorito: sectorSize = 2048
        case .hybridMBR: sectorSize = 512
        }

        let services = X86BIOSServices(isoFileURL: isoURL, sectorSizeBytes: sectorSize)
        let cpu = X86CPU(biosServices: services)
        cpu.regs.cs = 0x0000
        cpu.regs.ip = 0x7C00
        cpu.regs.dl = 0x80 // conventional boot-drive number most boot code expects
        cpu.loadBytes(bootPlan.bytes, atPhysicalAddress: cpu.physicalAddress(segment: 0, offset: 0x7C00))

        x86CPU = cpu
        usingRealX86 = true
        x86Registers = cpu.regs
        x86ConsoleOutput = ""
        x86StopReason = .running
        x86InstructionsExecuted = 0
    }

    /// Runs a real, read-only inspection of the attached ISO's ISO 9660 /
    /// El Torito boot structures (see `ISOBootInspector`), appends its
    /// genuine findings to the boot log, and — when a valid boot sector
    /// was found — returns the real bytes and addressing convention
    /// needed to actually load and run it. Returns `nil` for "nothing to
    /// execute", in which case the caller falls back to the toy engine.
    private func runOpticalBootInspection(generation: Int, isoURL: URL?) async -> (bytes: [UInt8], convention: BootSectorConvention)? {
        guard let isoURL else {
            bootLog.append("No disc in optical drive — trying next boot device.")
            try? await Task.sleep(nanoseconds: 450_000_000)
            return nil
        }

        bootLog.append("Reading ISO 9660 volume descriptor...")
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard generation == sessionGeneration else { return nil }

        do {
            let result = try await Task.detached(priority: .utility) {
                try ISOBootInspector.inspect(fileURL: isoURL)
            }.value

            guard generation == sessionGeneration else { return nil }
            for line in result.log {
                guard generation == sessionGeneration else { return nil }
                bootLog.append(line)
                try? await Task.sleep(nanoseconds: 350_000_000)
            }

            guard generation == sessionGeneration else { return nil }
            let plan = result.bootLoadPlan
            bootLog.append(
                plan != nil
                    ? "Boot sector accepted. Loading the real x86 interpreter at 0000:7C00…"
                    : "No valid boot sector found on this disc. Continuing with the demo engine."
            )
            try? await Task.sleep(nanoseconds: 450_000_000)
            return plan
        } catch {
            guard generation == sessionGeneration else { return nil }
            bootLog.append("Could not read the attached ISO: \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 450_000_000)
            return nil
        }
    }

    private func startTickLoop() {
        tickTask?.cancel()
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                tick()
            }
        }
    }

    private func tick() {
        guard phase == .running else { return }

        if let cpu = x86CPU {
            tickRealX86(cpu)
        } else {
            tickToyEngine()
        }

        simulatedCPUUsagePercent = Double.random(in: 8...27)
        let ramCeiling = max(64.0, Double(vm.ramMB) * 0.35)
        simulatedMemoryUsedMB = Int(Double.random(in: (ramCeiling * 0.4)...ramCeiling))
    }

    /// Steps the real interpreter once and copies its state out for
    /// display. Stops calling `step()` once the CPU has stopped itself
    /// (halted, or hit something unsupported) — there's nothing further
    /// to execute, but the final state stays on screen rather than
    /// vanishing or resetting.
    private func tickRealX86(_ cpu: X86CPU) {
        if !cpu.stopReason.isStopped {
            cpu.step()
        }
        x86Registers = cpu.regs
        x86ConsoleOutput = cpu.biosServices.consoleOutput
        x86StopReason = cpu.stopReason
        x86InstructionsExecuted = cpu.instructionsExecuted
        x86WaitingForKey = cpu.isWaitingForKey
        x86ExecutionTrace = cpu.executionTrace
        simulatedDiskActive = cpu.instructionsExecuted > 0 && !cpu.stopReason.isStopped
    }

    /// Called from the session screen's on-screen key buttons.
    func sendKey(_ key: KeyEvent) {
        x86CPU?.pressKey(key)
    }

    private func tickToyEngine() {
        if let instruction = engine.step() {
            lastExecutedInstruction = instruction
            cpuState = engine.state
            simulatedDiskActive = (instruction.opcode == .storeToMemory)
        } else {
            // The tiny demo program finished; loop it so the screen keeps
            // showing live activity for as long as the session is "running".
            engine.reset()
            simulatedDiskActive = false
        }
    }

    func pause() {
        guard phase == .running else { return }
        tickTask?.cancel()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .running
        startTickLoop()
    }

    func restart() {
        tickTask?.cancel()
        sessionGeneration += 1
        phase = .poweredOff
        start(attachedISOURL: lastAttachedISOURL)
    }

    func shutDown() {
        guard phase == .running || phase == .paused else { return }
        tickTask?.cancel()
        sessionGeneration += 1
        phase = .shuttingDown
        bootLog.append("Shutting down...")
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            phase = .poweredOff
            x86CPU = nil
            usingRealX86 = false
        }
    }

    /// Called from the session screen's `.onDisappear`. See the type-level
    /// comment on why this does not try to keep the session alive.
    func tearDown() {
        tickTask?.cancel()
        tickTask = nil
        sessionGeneration += 1
        phase = .poweredOff
        // Releases the 1 MB emulated-memory array and, via
        // X86BIOSServices' deinit, closes the open ISO file handle —
        // promptly, rather than waiting on ARC to get to it eventually.
        x86CPU = nil
        usingRealX86 = false
    }
}
