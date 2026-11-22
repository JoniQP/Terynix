import Foundation

// MARK: - What this file is, and isn't
//
// A real, from-scratch 8086-class 16-bit real-mode x86 interpreter:
// real registers, a real 1 MB memory space, real ModRM address decoding,
// and flag arithmetic worked out from first principles (see the ADD/SUB
// flag derivations below) rather than copied from somewhere uncheckable.
//
// Coverage is deliberately partial — see X86InstructionSet.swift for
// exactly which opcodes are implemented. Anything outside that set stops
// the CPU cleanly via `stopReason` rather than guessing or crashing.
// Real mode only: there is no protected-mode support here at all, which
// is also realistically where any real bootloader will take this CPU
// past what it can do — see the README.

struct X86Registers {
    var ax: UInt16 = 0
    var bx: UInt16 = 0
    var cx: UInt16 = 0
    var dx: UInt16 = 0
    var si: UInt16 = 0
    var di: UInt16 = 0
    var bp: UInt16 = 0
    var sp: UInt16 = 0
    var cs: UInt16 = 0
    var ds: UInt16 = 0
    var es: UInt16 = 0
    var ss: UInt16 = 0
    var ip: UInt16 = 0

    var cf = false
    var zf = false
    var sf = false
    var of = false
    var af = false
    var pf = false
    var interruptsEnabled = true
    var directionFlag = false // false = SI/DI step forward, true = backward

    var al: UInt8 {
        get { UInt8(ax & 0xFF) }
        set { ax = (ax & 0xFF00) | UInt16(newValue) }
    }
    var ah: UInt8 {
        get { UInt8(ax >> 8) }
        set { ax = (ax & 0x00FF) | (UInt16(newValue) << 8) }
    }
    var bl: UInt8 {
        get { UInt8(bx & 0xFF) }
        set { bx = (bx & 0xFF00) | UInt16(newValue) }
    }
    var bh: UInt8 {
        get { UInt8(bx >> 8) }
        set { bx = (bx & 0x00FF) | (UInt16(newValue) << 8) }
    }
    var cl: UInt8 {
        get { UInt8(cx & 0xFF) }
        set { cx = (cx & 0xFF00) | UInt16(newValue) }
    }
    var ch: UInt8 {
        get { UInt8(cx >> 8) }
        set { cx = (cx & 0x00FF) | (UInt16(newValue) << 8) }
    }
    var dl: UInt8 {
        get { UInt8(dx & 0xFF) }
        set { dx = (dx & 0xFF00) | UInt16(newValue) }
    }
    var dh: UInt8 {
        get { UInt8(dx >> 8) }
        set { dx = (dx & 0x00FF) | (UInt16(newValue) << 8) }
    }

    /// Packs the booleans above into the classic x86 FLAGS layout, for PUSHF.
    var flagsWord: UInt16 {
        var f: UInt16 = 0x0002 // bit 1 is reserved, always reads as 1
        if cf { f |= 0x0001 }
        if pf { f |= 0x0004 }
        if af { f |= 0x0010 }
        if zf { f |= 0x0040 }
        if sf { f |= 0x0080 }
        if interruptsEnabled { f |= 0x0200 }
        if directionFlag { f |= 0x0400 }
        if of { f |= 0x0800 }
        return f
    }

    mutating func setFlagsWord(_ f: UInt16) {
        cf = (f & 0x0001) != 0
        pf = (f & 0x0004) != 0
        af = (f & 0x0010) != 0
        zf = (f & 0x0040) != 0
        sf = (f & 0x0080) != 0
        interruptsEnabled = (f & 0x0200) != 0
        directionFlag = (f & 0x0400) != 0
        of = (f & 0x0800) != 0
    }
}

enum X86StopReason: Sendable, Equatable {
    case running
    case halted                                           // guest executed HLT — a clean, successful stop
    case unsupportedOpcode(UInt8, atAddress: String)
    case unsupportedGroupOpcode(UInt8, reg: UInt8, atAddress: String)
    case unsupportedInterrupt(UInt8, atAddress: String)
    case divideError(atAddress: String)                   // divide by zero, or a quotient too large for the destination
    case diskError(String)

    var isStopped: Bool { self != .running }
}

