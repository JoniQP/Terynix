import SwiftUI

/// The full-screen "monitor" for one virtual machine session. Presented
/// via `.fullScreenCover` from `VMSettingsView`, which on iPad is also
/// how "Full Screen" from the original spec is satisfied — the session
/// has no separate windowed mode to toggle out of.
struct VMSessionView: View {
    let vm: VirtualMachine
    @EnvironmentObject private var library: VMLibraryStore
    @EnvironmentObject private var isoLibrary: ISOLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: VMSessionViewModel

    /// Resolved on demand from `attachedISOID`, which on its own is just
    /// an identifier — this is the actual on-disk location `ISOBootInspector`
    /// reads from.
    private var attachedISOURL: URL? {
        guard let isoID = vm.attachedISOID, let iso = isoLibrary.iso(for: isoID) else { return nil }
        return isoLibrary.fileURL(for: iso)
    }

    init(vm: VirtualMachine) {
        self.vm = vm
        _session = StateObject(wrappedValue: VMSessionViewModel(vm: vm))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            ZStack {
                Color.black
                monitorContent
                    .id(session.phase)
                    .transition(.opacity)
                    .aspectRatio(vm.displayResolution.pixelSize, contentMode: .fit)
            }
            .animation(.easeInOut(duration: 0.3), value: session.phase)
            controlBar
        }
        .background(Color.black)
        .onAppear { session.start(attachedISOURL: attachedISOURL) }
        .onChange(of: session.phase) { newPhase in
            library.updateRuntimeState(id: vm.id, to: runtimeState(for: newPhase))
        }
        .onDisappear {
            session.tearDown()
            library.updateRuntimeState(id: vm.id, to: .stopped)
        }
        .statusBarHidden(true)
    }

    private func runtimeState(for phase: VMSessionViewModel.SessionPhase) -> VMRuntimeState {
        switch phase {
        case .poweredOff, .shuttingDown: return .stopped
        case .firmware, .bootingLoader: return .starting
        case .running: return .running
        case .paused: return .paused
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text(vm.name)
                .font(.footnote.bold())
                .lineLimit(1)
            Spacer()
            statusChip
            Label("\(Int(session.simulatedCPUUsagePercent))%", systemImage: "cpu")
            Label("\(session.simulatedMemoryUsedMB) MB", systemImage: "memorychip")
            Image(systemName: "externaldrive")
                .opacity(session.simulatedDiskActive ? 1 : 0.25)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.08))
    }

    private var statusChip: some View {
        Text(statusLabel)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.25))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
    }

    private var statusLabel: String {
        switch session.phase {
        case .poweredOff: return "Powered Off"
        case .firmware: return "Firmware"
        case .bootingLoader: return "Booting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .shuttingDown: return "Shutting Down"
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .running: return .green
        case .paused: return .yellow
        case .poweredOff: return .gray
        default: return .blue
        }
    }

    // MARK: - Monitor

    @ViewBuilder
    private var monitorContent: some View {
        switch session.phase {
        case .firmware, .bootingLoader:
            BIOSBootView(lines: session.bootLog, resolution: vm.displayResolution)
        case .running, .paused:
            if session.usingRealX86, let regs = session.x86Registers {
                X86MonitorView(
                    registers: regs,
                    consoleOutput: session.x86ConsoleOutput,
                    stopReason: session.x86StopReason,
                    instructionsExecuted: session.x86InstructionsExecuted,
                    executionTrace: session.x86ExecutionTrace,
                    isWaitingForKey: session.x86WaitingForKey,
                    isPaused: session.phase == .paused,
                    onKeyPress: { session.sendKey($0) }
                )
            } else {
                DemoDesktopView(
                    cpuState: session.cpuState,
                    lastInstruction: session.lastExecutedInstruction,
                    isPaused: session.phase == .paused
                )
            }
        case .poweredOff, .shuttingDown:
            VStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.3))
                Text(session.phase == .shuttingDown ? "Shutting down…" : "Powered Off")
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 22) {
            controlButton("restart.circle", label: "Restart") { session.restart() }
                .disabled(session.phase == .poweredOff)

            if session.phase == .paused {
                controlButton("play.circle.fill", label: "Resume") { session.resume() }
            } else {
                controlButton("pause.circle", label: "Pause") { session.pause() }
                    .disabled(session.phase != .running)
            }

            controlButton("power.circle", label: "Shut Down") { session.shutDown() }
                .disabled(session.phase == .poweredOff || session.phase == .shuttingDown)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
    }

    private func controlButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title2)
                Text(label).font(.caption2)
            }
        }
        .foregroundStyle(.white)
    }
}

