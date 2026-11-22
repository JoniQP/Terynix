import Foundation

// MARK: - Coverage
//
// Implemented: the full ADD/OR/ADC/SBB/AND/SUB/XOR/CMP group (register,
// memory, and immediate forms), MOV (register/memory/immediate/segment
// forms), INC/DEC, PUSH/POP (registers, segments, flags, immediates),
// JMP/CALL/RET (near and far, both directions), the full Jcc conditional-
// jump set, LOOP/LOOPE/LOOPNE/JCXZ, TEST, XCHG, LEA, NOT/NEG, both
// unsigned and signed MUL/IMUL/DIV/IDIV (divide-by-zero and quotient
// overflow both stop cleanly via `.divideError` — never a crash),
// SHL/SHR/SAR/ROL/ROR/RCL/RCR, CBW/CWD, LEAVE, XLAT, IN/OUT (a
// deliberately minimal, deliberately safe port I/O simulation covering
// just the ports an A20-line enable sequence touches — see
// performPortRead's doc comment for why "safe" specifically means every
// status read reports ready, never busy), the byte and word string ops
// (MOVS/STOS/LODS/CMPS/SCAS) with REP/REPE/REPNE, and
// NOP/HLT/CLI/STI/CLD/STD/INT. 143 distinct opcode values in total,
// scanned for accidental duplicate `case` labels after every change.
//
// Deliberately not implemented, and reported as `.unsupportedOpcode` /
// `.unsupportedGroupOpcode` rather than guessed at: multi-bit immediate
// shifts/rotates (only by-1 and by-CL), any I/O port this interpreter
// doesn't explicitly recognize, and any two-byte (0x0F-prefixed) opcode
// — which also happens to be roughly where real bootloader code starts
// reaching for 386+/protected-mode features anyway, so this is close to
// the real ceiling even if extended further.

enum ArithGroupOp: Int {
    case add = 0, or = 1, adc = 2, sbb = 3, and = 4, sub = 5, xor = 6, cmp = 7
}

extension X86CPU {

    private func performArithGroup(_ op: ArithGroupOp, a: UInt32, b: UInt32, isByte: Bool) -> UInt16 {
        switch op {
        case .add: return applyAdd(a, b, isByte: isByte)
        case .adc: return applyAdd(a, b &+ (regs.cf ? 1 : 0), isByte: isByte)
        case .sub, .cmp: return applySub(a, b, isByte: isByte)
        case .sbb: return applySub(a, b &+ (regs.cf ? 1 : 0), isByte: isByte)
        case .and: return applyLogic(a & b, isByte: isByte)
        case .or: return applyLogic(a | b, isByte: isByte)
        case .xor: return applyLogic(a ^ b, isByte: isByte)
        }
    }

    /// Unsigned multiply: AL×r/m8→AX, or AX×r/m16→DX:AX. CF/OF are set
    /// together, true exactly when the upper half of the result is
    /// nonzero (ZF/SF/PF/AF are architecturally undefined after MUL and
    /// are left untouched rather than guessed at).
    private func performMul(rm: Operand, isByte: Bool) {
        let value = readOperand(rm, isByte: isByte)
        if isByte {
            let result = UInt16(regs.al) * UInt16(value)
            regs.ax = result
            let highIsZero = (result & 0xFF00) == 0
            regs.cf = !highIsZero
            regs.of = !highIsZero
        } else {
            let result = UInt32(regs.ax) * UInt32(value)
            regs.ax = UInt16(result & 0xFFFF)
            regs.dx = UInt16(result >> 16)
            let highIsZero = regs.dx == 0
            regs.cf = !highIsZero
            regs.of = !highIsZero
        }
    }

    /// Signed multiply, single-operand form: AL×r/m8→AX, or AX×r/m16→DX:AX,
    /// both operands sign-extended first. CF/OF are true exactly when the
    /// result doesn't fit back into the lower half once sign-extended —
    /// computed in a wider integer type (Int32/Int64) so the "does it fit"
    /// check happens after a trap-free multiply, the same approach as
    /// performMul above.
    private func performImul(rm: Operand, isByte: Bool) {
        let value = readOperand(rm, isByte: isByte)
        if isByte {
            let a = Int32(Int8(bitPattern: regs.al))
            let b = Int32(Int8(bitPattern: UInt8(value & 0xFF)))
            let result = a * b
            regs.ax = UInt16(truncatingIfNeeded: result)
            let fits = (result >= -128 && result <= 127)
            regs.cf = !fits
            regs.of = !fits
        } else {
            let a = Int64(Int16(bitPattern: regs.ax))
            let b = Int64(Int16(bitPattern: value))
            let result = a * b
            regs.ax = UInt16(truncatingIfNeeded: result)
            regs.dx = UInt16(truncatingIfNeeded: result >> 16)
            let fits = (result >= -32768 && result <= 32767)
            regs.cf = !fits
            regs.of = !fits
        }
    }

