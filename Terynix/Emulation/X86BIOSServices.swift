import Foundation

/// One BIOS keyboard packet — the format `INT 16h` returns in AX: AH is
/// the scan code, AL is the ASCII value (0 for non-printing keys like
/// the arrows, which bootloader menus still read via the scan code).
struct KeyEvent: Sendable {
    let scanCode: UInt8
    let ascii: UInt8
}

/// Standard PC AT scan-code-set-1 values for the keys the session screen
/// offers — the ones a boot menu actually cares about (navigate, select,
/// cancel), not a full keyboard. Declared as static members on KeyEvent
/// itself (not a separate namespace) so call sites can use the `.enter`-
/// style shorthand, which only resolves against the expected type.
extension KeyEvent {
    static let upArrow = KeyEvent(scanCode: 0x48, ascii: 0x00)
    static let downArrow = KeyEvent(scanCode: 0x50, ascii: 0x00)
    static let leftArrow = KeyEvent(scanCode: 0x4B, ascii: 0x00)
    static let rightArrow = KeyEvent(scanCode: 0x4D, ascii: 0x00)
    static let enter = KeyEvent(scanCode: 0x1C, ascii: 0x0D)
    static let escape = KeyEvent(scanCode: 0x01, ascii: 0x1B)
    static let tab = KeyEvent(scanCode: 0x0F, ascii: 0x09)
    static let space = KeyEvent(scanCode: 0x39, ascii: 0x20)

    /// A typed character, for general input rather than the fixed keys
    /// above. Scan code is deliberately left at 0 rather than mapped to a
    /// specific physical key: real boot-time text input (a bootloader's
    /// command-line editor is the relevant case) reads the ASCII byte for
    /// printable characters and relies on the scan code only for
    /// non-printable/extended keys, which the dedicated buttons already
    /// cover correctly. Returns `nil` for characters with no ASCII
    /// representation rather than guessing at one.
    static func typed(_ character: Character) -> KeyEvent? {
        guard let ascii = character.asciiValue else { return nil }
        return KeyEvent(scanCode: 0, ascii: ascii)
    }
}

/// Simulates just enough BIOS interrupt behavior for a real-mode
/// bootloader to make progress: disk reads via the El Torito-style LBA
/// extensions (`INT 13h, AH=42h`), backed by real reads against the
/// actual attached ISO file; basic teletype console output
/// (`INT 10h, AH=0Eh`); and real keyboard input (`INT 16h`) fed by
/// whatever the session screen's on-screen keys send — enough for an
/// interactive boot menu to actually be navigable. Everything else is
/// reported back to the CPU as unsupported — see the extension below.
final class X86BIOSServices {
    private let isoFileHandle: FileHandle?
    private let sectorSizeBytes: Int
    private(set) var consoleOutput: String = ""
    private var keyQueue: [KeyEvent] = []

    /// - Parameters:
    ///   - isoFileURL: the real attached ISO disk reads are serviced from.
    ///   - sectorSizeBytes: 2048 for an El Torito boot (the ISO's native
    ///     CD sector size — the same convention `ISOBootInspector` uses
    ///     for the whole disc), or 512 for a hybrid-MBR boot, where the
    ///     image is treated as a raw block device with classic sectors.
    ///     See `BootSectorConvention`.
    init(isoFileURL: URL?, sectorSizeBytes: Int) {
        self.sectorSizeBytes = sectorSizeBytes
        if let url = isoFileURL {
            self.isoFileHandle = FileHandle(forReadingAtPath: url.path)
        } else {
            self.isoFileHandle = nil
        }
    }

    deinit {
        try? isoFileHandle?.close()
    }

    func teletypeOutput(character: UInt8) {
        defer { trimConsoleIfNeeded() }
        switch character {
        case 0x0D:
            break // bare CR dropped for display; LF below is what breaks the line
        case 0x0A:
            consoleOutput.append("\n")
        case 0x20..<0x7F:
            consoleOutput.append(Character(Unicode.Scalar(character)))
        default:
            break // other control characters (bell, backspace, ...) dropped — text-only console
        }
    }

    private func trimConsoleIfNeeded() {
        let limit = 4000
        if consoleOutput.count > limit {
            consoleOutput.removeFirst(consoleOutput.count - limit)
        }
    }

    /// Called from the UI when the person taps an on-screen key.
    func pressKey(_ key: KeyEvent) {
        guard keyQueue.count < 16 else { return } // a human tapping buttons won't realistically fill this
        keyQueue.append(key)
    }

    /// `INT 16h, AH=01h` semantics: look at the next key without removing it.
    func peekKey() -> KeyEvent? {
        keyQueue.first
    }