final class X86CPU {
    // Not private(set): Swift's access control is file-scoped, and the
    // CPU's own logic is deliberately split across X86CPU.swift,
    // X86InstructionSet.swift, and X86BIOSServices.swift for readability,
    // all of which need to mutate registers directly. Code outside the
    // Emulation layer (the view model) only ever reads this.
    var regs = X86Registers()
    private(set) var memory: [UInt8]
    private(set) var stopReason: X86StopReason = .running
    private(set) var instructionsExecuted = 0
    private(set) var lastInstructionAddress = ""
    /// A rolling log of recently-executed instructions: address plus the
    /// first 4 raw bytes there (prefix bytes included, if any), not a
    /// disassembly — consistent with the earlier decision not to build a
    /// real disassembler, since a wrong one would be worse than none.
    /// Capped so it can't grow without bound over a long session.
    private(set) var executionTrace: [String] = []
    private let maxTraceEntries = 200
    /// True while the guest is blocked in a genuinely-waiting `INT 16h,
    /// AH=00h` call with no key available yet — set and cleared by
    /// X86BIOSServices.swift's keyboard interrupt handler.
    var isWaitingForKey = false

    let biosServices: X86BIOSServices

    init(biosServices: X86BIOSServices) {
        self.memory = [UInt8](repeating: 0, count: 0x10_0000) // 1 MB real-mode address space
        self.biosServices = biosServices
    }

    /// Queues a keypress for the next `INT 16h` call to see — the only
    /// way keys reach the guest, called from the session screen's
    /// on-screen key buttons.
    func pressKey(_ key: KeyEvent) {
        biosServices.pressKey(key)
    }

    /// Copies bytes straight into memory at a physical address — used once,
    /// to load the boot sector at 0000:7C00 before execution starts.
    func loadBytes(_ bytes: [UInt8], atPhysicalAddress address: Int) {
        for (i, b) in bytes.enumerated() where address + i < memory.count {
            memory[address + i] = b
        }
    }

    // MARK: - Addressing

    func physicalAddress(segment: UInt16, offset: UInt16) -> Int {
        (Int(segment) << 4) + Int(offset)
    }

    func readMem8(_ address: Int) -> UInt8 {
        guard memory.indices.contains(address) else { return 0 }
        return memory[address]
    }
    func readMem16(_ address: Int) -> UInt16 {
        UInt16(readMem8(address)) | (UInt16(readMem8(address + 1)) << 8)
    }
    func writeMem8(_ address: Int, _ value: UInt8) {
        guard memory.indices.contains(address) else { return }
        memory[address] = value
    }
    func writeMem16(_ address: Int, _ value: UInt16) {
        writeMem8(address, UInt8(value & 0xFF))
        writeMem8(address + 1, UInt8(value >> 8))
    }

    func fetch8() -> UInt8 {
        let addr = physicalAddress(segment: regs.cs, offset: regs.ip)
        let b = readMem8(addr)
        regs.ip = regs.ip &+ 1
        return b
    }
    func fetch16() -> UInt16 {
        let lo = fetch8()
        let hi = fetch8()
        return UInt16(lo) | (UInt16(hi) << 8)
    }
    func fetchSigned8() -> Int8 {
        Int8(bitPattern: fetch8())
    }

    func pushWord(_ value: UInt16) {
        regs.sp = regs.sp &- 2
        writeMem16(physicalAddress(segment: regs.ss, offset: regs.sp), value)
    }
    func popWord() -> UInt16 {
        let value = readMem16(physicalAddress(segment: regs.ss, offset: regs.sp))
        regs.sp = regs.sp &+ 2
        return value
    }

    // MARK: - Operands

    /// A decoded ModRM operand. The memory case carries both the resolved
    /// physical address (for actual reads/writes) and the raw 16-bit
    /// effective offset before segment combination (needed by LEA, which
    /// wants the offset itself, not a dereferenceable address).
    enum Operand {
        case register(Int)
        case memory(address: Int, offset: UInt16)
    }