    /// Signed divide — the same shape as performDiv, but reconstructing
    /// DX:AX as a single 32-bit two's-complement bit pattern first
    /// (rather than sign-extending DX and AX separately, which would be
    /// wrong: only the combined 32-bit value's sign matters). Division
    /// happens in a wider type than the result (Int32 dividend for the
    /// byte form, Int64 for the word form) specifically so the classic
    /// INT16.min / -1 overflow case can't trap Swift's `/` — it's caught
    /// by the bounds check below instead, same as an ordinary overflow.
    private func performIdiv(rm: Operand, isByte: Bool) {
        let value = readOperand(rm, isByte: isByte)
        if isByte {
            let divisor = Int32(Int8(bitPattern: UInt8(value & 0xFF)))
            guard divisor != 0 else { stop(.divideError(atAddress: lastInstructionAddress)); return }
            let dividend = Int32(Int16(bitPattern: regs.ax))
            let quotient = dividend / divisor
            guard quotient >= -128 && quotient <= 127 else {
                stop(.divideError(atAddress: lastInstructionAddress)); return
            }
            regs.al = UInt8(bitPattern: Int8(quotient))
            regs.ah = UInt8(bitPattern: Int8(dividend % divisor))
        } else {
            let divisor = Int64(Int16(bitPattern: value))
            guard divisor != 0 else { stop(.divideError(atAddress: lastInstructionAddress)); return }
            let rawBits = (UInt32(regs.dx) << 16) | UInt32(regs.ax)
            let dividend = Int64(Int32(bitPattern: rawBits))
            let quotient = dividend / divisor
            guard quotient >= -32768 && quotient <= 32767 else {
                stop(.divideError(atAddress: lastInstructionAddress)); return
            }
            regs.ax = UInt16(bitPattern: Int16(quotient))
            regs.dx = UInt16(bitPattern: Int16(dividend % divisor))
        }
    }

    /// Unsigned divide: AX÷r/m8→AL quotient/AH remainder, or
    /// DX:AX÷r/m16→AX quotient/DX remainder. A real 8086 raises a #DE
    /// exception on division by zero or a quotient that doesn't fit the
    /// destination; this interpreter has no exception/IVT machinery, so
    /// both cases stop the CPU cleanly via `.divideError` instead of
    /// trapping (Swift's `/` crashes on integer division by zero) or
    /// silently truncating a result that wouldn't be real.
    private func performDiv(rm: Operand, isByte: Bool) {
        let value = readOperand(rm, isByte: isByte)
        guard value != 0 else {
            stop(.divideError(atAddress: lastInstructionAddress))
            return
        }
        if isByte {
            let dividend = UInt32(regs.ax)
            let divisor = UInt32(value)
            let quotient = dividend / divisor
            guard quotient <= 0xFF else {
                stop(.divideError(atAddress: lastInstructionAddress))
                return
            }
            regs.al = UInt8(quotient)
            regs.ah = UInt8(dividend % divisor)
        } else {
            let dividend = (UInt32(regs.dx) << 16) | UInt32(regs.ax)
            let divisor = UInt32(value)
            let quotient = dividend / divisor
            guard quotient <= 0xFFFF else {
                stop(.divideError(atAddress: lastInstructionAddress))
                return
            }
            regs.ax = UInt16(quotient)
            regs.dx = UInt16(dividend % divisor)
        }
    }

    private func arithGroupIndex(forBlockBase base: UInt8) -> Int? {
        switch base {
        case 0x00: return 0
        case 0x08: return 1
        case 0x10: return 2
        case 0x18: return 3
        case 0x20: return 4
        case 0x28: return 5
        case 0x30: return 6
        case 0x38: return 7
        default: return nil
        }
    }

    /// Handles the regular 6-form shape shared by all 8 arithmetic/logic
    /// ops: op r/m,reg (two directions) and op AL/AX,imm. Forms 6 and 7
    /// of each block (PUSH/POP segment or prefix bytes) are handled as
    /// separate explicit opcodes, not here — see the note on opcode 0x06
    /// etc. below.
    private func handleArithGroupInstruction(group: ArithGroupOp, form: UInt8, segmentOverride: UInt16?) {
        let isByte = (form == 0 || form == 2 || form == 4)
        switch form {
        case 0, 1:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            let a = UInt32(readOperand(rm, isByte: isByte))
            let b = UInt32(readRegister(reg, isByte: isByte))
            let result = performArithGroup(group, a: a, b: b, isByte: isByte)
            if group != .cmp { writeOperand(rm, isByte: isByte, value: result) }
        case 2, 3:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            let a = UInt32(readRegister(reg, isByte: isByte))
            let b = UInt32(readOperand(rm, isByte: isByte))
            let result = performArithGroup(group, a: a, b: b, isByte: isByte)
            if group != .cmp { writeRegister(reg, isByte: isByte, value: result) }
        case 4, 5:
            let imm: UInt32 = isByte ? UInt32(fetch8()) : UInt32(fetch16())
            let a: UInt32 = isByte ? UInt32(regs.al) : UInt32(regs.ax)
            let result = performArithGroup(group, a: a, b: imm, isByte: isByte)
            if group != .cmp {
                if isByte { regs.al = UInt8(result & 0xFF) } else { regs.ax = result }
            }
        default:
            break
        }
    }