    /// `INT 16h, AH=00h` semantics: actually consume the next key.
    @discardableResult
    func popKey() -> KeyEvent? {
        keyQueue.isEmpty ? nil : keyQueue.removeFirst()
    }

    enum DiskReadResult {
        case success(bytes: [UInt8])
        case failure
    }

    /// Reads `count` sectors starting at `lba`, straight from the real
    /// attached ISO file.
    func readSectors(lba: UInt32, count: Int) -> DiskReadResult {
        guard let handle = isoFileHandle, count > 0 else { return .failure }
        let offset = UInt64(lba) * UInt64(sectorSizeBytes)
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count * sectorSizeBytes) else { return .failure }
            return .success(bytes: Array(data))
        } catch {
            return .failure
        }
    }
}

extension X86CPU {

    func handleInterrupt(_ vector: UInt8) {
        switch vector {
        case 0x10: handleVideoInterrupt()
        case 0x13: handleDiskInterrupt()
        case 0x16: handleKeyboardInterrupt()
        default:
            stop(.unsupportedInterrupt(vector, atAddress: lastInstructionAddress))
        }
    }

    private func handleVideoInterrupt() {
        switch regs.ah {
        case 0x0E:
            biosServices.teletypeOutput(character: regs.al)
            regs.cf = false
        case 0x00:
            // "Set video mode" — accepted as a no-op; this is a text-only console simulation.
            regs.cf = false
        default:
            stop(.unsupportedInterrupt(0x10, atAddress: lastInstructionAddress))
        }
    }

    private func handleDiskInterrupt() {
        switch regs.ah {
        case 0x00:
            regs.cf = false // reset disk system: always "succeeds"
        case 0x41:
            if regs.bx == 0x55AA {
                regs.bx = 0xAA55
                regs.ah = 0x30 // extensions version 3.0
                regs.cx = 0x0001 // bit 0: extended disk access functions supported
                regs.cf = false
            } else {
                regs.cf = true
            }
        case 0x42:
            performExtendedRead()
        default:
            // CHS-style reads (e.g. AH=02h) aren't how a real BIOS presents
            // an emulated CD drive — real El Torito bootloaders check for
            // and use the LBA extensions above specifically because CHS
            // geometry doesn't apply to a CD. A clean BIOS-style error
            // here is the honest, realistic response, not a gap to hide.
            regs.cf = true
            regs.ah = 0x01
        }
    }

    /// `INT 13h, AH=42h`: reads the Disk Address Packet pointed to by
    /// DS:SI (size@0, reserved@1, sector count@2-3, buffer offset@4-5,
    /// buffer segment@6-7, 64-bit LBA@8-15 — only the low 32 bits of the
    /// LBA are used here, more than enough for any realistic ISO size),
    /// and copies the real sectors it names into memory at that buffer.
    private func performExtendedRead() {
        let dap = physicalAddress(segment: regs.ds, offset: regs.si)
        let sectorCount = Int(readMem16(dap + 2))
        let bufferOffset = readMem16(dap + 4)
        let bufferSegment = readMem16(dap + 6)
        let lba = UInt32(readMem16(dap + 8)) | (UInt32(readMem16(dap + 10)) << 16)

        switch biosServices.readSectors(lba: lba, count: sectorCount) {
        case .success(let bytes):
            loadBytes(bytes, atPhysicalAddress: physicalAddress(segment: bufferSegment, offset: bufferOffset))
            regs.cf = false
            regs.ah = 0x00
        case .failure:
            regs.cf = true
            regs.ah = 0x04 // "sector not found"-style error
        }
    }

    private func handleKeyboardInterrupt() {
        switch regs.ah {
        case 0x00:
            isWaitingForKey = false
            if let key = biosServices.popKey() {
                regs.ax = (UInt16(key.scanCode) << 8) | UInt16(key.ascii)
            } else {
                // Genuinely wait: rewind past this instruction's 2 bytes
                // (opcode + vector) so the next step() re-executes the
                // same INT 16h call instead of fabricating a keypress.
                // From the guest's perspective this *is* what a real
                // blocking BIOS call looks like — execution simply
                // doesn't move on until a key arrives.
                regs.ip = regs.ip &- 2
                isWaitingForKey = true
            }
        case 0x01:
            if let key = biosServices.peekKey() {
                regs.zf = false
                regs.ax = (UInt16(key.scanCode) << 8) | UInt16(key.ascii)
            } else {
                regs.zf = true // "no key waiting" — lets a menu's timeout proceed on its own
            }
        default:
            stop(.unsupportedInterrupt(0x16, atAddress: lastInstructionAddress))
        }
    }
}