/// The "desktop" shown once the demo session reaches `.running` —
/// a live register/memory monitor for `DemoPCEngine`, not a real OS
/// desktop. The on-screen caption says so explicitly, not just a code
/// comment, since this is the one screen most likely to be mistaken for
/// "a real PC booted".
private struct DemoDesktopView: View {
    let cpuState: DemoCPUState
    let lastInstruction: DemoInstruction?
    let isPaused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "desktopcomputer")
                Text("Virtual PC — Demo Session")
                Spacer()
                if isPaused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                }
            }
            .font(.headline)
            .foregroundStyle(.white)

            Text("This screen shows a small simulated CPU executing a demo program. It is not running a real operating system.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))

            Divider().overlay(Color.white.opacity(0.2))

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Registers").font(.caption2.bold()).foregroundStyle(.white.opacity(0.4))
                    Text("ACC    \(String(format: "0x%02X", cpuState.accumulator))")
                    Text("PC     \(String(format: "0x%02X", cpuState.programCounter))")
                    Text("ZF     \(cpuState.zeroFlag ? "1" : "0")")
                    Text("CYCLES \(cpuState.cyclesExecuted)")
                }
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color(red: 0.55, green: 0.95, blue: 0.75))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Memory").font(.caption2.bold()).foregroundStyle(.white.opacity(0.4))
                    ForEach(Array(cpuState.memory.prefix(8).enumerated()), id: \.offset) { index, value in
                        Text("[\(index)] \(String(format: "0x%02X", value))")
                    }
                }
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color(red: 0.55, green: 0.95, blue: 0.75))
            }

            if let instruction = lastInstruction {
                Text("> \(instruction.disassembly)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.top, 6)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Shown once a real, validated boot sector was found and loaded — real
/// x86 registers, real console text the boot code actually printed via
/// `INT 10h`, and a plain-language readout of exactly how far execution
/// got. Coverage is intentionally partial (see X86InstructionSet.swift),
/// so stopping is an expected, honestly-reported outcome here, not a bug.
private struct X86MonitorView: View {
    let registers: X86Registers
    let consoleOutput: String
    let stopReason: X86StopReason
    let instructionsExecuted: Int
    let executionTrace: [String]
    let isWaitingForKey: Bool
    let isPaused: Bool
    let onKeyPress: (KeyEvent) -> Void

    @State private var typedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "cpu")
                Text("Real x86 Boot Execution")
                Spacer()
                if isPaused {
                    Text("PAUSED").font(.caption.bold()).foregroundStyle(.yellow)
                }
            }
            .font(.headline)
            .foregroundStyle(.white)

            Text("Executing real instructions read from your attached disc's boot sector. Coverage is intentionally partial — see the README for exactly what's implemented.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))

            statusBanner

            ScrollView {
                Text(consoleOutput.isEmpty ? "(no console output yet)" : consoleOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color(red: 0.55, green: 0.95, blue: 0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            .padding(8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            keyboardRow
            typedInputRow

            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Registers").font(.caption2.bold()).foregroundStyle(.white.opacity(0.4))
                    regLine("AX", registers.ax); regLine("BX", registers.bx)
                    regLine("CX", registers.cx); regLine("DX", registers.dx)
                    regLine("SI", registers.si); regLine("DI", registers.di)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Segments / IP").font(.caption2.bold()).foregroundStyle(.white.opacity(0.4))
                    regLine("CS", registers.cs); regLine("IP", registers.ip)
                    regLine("DS", registers.ds); regLine("SS", registers.ss)
                    regLine("SP", registers.sp)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Flags").font(.caption2.bold()).foregroundStyle(.white.opacity(0.4))
                    Text("CF\(bit(registers.cf)) ZF\(bit(registers.zf)) SF\(bit(registers.sf))")
                    Text("OF\(bit(registers.of)) IF\(bit(registers.interruptsEnabled)) DF\(bit(registers.directionFlag))")
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))

            if !executionTrace.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Instructions (address, raw bytes — not a disassembly)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white.opacity(0.4))
                    ForEach(Array(executionTrace.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }

            Text("\(instructionsExecuted) real instructions executed")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func regLine(_ name: String, _ value: UInt16) -> some View {
        Text("\(name)  \(String(format: "0x%04X", value))")
    }

    private func bit(_ value: Bool) -> String { value ? "1" : "0" }

    private var keyboardRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isWaitingForKey {
                Text("Waiting for a key — the guest is genuinely blocked here, not frozen.")
                    .font(.caption2.bold())
                    .foregroundStyle(.yellow)
            }
            HStack(spacing: 8) {
                keyButton(systemImage: "arrow.up", key: .upArrow)
                keyButton(systemImage: "arrow.down", key: .downArrow)
                keyButton(systemImage: "arrow.left", key: .leftArrow)
                keyButton(systemImage: "arrow.right", key: .rightArrow)
                keyButton(label: "Enter", key: .enter)
                keyButton(label: "Esc", key: .escape)
                keyButton(label: "Tab", key: .tab)
                keyButton(label: "Space", key: .space)
            }
        }
    }

    /// General typing, separate from the fixed navigation keys above —
    /// sends each character as its own KeyEvent in order. Deliberately
    /// does not also send Enter: typing and submitting stay two separate,
    /// predictable actions, with the existing Enter button covering the
    /// second one whenever the person actually wants to submit a line.
    private var typedInputRow: some View {
        HStack(spacing: 8) {
            TextField("Type and send…", text: $typedText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onSubmit(sendTypedText)
            Button("Send", action: sendTypedText)
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(typedText.isEmpty)
        }
    }

    private func sendTypedText() {
        for character in typedText {
            if let key = KeyEvent.typed(character) {
                onKeyPress(key)
            }
        }
        typedText = ""
    }

    private func keyButton(systemImage: String? = nil, label: String? = nil, key: KeyEvent) -> some View {
        Button {
            onKeyPress(key)
        } label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(label ?? "")
                }
            }
            .font(.caption.bold())
            .frame(minWidth: 32, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .tint(isWaitingForKey ? .yellow : .white)
    }

    private var statusBanner: some View {
        Group {
            switch stopReason {
            case .running:
                statusLine("Running", color: .green)
            case .halted:
                statusLine("Halted — the guest executed HLT. A clean, successful stop.", color: .blue)
            case .unsupportedOpcode(let op, let addr):
                statusLine("Stopped at \(addr) — opcode 0x\(String(format: "%02X", op)) isn't implemented.", color: .orange)
            case .unsupportedGroupOpcode(let op, let reg, let addr):
                statusLine("Stopped at \(addr) — 0x\(String(format: "%02X", op))/\(reg) isn't implemented.", color: .orange)
            case .unsupportedInterrupt(let vector, let addr):
                statusLine("Stopped at \(addr) — INT 0x\(String(format: "%02X", vector)) isn't implemented.", color: .orange)
            case .divideError(let addr):
                statusLine("Stopped at \(addr) — divide error (by zero, or a quotient too large).", color: .red)
            case .diskError(let message):
                statusLine("Disk error: \(message)", color: .red)
            }
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