    /// Decodes a ModRM byte, consuming any displacement bytes it implies.
    /// Addressing-mode table and the mod=00/rm=110 direct-address special
    /// case follow the standard 8086 ModRM encoding exactly; segment
    /// defaults to SS only for the BP-based forms, DS otherwise, matching
    /// real hardware.
    func decodeModRM(segmentOverride: UInt16?) -> (reg: Int, rm: Operand) {
        let modrm = fetch8()
        let mod = (modrm >> 6) & 0x3
        let reg = Int((modrm >> 3) & 0x7)
        let rmField = Int(modrm & 0x7)

        if mod == 0b11 {
            return (reg, .register(rmField))
        }

        var usesBP = false
        var effectiveOffset: UInt16

        switch rmField {
        case 0: effectiveOffset = regs.bx &+ regs.si
        case 1: effectiveOffset = regs.bx &+ regs.di
        case 2: effectiveOffset = regs.bp &+ regs.si; usesBP = true
        case 3: effectiveOffset = regs.bp &+ regs.di; usesBP = true
        case 4: effectiveOffset = regs.si
        case 5: effectiveOffset = regs.di
        case 6:
            if mod == 0b00 {
                effectiveOffset = fetch16() // direct address, no base register
            } else {
                effectiveOffset = regs.bp
                usesBP = true
            }
        default: // 7
            effectiveOffset = regs.bx
        }

        switch mod {
        case 0b01:
            let disp = Int16(fetchSigned8())
            effectiveOffset = effectiveOffset &+ UInt16(bitPattern: disp)
        case 0b10:
            let disp = Int16(bitPattern: fetch16())
            effectiveOffset = effectiveOffset &+ UInt16(bitPattern: disp)
        default:
            break
        }

        let segment = segmentOverride ?? (usesBP ? regs.ss : regs.ds)
        let address = physicalAddress(segment: segment, offset: effectiveOffset)
        return (reg, .memory(address: address, offset: effectiveOffset))
    }

    func readRegister(_ index: Int, isByte: Bool) -> UInt16 {
        if isByte {
            switch index {
            case 0: return UInt16(regs.al)
            case 1: return UInt16(regs.cl)
            case 2: return UInt16(regs.dl)
            case 3: return UInt16(regs.bl)
            case 4: return UInt16(regs.ah)
            case 5: return UInt16(regs.ch)
            case 6: return UInt16(regs.dh)
            default: return UInt16(regs.bh)
            }
        }
        switch index {
        case 0: return regs.ax
        case 1: return regs.cx
        case 2: return regs.dx
        case 3: return regs.bx
        case 4: return regs.sp
        case 5: return regs.bp
        case 6: return regs.si
        default: return regs.di
        }
    }

    func writeRegister(_ index: Int, isByte: Bool, value: UInt16) {
        if isByte {
            let b = UInt8(value & 0xFF)
            switch index {
            case 0: regs.al = b
            case 1: regs.cl = b
            case 2: regs.dl = b
            case 3: regs.bl = b
            case 4: regs.ah = b
            case 5: regs.ch = b
            case 6: regs.dh = b
            default: regs.bh = b
            }
            return
        }
        switch index {
        case 0: regs.ax = value
        case 1: regs.cx = value
        case 2: regs.dx = value
        case 3: regs.bx = value
        case 4: regs.sp = value
        case 5: regs.bp = value
        case 6: regs.si = value
        default: regs.di = value
        }
    }

    func readOperand(_ op: Operand, isByte: Bool) -> UInt16 {
        switch op {
        case .register(let idx): return readRegister(idx, isByte: isByte)
        case .memory(let addr, _): return isByte ? UInt16(readMem8(addr)) : readMem16(addr)
        }
    }

    func writeOperand(_ op: Operand, isByte: Bool, value: UInt16) {
        switch op {
        case .register(let idx): writeRegister(idx, isByte: isByte, value: value)
        case .memory(let addr, _):
            if isByte { writeMem8(addr, UInt8(value & 0xFF)) } else { writeMem16(addr, value) }
        }
    }

    func segmentRegister(_ index: Int) -> UInt16 {
        switch index & 0x3 {
        case 0: return regs.es
        case 1: return regs.cs
        case 2: return regs.ss
        default: return regs.ds
        }
    }
    func setSegmentRegister(_ index: Int, _ value: UInt16) {
        switch index & 0x3 {
        case 0: regs.es = value
        case 1: regs.cs = value
        case 2: regs.ss = value
        default: regs.ds = value
        }
    }

    // MARK: - Flag arithmetic
    //
    // Derived from first principles rather than transcribed, and checked
    // against worked examples:
    //   ADD 0x7F+0x01 (8-bit): result 0x80, OF must be true (127+1 signed-
    //     overflows to -128). (a^result)&(b^result)&signBit:
    //     (0x7F^0x80)&(0x01^0x80) = 0xFF & 0x81 = 0x81; &0x80 = 0x80 ≠ 0. ✓.
    //   SUB 0x80-0x01 (8-bit): result 0x7F, OF must be true (-128-1
    //     overflows to +127). (a^b)&(a^result)&signBit:
    //     (0x80^0x01)&(0x80^0x7F) = 0x81&0xFF = 0x81; &0x80 ≠ 0. ✓.
    //   SUB 0x01-0x02: CF must be true (borrow). a<b → 1<2 → true. ✓.