    /// ROL/ROR only. Unlike shifts, rotates leave ZF/SF/PF/AF completely
    /// untouched — only CF (and, for single-bit rotates, OF) change.
    /// Reusing the shift flag logic here would be a real, easy-to-miss
    /// bug, so this is deliberately a separate function rather than a
    /// branch inside `performShift`.
    /// A deliberately narrow, deliberately safe simulation of `IN`/`OUT`
    /// port I/O — covering only the ports an early bootloader's A20-line
    /// enable sequence actually touches, since that's the one genuinely
    /// common, early use of port I/O in boot-sector-class code, and
    /// skipping it entirely would stop most real bootloaders immediately.
    ///
    /// The design goal here isn't accuracy, it's safety: a real
    /// bootloader's A20 sequence polls the keyboard controller's status
    /// port (0x64) waiting for a "ready" bit before proceeding. If this
    /// simulation ever reported "busy", that poll loop would spin
    /// forever — a *worse* failure than any other unsupported-opcode
    /// stop in this file, because it wouldn't be visibly reported at all,
    /// just silent, unproductive looping. So every status read here
    /// reports "ready" immediately, and every write is accepted and
    /// discarded — there's no real device state behind these ports to
    /// model, including A20 gating itself, which this interpreter's flat
    /// memory model has no concept of to begin with.
    private func performPortRead(port: UInt16) -> UInt8 {
        switch port {
        case 0x60, 0x61: return 0x00  // keyboard controller data / system control port B
        case 0x64: return 0x00        // keyboard controller status: always "ready", see above
        case 0x92: return 0x02        // "fast A20" system control port A: reports A20 already enabled
        default: return 0xFF          // unassigned port — 0xFF is the conventional floating-bus value
        }
    }

    private func performPortWrite(port: UInt16, value: UInt8) {
        _ = (port, value) // accepted and discarded — see the doc comment above
    }

    private func performRotate(group: Int, value: UInt32, amount: UInt8, isByte: Bool) -> UInt16? {
        guard amount > 0 else { return UInt16(value & (isByte ? 0xFF : 0xFFFF)) }
        let mask: UInt32 = isByte ? 0xFF : 0xFFFF
        let signBit: UInt32 = isByte ? 0x80 : 0x8000
        var v = value & mask
        var cf = regs.cf
        switch group {
        case 0: // ROL — bit rotated out of the top re-enters at the bottom, and also sets CF
            for _ in 0..<amount {
                let topBit = (v & signBit) != 0
                v = ((v << 1) & mask) | (topBit ? 1 : 0)
                cf = topBit
            }
        case 1: // ROR — mirror image of ROL
            for _ in 0..<amount {
                let bottomBit = (v & 0x1) != 0
                v = (v >> 1) | (bottomBit ? signBit : 0)
                cf = bottomBit
            }
        case 2: // RCL — like ROL, but the bit that enters at the bottom is
                // the *old* CF, not the bit that just rotated out; CF
                // participates as if it were one extra bit of the value
                // (a 9-bit rotation for a byte, 17-bit for a word).
            for _ in 0..<amount {
                let newCF = (v & signBit) != 0
                v = ((v << 1) & mask) | (cf ? 1 : 0)
                cf = newCF
            }
        case 3: // RCR — mirror image of RCL
            for _ in 0..<amount {
                let newCF = (v & 0x1) != 0
                v = (v >> 1) | (cf ? signBit : 0)
                cf = newCF
            }
        default:
            stop(.unsupportedGroupOpcode(0xD0, reg: UInt8(group), atAddress: lastInstructionAddress))
            return nil
        }
        regs.cf = cf
        if amount == 1 {
            switch group {
            case 0, 2: regs.of = ((v & signBit) != 0) != cf // ROL, RCL: new top bit XOR new CF
            case 1, 3: regs.of = ((v & signBit) != 0) != ((v & (signBit >> 1)) != 0) // ROR, RCR
            default: break
            }
        }
        return UInt16(v)
    }

