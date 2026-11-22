import Foundation

// MARK: - What this file is, and what it deliberately is not
//
// `DemoPCEngine` is a tiny, fully-simulated 8-bit accumulator machine.
// It is NOT an x86, ARM, or any real CPU architecture emulator, and it
// cannot run a real operating system or a real ISO image.
//
// It exists so the demo PC screen has genuine, live computation to show
// — changing registers, a moving program counter, real memory writes —
// instead of a canned animation pretending to be one. Every value the
// session screen displays (see `DemoCPUState`) is actually computed by
// `step()`, not scripted.
//
// Real PC emulation (booting an actual Windows/Linux/DOS ISO) is a
// separate, much larger undertaking — see the project README for the
// current state of that investigation.

enum DemoOpcode: UInt8 {
    case noop = 0x00
    case loadImmediate = 0x01    // LOAD  #imm   -> ACC = imm
    case addImmediate = 0x02     // ADD   #imm   -> ACC += imm
    case storeToMemory = 0x03    // STORE addr   -> MEM[addr] = ACC
    case jumpIfZeroFlag = 0x04   // JZ    addr   -> if ACC == 0, PC = addr
    case decrement = 0x05        // DEC          -> ACC -= 1
    case jumpAlways = 0x06       // JMP   addr
    case halt = 0xFF
}

struct DemoInstruction {
    let opcode: DemoOpcode
    let operand: UInt8

    var disassembly: String {
        switch opcode {
        case .noop: return "NOP"
        case .loadImmediate: return "LOAD  #\(operand)"
        case .addImmediate: return "ADD   #\(operand)"
        case .storeToMemory: return "STORE [\(operand)]"
        case .jumpIfZeroFlag: return "JZ    \(operand)"
        case .decrement: return "DEC"
        case .jumpAlways: return "JMP   \(operand)"
        case .halt: return "HALT"
        }
    }
}

struct DemoCPUState {
    var accumulator: UInt8 = 0
    var programCounter: Int = 0
    var memory: [UInt8] = Array(repeating: 0, count: 16)
    var halted: Bool = false
    var cyclesExecuted: Int = 0

    var zeroFlag: Bool { accumulator == 0 }
}

/// Interprets a small, fixed demo program one instruction per `step()`
/// call. `VMSessionViewModel` drives stepping on a timer.
final class DemoPCEngine {
    private(set) var state = DemoCPUState()
    let program: [DemoInstruction]

    init() {
        // A counting-down loop: loads 5, then repeatedly decrements and
        // stores the result to memory cell 0 until it reaches zero, then
        // halts. Purely illustrative — chosen so the register and memory
        // panel visibly changes every couple of steps.
        program = [
            DemoInstruction(opcode: .loadImmediate, operand: 5),  // 0
            DemoInstruction(opcode: .storeToMemory, operand: 0),  // 1
            DemoInstruction(opcode: .jumpIfZeroFlag, operand: 7), // 2
            DemoInstruction(opcode: .decrement, operand: 0),      // 3
            DemoInstruction(opcode: .storeToMemory, operand: 0),  // 4
            DemoInstruction(opcode: .jumpAlways, operand: 2),     // 5
            DemoInstruction(opcode: .noop, operand: 0),           // 6 (unused)
            DemoInstruction(opcode: .halt, operand: 0)            // 7
        ]
    }

    func reset() {
        state = DemoCPUState()
    }

    /// Executes exactly one instruction and returns it, or `nil` if the
    /// machine is halted or has run off the end of the program.
    @discardableResult
    func step() -> DemoInstruction? {
        guard !state.halted else { return nil }
        guard program.indices.contains(state.programCounter) else {
            state.halted = true
            return nil
        }

        let instruction = program[state.programCounter]
        var nextPC = state.programCounter + 1

        switch instruction.opcode {
        case .noop:
            break
        case .loadImmediate:
            state.accumulator = instruction.operand
        case .addImmediate:
            state.accumulator = state.accumulator &+ instruction.operand
        case .storeToMemory:
            let addr = Int(instruction.operand)
            if state.memory.indices.contains(addr) {
                state.memory[addr] = state.accumulator
            }
        case .jumpIfZeroFlag:
            if state.zeroFlag {
                nextPC = Int(instruction.operand)
            }
        case .decrement:
            state.accumulator = state.accumulator &- 1
        case .jumpAlways:
            nextPC = Int(instruction.operand)
        case .halt:
            state.halted = true
        }

        state.programCounter = nextPC
        state.cyclesExecuted += 1
        return instruction
    }
}