    private func parity(_ byte: UInt8) -> Bool {
        byte.nonzeroBitCount % 2 == 0
    }

    @discardableResult
    func applyAdd(_ a: UInt32, _ b: UInt32, isByte: Bool) -> UInt16 {
        let mask: UInt32 = isByte ? 0xFF : 0xFFFF
        let signBit: UInt32 = isByte ? 0x80 : 0x8000
        let sum = a + b
        let result = sum & mask
        regs.cf = sum > mask
        regs.zf = result == 0
        regs.sf = (result & signBit) != 0
        regs.of = (((a ^ result) & (b ^ result)) & signBit) != 0
        regs.af = ((a & 0xF) + (b & 0xF)) > 0xF
        regs.pf = parity(UInt8(result & 0xFF))
        return UInt16(result)
    }

    @discardableResult
    func applySub(_ a: UInt32, _ b: UInt32, isByte: Bool) -> UInt16 {
        let mask: UInt32 = isByte ? 0xFF : 0xFFFF
        let signBit: UInt32 = isByte ? 0x80 : 0x8000
        let result = (a &- b) & mask
        regs.cf = a < b
        regs.zf = result == 0
        regs.sf = (result & signBit) != 0
        regs.of = (((a ^ b) & (a ^ result)) & signBit) != 0
        regs.af = (a & 0xF) < (b & 0xF)
        regs.pf = parity(UInt8(result & 0xFF))
        return UInt16(result)
    }

    @discardableResult
    func applyLogic(_ result: UInt32, isByte: Bool) -> UInt16 {
        let mask: UInt32 = isByte ? 0xFF : 0xFFFF
        let signBit: UInt32 = isByte ? 0x80 : 0x8000
        let r = result & mask
        regs.cf = false
        regs.of = false
        regs.zf = r == 0
        regs.sf = (r & signBit) != 0
        regs.pf = parity(UInt8(r & 0xFF))
        return UInt16(r)
    }

    func stepDirection() -> UInt16 {
        regs.directionFlag ? UInt16(bitPattern: -1) : 1
    }

    func currentAddressString() -> String {
        String(format: "%04X:%04X", regs.cs, regs.ip)
    }

    private func recordTraceEntry() {
        let addr = physicalAddress(segment: regs.cs, offset: regs.ip)
        let bytes = (0..<4).map { readMem8(addr + $0) }
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        executionTrace.append("\(currentAddressString())  \(hex)")
        if executionTrace.count > maxTraceEntries {
            executionTrace.removeFirst(executionTrace.count - maxTraceEntries)
        }
    }

    func stop(_ reason: X86StopReason) {
        guard !stopReason.isStopped else { return } // first stop reason wins
        stopReason = reason
    }

    // MARK: - Fetch/execute loop

    /// Executes exactly one instruction, including any prefix bytes
    /// ahead of it. No-op once `stopReason` is anything but `.running`.
    func step() {
        guard !stopReason.isStopped else { return }
        recordTraceEntry()

        var segmentOverride: UInt16?
        var repPrefix: UInt8?

        prefixLoop: while true {
            let probe = readMem8(physicalAddress(segment: regs.cs, offset: regs.ip))
            switch probe {
            case 0x26: segmentOverride = regs.es; regs.ip = regs.ip &+ 1
            case 0x2E: segmentOverride = regs.cs; regs.ip = regs.ip &+ 1
            case 0x36: segmentOverride = regs.ss; regs.ip = regs.ip &+ 1
            case 0x3E: segmentOverride = regs.ds; regs.ip = regs.ip &+ 1
            case 0xF2, 0xF3: repPrefix = probe; regs.ip = regs.ip &+ 1
            case 0xF0: regs.ip = regs.ip &+ 1 // LOCK — accepted, meaningless on a single-core interpreter
            default: break prefixLoop
            }
        }

        lastInstructionAddress = currentAddressString()
        let opcode = fetch8()
        execute(opcode: opcode, segmentOverride: segmentOverride, repPrefix: repPrefix)

        if !stopReason.isStopped {
            instructionsExecuted += 1
        }
    }
}