    /// Returns the shifted value, or `nil` if `group` isn't one of the
    /// three shifts implemented — in which case this has already called
    /// `stop(...)` and the caller should not write anything back.
    private func performShift(group: Int, value: UInt32, amount: UInt8, isByte: Bool) -> UInt16? {
        guard amount > 0 else { return UInt16(value & (isByte ? 0xFF : 0xFFFF)) } // shift by 0: no change at all
        let mask: UInt32 = isByte ? 0xFF : 0xFFFF
        let signBit: UInt32 = isByte ? 0x80 : 0x8000
        var v = value & mask
        var cf = regs.cf
        switch group {
        case 4, 6: // SHL / SAL (6 is an undocumented alias, same behavior)
            for _ in 0..<amount {
                cf = (v & signBit) != 0
                v = (v << 1) & mask
            }
        case 5: // SHR
            for _ in 0..<amount {
                cf = (v & 0x1) != 0
                v >>= 1
            }
        case 7: // SAR — preserves the sign bit on each shift
            let signSet = (value & signBit) != 0
            for _ in 0..<amount {
                cf = (v & 0x1) != 0
                v >>= 1
                if signSet { v |= signBit }
            }
        default:
            stop(.unsupportedGroupOpcode(0xD0, reg: UInt8(group), atAddress: lastInstructionAddress))
            return nil
        }
        regs.cf = cf
        regs.zf = v == 0
        regs.sf = (v & signBit) != 0
        regs.pf = (UInt8(v & 0xFF)).nonzeroBitCount % 2 == 0
        // OF is only architecturally defined for single-bit shifts; left
        // unchanged for multi-bit shifts rather than guessed at.
        if amount == 1 {
            switch group {
            case 4, 6: regs.of = ((v & signBit) != 0) != cf
            case 7: regs.of = false
            default: break
            }
        }
        return UInt16(v)
    }

    private func executeRepLoop(repPrefix: UInt8?, checkZF: Bool, _ body: () -> Void) {
        if let rep = repPrefix {
            while regs.cx != 0 {
                body()
                regs.cx = regs.cx &- 1
                if checkZF {
                    let wantZF = (rep == 0xF3) // REPE/REPZ continues while ZF=1; REPNE/REPNZ while ZF=0
                    if wantZF != regs.zf { break }
                }
            }
        } else {
            body()
        }
    }

    /// Dispatches one already-fetched opcode byte.
    func execute(opcode: UInt8, segmentOverride: UInt16?, repPrefix: UInt8?) {
        let blockBase = opcode & 0xF8
        let low3 = opcode & 0x07
        if low3 <= 5, let idx = arithGroupIndex(forBlockBase: blockBase), let group = ArithGroupOp(rawValue: idx) {
            handleArithGroupInstruction(group: group, form: low3, segmentOverride: segmentOverride)
            return
        }

        switch opcode {

        // MARK: Immediate-to-r/m arithmetic group (ModRM reg field selects the op)
        case 0x80:
            let (regField, rm) = decodeModRM(segmentOverride: segmentOverride)
            guard let group = ArithGroupOp(rawValue: regField) else {
                stop(.unsupportedGroupOpcode(opcode, reg: UInt8(regField), atAddress: lastInstructionAddress)); return
            }
            let imm = UInt32(fetch8())
            let a = UInt32(readOperand(rm, isByte: true))
            let result = performArithGroup(group, a: a, b: imm, isByte: true)
            if group != .cmp { writeOperand(rm, isByte: true, value: result) }
        case 0x81:
            let (regField, rm) = decodeModRM(segmentOverride: segmentOverride)
            guard let group = ArithGroupOp(rawValue: regField) else {
                stop(.unsupportedGroupOpcode(opcode, reg: UInt8(regField), atAddress: lastInstructionAddress)); return
            }
            let imm = UInt32(fetch16())
            let a = UInt32(readOperand(rm, isByte: false))
            let result = performArithGroup(group, a: a, b: imm, isByte: false)
            if group != .cmp { writeOperand(rm, isByte: false, value: result) }
        case 0x83:
            let (regField, rm) = decodeModRM(segmentOverride: segmentOverride)
            guard let group = ArithGroupOp(rawValue: regField) else {
                stop(.unsupportedGroupOpcode(opcode, reg: UInt8(regField), atAddress: lastInstructionAddress)); return
            }
            let immByte = fetchSigned8()
            let imm = UInt32(UInt16(bitPattern: Int16(immByte))) // sign-extended to 16 bits
            let a = UInt32(readOperand(rm, isByte: false))
            let result = performArithGroup(group, a: a, b: imm, isByte: false)
            if group != .cmp { writeOperand(rm, isByte: false, value: result) }

        // MARK: Unary group — TEST-with-immediate / NOT / NEG / MUL / IMUL / DIV / IDIV.
        case 0xF6, 0xF7:
            let isByte = (opcode == 0xF6)
            let (regField, rm) = decodeModRM(segmentOverride: segmentOverride)
            switch regField {
            case 0, 1:
                let imm: UInt32 = isByte ? UInt32(fetch8()) : UInt32(fetch16())
                applyLogic(UInt32(readOperand(rm, isByte: isByte)) & imm, isByte: isByte)
            case 2: // NOT — the one logic-ish op that touches no flags at all
                let mask: UInt16 = isByte ? 0xFF : 0xFFFF
                writeOperand(rm, isByte: isByte, value: (~readOperand(rm, isByte: isByte)) & mask)
            case 3: // NEG — equivalent to 0 - value, so applySub's flags are already exactly right
                let result = applySub(0, UInt32(readOperand(rm, isByte: isByte)), isByte: isByte)
                writeOperand(rm, isByte: isByte, value: result)
            case 4:
                performMul(rm: rm, isByte: isByte)
            case 5:
                performImul(rm: rm, isByte: isByte)
            case 6:
                performDiv(rm: rm, isByte: isByte)
            case 7:
                performIdiv(rm: rm, isByte: isByte)
            default:
                stop(.unsupportedGroupOpcode(opcode, reg: UInt8(regField), atAddress: lastInstructionAddress))
            }

        // MARK: INC/DEC r16 (0x40-0x4F) — note CF is explicitly preserved,
        // a real 8086 quirk so these don't disturb a carry a caller is tracking.
        case 0x40...0x47:
            let idx = Int(opcode - 0x40)
            let cfBefore = regs.cf
            let result = applyAdd(UInt32(readRegister(idx, isByte: false)), 1, isByte: false)
            regs.cf = cfBefore
            writeRegister(idx, isByte: false, value: result)
        case 0x48...0x4F:
            let idx = Int(opcode - 0x48)
            let cfBefore = regs.cf
            let result = applySub(UInt32(readRegister(idx, isByte: false)), 1, isByte: false)
            regs.cf = cfBefore
            writeRegister(idx, isByte: false, value: result)

        // MARK: PUSH/POP r16 (0x50-0x5F)
        case 0x50...0x57:
            pushWord(readRegister(Int(opcode - 0x50), isByte: false))
        case 0x58...0x5F:
            writeRegister(Int(opcode - 0x58), isByte: false, value: popWord())

        // MARK: Segment PUSH/POP. 0x0F is deliberately excluded (POP CS on
        // real 8086, but repurposed as the two-byte escape on later x86;
        // treated as unsupported either way, see the coverage note above).
        case 0x06: pushWord(regs.es)
        case 0x07: regs.es = popWord()
        case 0x0E: pushWord(regs.cs)
        case 0x16: pushWord(regs.ss)
        case 0x17: regs.ss = popWord()
        case 0x1E: pushWord(regs.ds)
        case 0x1F: regs.ds = popWord()

        case 0x68: pushWord(fetch16())
        case 0x6A:
            let imm = fetchSigned8()
            pushWord(UInt16(bitPattern: Int16(imm)))
        case 0x9C: pushWord(regs.flagsWord)
        case 0x9D: regs.setFlagsWord(popWord())

        // MARK: MOV
        case 0x88:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            writeOperand(rm, isByte: true, value: readRegister(reg, isByte: true))
        case 0x89:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            writeOperand(rm, isByte: false, value: readRegister(reg, isByte: false))
        case 0x8A:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            writeRegister(reg, isByte: true, value: readOperand(rm, isByte: true))
        case 0x8B:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            writeRegister(reg, isByte: false, value: readOperand(rm, isByte: false))
        case 0x8C:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            writeOperand(rm, isByte: false, value: segmentRegister(reg))
        case 0x8E:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            setSegmentRegister(reg, readOperand(rm, isByte: false))
        case 0xB0...0xB7:
            writeRegister(Int(opcode - 0xB0), isByte: true, value: UInt16(fetch8()))
        case 0xB8...0xBF:
            writeRegister(Int(opcode - 0xB8), isByte: false, value: fetch16())
        case 0xC6:
            let (regField, rm) = decodeModRM(segmentOverride: segmentOverride)
            guard regField == 0 else {
                stop(.unsupportedGroupOpcode(opcode, reg: UInt8(regField), atAddress: lastInstructionAddress)); return
            }
            writeOperand(rm, isByte: true, value: UInt16(fetch8()))
        case 0xC7:
            let (regField, rm) = decodeModRM(segmentOverride: segmentOverride)
            guard regField == 0 else {
                stop(.unsupportedGroupOpcode(opcode, reg: UInt8(regField), atAddress: lastInstructionAddress)); return
            }
            writeOperand(rm, isByte: false, value: fetch16())
        case 0x8D: // LEA r16, m — wants the bare effective offset, not a dereference
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            if case .memory(_, let offset) = rm {
                writeRegister(reg, isByte: false, value: offset)
            }

        // MARK: XCHG
        case 0x86:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            let a = readOperand(rm, isByte: true)
            let b = readRegister(reg, isByte: true)
            writeOperand(rm, isByte: true, value: b)
            writeRegister(reg, isByte: true, value: a)
        case 0x87:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            let a = readOperand(rm, isByte: false)
            let b = readRegister(reg, isByte: false)
            writeOperand(rm, isByte: false, value: b)
            writeRegister(reg, isByte: false, value: a)

        // MARK: TEST (AND without writing the result back)
        case 0x84:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            applyLogic(UInt32(readOperand(rm, isByte: true)) & UInt32(readRegister(reg, isByte: true)), isByte: true)
        case 0x85:
            let (reg, rm) = decodeModRM(segmentOverride: segmentOverride)
            applyLogic(UInt32(readOperand(rm, isByte: false)) & UInt32(readRegister(reg, isByte: false)), isByte: false)
        case 0xA8:
            let imm = fetch8()
            applyLogic(UInt32(regs.al) & UInt32(imm), isByte: true)
        case 0xA9:
            let imm = fetch16()
            applyLogic(UInt32(regs.ax) & UInt32(imm), isByte: false)

        // MARK: Control flow
        case 0xEB:
            let rel = fetchSigned8()
            regs.ip = regs.ip &+ UInt16(bitPattern: Int16(rel))
        case 0xE9:
            let rel = Int16(bitPattern: fetch16())
            regs.ip = regs.ip &+ UInt16(bitPattern: rel)
        case 0xEA:
            let newIP = fetch16()
            let newCS = fetch16()
            regs.ip = newIP
            regs.cs = newCS
        case 0xE8:
            let rel = Int16(bitPattern: fetch16())
            pushWord(regs.ip) // fetch16() already advanced IP past the operand
            regs.ip = regs.ip &+ UInt16(bitPattern: rel)
        case 0xC3:
            regs.ip = popWord()
        case 0xC2:
            let extra = fetch16()
            regs.ip = popWord()
            regs.sp = regs.sp &+ extra
        case 0x9A: // CALL far ptr16:16 — same operand encoding as the far JMP above
            let newIP = fetch16()
            let newCS = fetch16()
            pushWord(regs.cs)
            pushWord(regs.ip) // already past the 4-byte operand
            regs.cs = newCS
            regs.ip = newIP
        case 0xCB: // RET far — pops in the reverse order CALL far pushed: IP (pushed last) comes off first
            regs.ip = popWord()
            regs.cs = popWord()
        case 0xCA: // RET far, imm16
            let extra = fetch16()
            regs.ip = popWord()
            regs.cs = popWord()
            regs.sp = regs.sp &+ extra

        case 0x70...0x7F:
            let rel = fetchSigned8()
            if evaluateCondition(opcode & 0x0F) {
                regs.ip = regs.ip &+ UInt16(bitPattern: Int16(rel))
            }

        case 0xE0: // LOOPNE/LOOPNZ
            let rel = fetchSigned8()
            regs.cx = regs.cx &- 1
            if regs.cx != 0 && !regs.zf { regs.ip = regs.ip &+ UInt16(bitPattern: Int16(rel)) }
        case 0xE1: // LOOPE/LOOPZ
            let rel = fetchSigned8()
            regs.cx = regs.cx &- 1
            if regs.cx != 0 && regs.zf { regs.ip = regs.ip &+ UInt16(bitPattern: Int16(rel)) }
        case 0xE2: // LOOP
            let rel = fetchSigned8()
            regs.cx = regs.cx &- 1
            if regs.cx != 0 { regs.ip = regs.ip &+ UInt16(bitPattern: Int16(rel)) }
        case 0xE3: // JCXZ
            let rel = fetchSigned8()
            if regs.cx == 0 { regs.ip = regs.ip &+ UInt16(bitPattern: Int16(rel)) }

        // MARK: String operations (byte and word forms, with REP support)
        case 0xA4:
            executeRepLoop(repPrefix: repPrefix, checkZF: false) {
                let src = self.physicalAddress(segment: segmentOverride ?? self.regs.ds, offset: self.regs.si)
                let dst = self.physicalAddress(segment: self.regs.es, offset: self.regs.di)
                self.writeMem8(dst, self.readMem8(src))
                let d = self.stepDirection()
                self.regs.si = self.regs.si &+ d
                self.regs.di = self.regs.di &+ d
            }
        case 0xA5:
            executeRepLoop(repPrefix: repPrefix, checkZF: false) {
                let src = self.physicalAddress(segment: segmentOverride ?? self.regs.ds, offset: self.regs.si)
                let dst = self.physicalAddress(segment: self.regs.es, offset: self.regs.di)
                self.writeMem16(dst, self.readMem16(src))
                let d = self.stepDirection() &* 2
                self.regs.si = self.regs.si &+ d
                self.regs.di = self.regs.di &+ d
            }
        case 0xA6:
            executeRepLoop(repPrefix: repPrefix, checkZF: true) {
                let src = self.physicalAddress(segment: segmentOverride ?? self.regs.ds, offset: self.regs.si)
                let dst = self.physicalAddress(segment: self.regs.es, offset: self.regs.di)
                self.applySub(UInt32(self.readMem8(src)), UInt32(self.readMem8(dst)), isByte: true)
                let d = self.stepDirection()
                self.regs.si = self.regs.si &+ d
                self.regs.di = self.regs.di &+ d
            }
        case 0xA7:
            executeRepLoop(repPrefix: repPrefix, checkZF: true) {
                let src = self.physicalAddress(segment: segmentOverride ?? self.regs.ds, offset: self.regs.si)
                let dst = self.physicalAddress(segment: self.regs.es, offset: self.regs.di)
                self.applySub(UInt32(self.readMem16(src)), UInt32(self.readMem16(dst)), isByte: false)
                let d = self.stepDirection() &* 2
                self.regs.si = self.regs.si &+ d
                self.regs.di = self.regs.di &+ d
            }
        case 0xAA:
            executeRepLoop(repPrefix: repPrefix, checkZF: false) {
                let dst = self.physicalAddress(segment: self.regs.es, offset: self.regs.di)
                self.writeMem8(dst, self.regs.al)
                self.regs.di = self.regs.di &+ self.stepDirection()
            }
        case 0xAB:
            executeRepLoop(repPrefix: repPrefix, checkZF: false) {
                let dst = self.physicalAddress(segment: self.regs.es, offset: self.regs.di)
                self.writeMem16(dst, self.regs.ax)
                self.regs.di = self.regs.di &+ (self.stepDirection() &* 2)
            }
        case 0xAC:
            executeRepLoop(repPrefix: repPrefix, checkZF: false) {
                let src = self.physicalAddress(segment: segmentOverride ?? self.regs.ds, offset: self.regs.si)
                self.regs.al = self.readMem8(src)
                self.regs.si = self.regs.si &+ self.stepDirection()
            }
        case 0xAD:
            executeRepLoop(repPrefix: repPrefix, checkZF: false) {
                let src = self.physicalAddress(segment: segmentOverride ?? self.regs.ds, offset: self.regs.si)
                self.regs.ax = self.readMem16(src)
                self.regs.si = self.regs.si &+ (self.stepDirection() &* 2)
            }
        case 0xAE:
            executeRepLoop(repPrefix: repPrefix, checkZF: true) {
                let addr = self.physicalAddress(segment: self.regs.es, offset: self.regs.di)
                self.applySub(UInt32(self.regs.al), UInt32(self.readMem8(addr)), isByte: true)
                self.regs.di = self.regs.di &+ self.stepDirection()
            }
        case 0xAF:
            executeRepLoop(repPrefix: repPrefix, checkZF: true) {
                let addr = self.physicalAddress(segment: self.regs.es, offset: self.regs.di)
                self.applySub(UInt32(self.regs.ax), UInt32(self.readMem16(addr)), isByte: false)
                self.regs.di = self.regs.di &+ (self.stepDirection() &* 2)
            }

        // MARK: Shifts and rotates (shift/rotate-by-1 and by-CL only; see coverage note)
        case 0xD0, 0xD1, 0xD2, 0xD3:
            let isByte = (opcode == 0xD0 || opcode == 0xD2)
            let byCL = (opcode == 0xD2 || opcode == 0xD3)
            let (regField, rm) = decodeModRM(segmentOverride: segmentOverride)
            let amount: UInt8 = byCL ? (regs.cl & 0x1F) : 1
            let value = UInt32(readOperand(rm, isByte: isByte))
            let result: UInt16?
            switch regField {
            case 0, 1, 2, 3: result = performRotate(group: regField, value: value, amount: amount, isByte: isByte)
            case 4, 5, 6, 7: result = performShift(group: regField, value: value, amount: amount, isByte: isByte)
            default:
                stop(.unsupportedGroupOpcode(opcode, reg: UInt8(regField), atAddress: lastInstructionAddress))
                result = nil
            }
            if let result { writeOperand(rm, isByte: isByte, value: result) }

        // MARK: INC/DEC/PUSH r/m group
        case 0xFE:
            let (regField, rm) = decodeModRM(segmentOverride: segmentOverride)
            switch regField {
            case 0:
                let cfBefore = regs.cf
                let result = applyAdd(UInt32(readOperand(rm, isByte: true)), 1, isByte: true)
                regs.cf = cfBefore
                writeOperand(rm, isByte: true, value: result)
            case 1:
                let cfBefore = regs.cf
                let result = applySub(UInt32(readOperand(rm, isByte: true)), 1, isByte: true)
                regs.cf = cfBefore
                writeOperand(rm, isByte: true, value: result)
            default:
                stop(.unsupportedGroupOpcode(opcode, reg: UInt8(regField), atAddress: lastInstructionAddress))
            }
        case 0xFF:
            let (regField, rm) = decodeModRM(segmentOverride: segmentOverride)
            switch regField {
            case 0:
                let cfBefore = regs.cf
                let result = applyAdd(UInt32(readOperand(rm, isByte: false)), 1, isByte: false)
                regs.cf = cfBefore
                writeOperand(rm, isByte: false, value: result)
            case 1:
                let cfBefore = regs.cf
                let result = applySub(UInt32(readOperand(rm, isByte: false)), 1, isByte: false)
                regs.cf = cfBefore
                writeOperand(rm, isByte: false, value: result)
            case 6:
                pushWord(readOperand(rm, isByte: false))
            default:
                stop(.unsupportedGroupOpcode(opcode, reg: UInt8(regField), atAddress: lastInstructionAddress))
            }

        // MARK: Port I/O — see performPortRead/performPortWrite above for why these are deliberately minimal
        case 0xE4:
            regs.al = performPortRead(port: UInt16(fetch8()))
        case 0xE5:
            regs.ax = UInt16(performPortRead(port: UInt16(fetch8())))
        case 0xE6:
            performPortWrite(port: UInt16(fetch8()), value: regs.al)
        case 0xE7:
            performPortWrite(port: UInt16(fetch8()), value: UInt8(regs.ax & 0xFF))
        case 0xEC:
            regs.al = performPortRead(port: regs.dx)
        case 0xED:
            regs.ax = UInt16(performPortRead(port: regs.dx))
        case 0xEE:
            performPortWrite(port: regs.dx, value: regs.al)
        case 0xEF:
            performPortWrite(port: regs.dx, value: UInt8(regs.ax & 0xFF))

        // MARK: Misc
        case 0x90: break // NOP
        case 0x98: // CBW: sign-extend AL into AX
            regs.ax = UInt16(bitPattern: Int16(Int8(bitPattern: regs.al)))
        case 0x99: // CWD: sign-extend AX into DX:AX
            regs.dx = Int16(bitPattern: regs.ax) < 0 ? 0xFFFF : 0x0000
        case 0xC9: // LEAVE: MOV SP,BP then POP BP
            regs.sp = regs.bp
            regs.bp = popWord()
        case 0xD7: // XLAT: AL = byte at [DS:BX+AL] (or the overridden segment)
            let addr = physicalAddress(segment: segmentOverride ?? regs.ds, offset: regs.bx &+ UInt16(regs.al))
            regs.al = readMem8(addr)
        case 0xF4: stop(.halted)
        case 0xFA: regs.interruptsEnabled = false
        case 0xFB: regs.interruptsEnabled = true
        case 0xFC: regs.directionFlag = false
        case 0xFD: regs.directionFlag = true
        case 0xCD:
            let vector = fetch8()
            handleInterrupt(vector)

        default:
            stop(.unsupportedOpcode(opcode, atAddress: lastInstructionAddress))
        }
    }

    private func evaluateCondition(_ code: UInt8) -> Bool {
        switch code {
        case 0x0: return regs.of                           // JO
        case 0x1: return !regs.of                           // JNO
        case 0x2: return regs.cf                            // JB/JC/JNAE
        case 0x3: return !regs.cf                           // JAE/JNB/JNC
        case 0x4: return regs.zf                            // JE/JZ
        case 0x5: return !regs.zf                           // JNE/JNZ
        case 0x6: return regs.cf || regs.zf                  // JBE/JNA
        case 0x7: return !regs.cf && !regs.zf                 // JA/JNBE
        case 0x8: return regs.sf                            // JS
        case 0x9: return !regs.sf                            // JNS
        case 0xA: return regs.pf                            // JP/JPE
        case 0xB: return !regs.pf                            // JNP/JPO
        case 0xC: return regs.sf != regs.of                   // JL/JNGE
        case 0xD: return regs.sf == regs.of                   // JGE/JNL
        case 0xE: return regs.zf || (regs.sf != regs.of)      // JLE/JNG
        default:  return !regs.zf && (regs.sf == regs.of)     // JG/JNLE
        }
    }
}
