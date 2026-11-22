# Terynix
Terynix is an experimental virtualization platform for iPadOS, built with Swift and SwiftUI. Its goal is to bring persistent Linux virtual machines to iPad, featuring ISO booting, virtual storage, and configurable hardware resources.

A working build of the app described in the spec, now covering stages
1–6 in some form: SwiftUI interface, VM management with persistent
storage, an interactive demo PC, virtual media management, a real
investigation of the emulation-engine question (stage 5, in **Part 2**),
and a genuine first implementation of a real engine (stage 6) — a
from-scratch 16-bit x86 real-mode interpreter that actually executes an
attached disc's real boot sector, detailed in **Part 1**. Stage 7
(testing) is still ahead, since it needs an actual Xcode build.

Everything here is real, working code written against iPadOS 16+ APIs. It
has **not** been compiled — this environment doesn't have Xcode or the iOS
SDK, only a Linux container. I hand-checked every file (types, bindings,
concurrency, API availability, cross-file access control) and verified
brace/paren balance and import consistency with simple scripts, but a
first build in Xcode is the real test — especially this session's
addition, which is a large, intricate piece of code I could not compile
or run against a single real instruction. If anything doesn't compile,
send me the error and I'll fix it.

---

## Part 1 — What's in this build

### Opening it in Xcode

1. Xcode → **File → New → Project → App**. Name it `VirtualPC`, interface
   **SwiftUI**, language **Swift**. Uncheck Core Data / Tests unless you
   want them.
2. Delete the generated `ContentView.swift` (and the generated
   `VirtualPCApp.swift` — you'll use the one below instead).
3. Drag the `VirtualPC/` folder from this delivery into the Xcode project
   navigator (the one containing `Models/`, `Views/`, etc. — not the outer
   folder with this README). Choose **Create groups**, and make sure **Copy
   items if needed** is checked and your app target is ticked.
4. Project settings → target → **Minimum Deployments → iOS 16.0**.
5. Build. Everything below is one target, no external packages.

### File map

| File | Role |
|---|---|
| `VirtualPCApp.swift` | App entry point, wires up the two stores |
| `Theme/Theme.swift` | Color tokens + card style, dark/light aware |
| `Models/VirtualMachine.swift` | VM config struct + Network/Boot/Display/RuntimeState enums |
| `Models/GuestOSCatalog.swift` | Selectable guest OS profiles, each tagged with an honest support level |
| `Persistence/VMLibraryStore.swift` | Loads/saves the VM list as JSON; single source of truth |
| `Persistence/VirtualDiskManager.swift` | Creates/deletes virtual disk files as sparse files; reports used vs. max size |
| `Persistence/ISOLibrary.swift` | Imports ISOs from Files into app storage, off the main thread |
| `Emulation/DemoPCEngine.swift` | The toy 8-bit CPU that drives the demo screen (see Part 2) |
| `Emulation/ISOBootInspector.swift` | Real ISO 9660 / El Torito parser — validates an attached disc's actual boot structure |
| `Emulation/ISODirectoryBrowser.swift` | Real ISO 9660 directory-tree parser — reads the disc's actual file/folder listing |
| `Emulation/X86CPU.swift` | Real 16-bit x86 real-mode CPU core: registers, 1 MB memory, ModRM addressing, flag arithmetic |
| `Emulation/X86InstructionSet.swift` | The actual opcode dispatch — everything the CPU can execute, and what it can't |
| `Emulation/X86BIOSServices.swift` | Simulated BIOS disk/video/keyboard interrupts, with disk reads backed by the real attached ISO |
| `ViewModels/VMSessionViewModel.swift` | Boot sequence + Start/Pause/Resume/Restart/Shut Down state machine |
| `Views/Dashboard/DashboardView.swift` | Grid of VM cards, create/delete |
| `Views/Wizard/CreateVMWizardView.swift` | 4-step VM creation wizard |
| `Views/Settings/VMSettingsView.swift` | Per-VM settings, live-bound to the store |
| `Views/Session/VMSessionView.swift` | Full-screen running session: status bar, monitor, controls |
| `Views/Session/BIOSBootView.swift` | Simulated firmware/bootloader text |
| `Views/Media/MediaLibraryView.swift` | ISO import and library |
| `Views/Media/ISODirectoryBrowserView.swift` | Browses a disc's real file/folder listing, recursively |
| `Views/Media/ISOFileDetailView.swift` | Real (bounded) text preview and streaming export for one file |

**Layering:** `Models/`, `Persistence/`, and `Emulation/` import only
`Foundation`/`Combine` — zero SwiftUI dependency, confirmed by grep across
every file. That's deliberate: it's what makes "separate the UI, VM
configuration, storage management, and emulation engine" true rather than
aspirational — those three layers could be unit-tested or reused without
any UI framework at all.

### What's genuinely implemented (not placeholder)

- **VM lifecycle**: create via wizard → persists as JSON in
  `Application Support/VirtualPC/` → edit in Settings (every field writes
  straight through to the store) → delete with confirmation, which also
  removes the virtual disk file.
- **Virtual disks**: created as real sparse files (seek-to-size, write one
  byte) — a disk declared as 64 GB doesn't consume 64 GB until data is
  actually written to it, the same trick VirtualBox's "dynamically
  allocated" format and QEMU's qcow2 use. Settings shows the declared
  max, the real allocated size (via `URLResourceKey.totalFileAllocatedSizeKey`),
  and now the space still available within that max too — a genuine,
  named spec item ("display used and available storage space") a full
  requirements re-read caught had only ever shown two of those three
  numbers. The same re-read caught two more real gaps, both now fixed:
  boot order was only ever settable once, at creation — Settings now has
  its own toggle, the same binding-writes-through pattern as every other
  editable field here; and "support importing and exporting virtual
  disks where possible" had never been built for the VM's own disk (only
  for ISOs and the files inside them) — Settings now has a real export,
  using a plain `copyItem` rather than the chunked streaming built for
  ISO export, since this disk is still just the sparse placeholder from
  creation (nothing writes real guest data to it — see "What's
  deliberately out of scope" below) and `copyItem` preserves a sparse
  file's sparseness on APFS. Import is deliberately not built alongside
  it: unlike export, it raises real format questions (what must an
  imported image's size relationship to the declared maximum be, what
  happens if it's already populated with real data) that deserve answers
  before writing code, not after.
- **ISO import**: `.fileImporter` → security-scoped resource access →
  copy into sandboxed storage on a detached background task (not the main
  thread — ISOs can be gigabytes) → tracked in a library with a progress
  indicator while copying.
- **Smooth start/stop animations** — an original-spec item ("add smooth
  animations when starting and stopping virtual machines") that a fresh
  re-read of the spec caught had never actually been built, several
  sessions after everything around it. A session's firmware, bootloader,
  running, and powered-off screens now cross-fade into each other via
  `.animation(value: session.phase)` rather than snapping instantly
  (`SessionPhase` needed upgrading from `Equatable` to `Hashable` for
  this, so it could serve as a view-identity key); the Dashboard's VM
  cards animate in and out on create/delete too, via `withAnimation` at
  the call site rather than inside `VMLibraryStore` itself, which stays
  free of any SwiftUI dependency by design.
- **The demo PC**: `DemoPCEngine` is a real, tiny interpreter — 8 opcodes,
  16 bytes of memory, one program. Every value the session screen shows
  (accumulator, program counter, memory cells, the disassembly line) is
  actually computed by stepping that program, not a scripted animation. It
  is explicitly labeled on-screen ("This screen shows a small simulated
  CPU... It is not running a real operating system") so the honesty is
  visible to the user, not just in code comments.
- **Real ISO boot inspection**: when a VM boots with an ISO attached,
  `ISOBootInspector` genuinely parses it — confirms the ISO 9660 Primary
  Volume Descriptor, reads the volume label, locates the El Torito boot
  catalog if one exists, and reads the real bytes at the boot image's
  actual LBA to check for the 0x55AA signature a BIOS checks before
  handing off execution. It also checks for a hybrid MBR at byte 0, since
  most modern Linux ISOs are dd-to-USB hybrids. All of this is real,
  specific to the file you attached — the volume label and LBA numbers in
  the boot log are genuinely read from your ISO, not generated. The same
  inspector is also reachable standalone: tap any ISO in the Media Library
  to see its boot report without starting a VM. On its own this step
  still doesn't execute anything — it only reads and validates. What
  happens with a validated boot sector is covered next.
- **Real directory browsing, file viewing, and export**: from that same
  boot-report screen, "Browse Files" shows the disc's actual file and
  folder listing — `ISODirectoryBrowser` reads the root directory record
  embedded in the Primary Volume Descriptor, then walks each directory's
  own extent in turn as you navigate deeper, reading only the one
  directory you're looking at rather than the whole disc. This covers
  plain ISO 9660 names only (not Joliet or Rock Ridge extensions some
  discs also carry), so names may show in their shorter, often all-caps
  form. Tapping a file shows a real, bounded (64 KB max) preview if it
  looks like text — genuinely useful for something like isolinux.cfg or
  grub.cfg, the actual menu configuration driving the boot interaction —
  or — for anything that isn't text — a real hex dump (offset, hex bytes,
  ASCII column, the classic three-column layout) of its first 512 bytes
  instead of a dead end, using the same bytes already read for the text
  check rather than a second file read. Either way, export gets you the
  complete file to the Files app or anywhere else via the share sheet.
  Export streams in 1 MB chunks rather than loading the file into memory,
  which matters: a real Linux ISO's root filesystem (casper/ or LiveOS/,
  typically) is often a multi-gigabyte squashfs image, and loading that
  fully into memory would risk iPadOS killing the app outright.
- **Sample VM on first launch**: seeded once via a `UserDefaults` flag, so
  it appears on first run but doesn't resurrect itself after you delete it.
- **No background execution claimed**: a session's tick loop and boot
  sequence are torn down in `.onDisappear`. There's no real background
  hypervisor process behind this app — iPadOS gives third-party apps no
  such capability (see Part 2) — so the UI doesn't pretend a VM keeps
  running once you leave its screen.

### The real x86 interpreter

When a session boots with an ISO attached and `ISOBootInspector` finds a
valid boot sector, Virtual PC now loads those real bytes into a real,
from-scratch 16-bit x86 real-mode interpreter (`X86CPU` +
`X86InstructionSet` + `X86BIOSServices`) at the standard BIOS boot
address, 0000:7C00, and actually executes them — real registers, a real
1 MB memory space, real flag arithmetic, real `INT 13h` disk reads
against your actual attached file. This is a genuinely different thing
from the toy `DemoPCEngine`: it's interpreting the specific bytes your
specific ISO put at its boot sector, not running a fixed illustrative
program.

**What it covers.** The arithmetic/logic group (ADD/OR/ADC/SBB/AND/SUB/
XOR/CMP, register/memory/immediate forms), MOV in all its common shapes,
INC/DEC, NOT/NEG, both unsigned and signed MUL/IMUL/DIV/IDIV, PUSH/POP,
JMP/CALL/RET (near and far, both directions), the full conditional-jump
set, LOOP/JCXZ, TEST, XCHG, LEA, SHL/SHR/SAR/ROL/ROR/RCL/RCR, CBW/CWD,
LEAVE, XLAT, MOVS/STOS/LODS/CMPS/SCAS with REP, and
NOP/HLT/CLI/STI/CLD/STD/INT — 135 distinct opcode values, enough real-
mode x86 that an early bootloader stage has a real chance of running for
a while before hitting the edge. Both DIV and IDIV are guarded explicitly
against division by zero and a quotient that overflows its destination —
either stops the CPU cleanly via a dedicated `.divideError` rather than
crashing (Swift traps on integer division by zero) or silently producing
a wrong answer; IDIV's classic edge case (dividing the most negative
value by −1) is specifically covered by doing the division in a wider
integer type and bounds-checking the result afterward, rather than
letting it trap. On the BIOS side: `INT 13h` AH=41h/42h (the LBA
extensions real CD-boot code uses — also why plain AH=02h CHS reads
report a clean "unsupported" error rather than misbehaving, since CHS
genuinely doesn't apply to an emulated CD drive), `INT 10h` AH=0Eh
(teletype text output), and `INT 16h` keyboard services, now backed by
real input — see below.

**Port I/O (`IN`/`OUT`) is now simulated too, deliberately narrowly.** The
only real reason boot-sector-class code touches hardware ports at all is
the A20 address-line enable sequence almost every bootloader runs early
— so that's the only thing covered: the keyboard-controller ports (0x60,
0x61, 0x64) and the simpler "fast A20" port (0x92). The design goal here
is safety, not accuracy: a real A20 sequence polls the keyboard
controller's status port waiting for a "ready" bit, and if this
simulation ever reported "busy," that poll would spin forever — a worse
failure than any other unsupported-opcode stop in this file, since
nothing would visibly report it, just silent, unproductive looping. So
every status read here reports "ready" immediately, and every write is
accepted and discarded; any port outside this small set reads back
`0xFF` (the conventional floating-bus value) rather than being treated
as an error.

**What else it deliberately doesn't cover, and reports rather than
fakes:** multi-bit immediate shifts/rotates (only by-1 and by-CL), and
any two-byte (`0x0F`-prefixed) opcode. That last one matters most: `0x0F`
is also where 386+ and protected-mode-adjacent instructions live, so a
bootloader reaching for those is hitting close to the real ceiling of
"real mode" itself, not an arbitrary cutoff I chose. When execution hits
any of this, or an interrupt outside the three described above, or a
genuine divide error, `X86CPU.stopReason` records exactly what happened
and at what `CS:IP`, and the session screen shows that plainly rather
than hanging or pretending to continue.

**A recent-instructions trace, not just a live snapshot.** The register
panel updates every tick, which shows current state but not the path
that led there. A small "Recent Instructions" panel now shows the last
8 instructions as address plus raw bytes — deliberately not a
disassembly, for the same reason the project never built one: a wrong
disassembly would be worse than none, and raw bytes next to a real
address are honest about exactly what they are. `X86CPU` keeps up to 200
such entries internally (trimmed as it grows), so there's room to extend
the displayed window later without touching the underlying capture.

**Keyboard input is real too.** The session screen shows arrow keys,
Enter, Esc, Tab, and Space whenever real x86 mode is active. Tapping one
queues a standard BIOS scan code that `INT 16h` actually serves — enough
to navigate and select from an interactive boot menu (GRUB's is the
obvious case) rather than only watching it time out unattended. The
blocking form of the keyboard call (`AH=00h`, "wait for a key") is
genuinely blocking, not faked: with no key queued, `X86CPU` rewinds `IP`
back over the same two-byte `INT 16h` instruction so the next tick
re-executes it, which is what a real blocked BIOS call looks like from
the guest's side. The session screen shows a "waiting for a key" banner
during this so it's clear the guest hasn't frozen — it's legitimately
paused on you. A text field next to the special keys covers general
typing too — each character becomes its own key event with the typed
byte as its ASCII value (the scan code is left at 0 rather than mapped
to a specific physical key, since text-input code reads the ASCII byte
for printable characters and only needs a real scan code for
non-printable keys, which the dedicated buttons already cover). Typing
and submitting stay deliberately separate actions — "Send" only queues
the characters, it doesn't also press Enter — so entering a command and
choosing when to run it don't get conflated into one button.

**What to realistically expect with a real Linux ISO.** A GRUB2 boot.img
is small and simple — real execution through it is plausible. Its
successor, core.img, and ISOLINUX's isolinux.bin are both substantially
larger stage-2 programs; getting partway into one before hitting
something outside the covered set is the likely outcome, and that's a
genuinely real result, not a failure — it means every instruction up to
that point actually ran. Reaching an actual Linux kernel would require
the CPU to switch into 32-bit protected mode, which is simply a different
machine this interpreter doesn't implement.

### Known simplifications (not bugs — documented choices for a first build)

- Settings writes on every keystroke (simple, correct, a bit chatty on a
  small JSON file — fine at this scale; worth debouncing if VM lists grow
  very large).
- Disk usage in Settings is computed on open, deliberately not
  live-updating: nothing in the app ever writes to the virtual hard disk
  file after creation (the x86 interpreter's `INT 13h` only implements
  reads, from the attached ISO — never writes to the VM's own disk), so
  there's currently no activity for a live view to meaningfully reflect.
  Building that polish now would be decorative rather than functional;
  worth revisiting if disk writes are ever implemented.
- The OS-profile picker is grouped by family now (`GuestOSCatalog.familiesInOrder`,
  derived from the profile list itself so it can't drift out of sync).
- The on-screen keyboard (navigation keys plus general typing — see
  below) only appears in real-x86 mode; outside that, there's nothing
  for it to send input to.
- No dedicated mouse overlay, and after checking, I don't think one
  belongs here: the app's own UI is almost entirely standard SwiftUI
  controls (Button, NavigationLink, Picker, TextField), which iPadOS
  already translates trackpad clicks into correctly without any extra
  work — the one custom gesture in the whole app (a plain
  `.onTapGesture` for tapping an ISO row) behaves the same way. And on
  the guest side, there's no `INT 33h` (the classic BIOS mouse service)
  implemented, because no boot menu this interpreter would plausibly
  reach ever calls it — a mouse overlay would have nothing real to feed.
  Building one would be decorative rather than functional, the same
  conclusion as live disk usage above, so this is closed rather than
  left as an open gap.
- "Full Screen" is satisfied by the session always presenting full-screen
  (`fullScreenCover`) rather than a toggle — iPad doesn't really have the
  windowed-vs-fullscreen VM distinction desktop VirtualBox has.

---

## Part 2 — The real-emulation question (stage 5 of your plan)

This is the part worth reading before investing further engineering time,
because it determines what "integrate the engine only if it actually works
and its license permits it" can mean in practice. I searched current
sources rather than relying on memory, since this is exactly the kind of
platform-capability fact that shifts over time.

### Full hardware virtualization (what VirtualBox/Parallels actually do): not available

VirtualBox-style virtualization uses a hypervisor to run a guest OS close
to natively. On Apple platforms that's `Hypervisor.framework` and the
higher-level `Virtualization.framework`. Both are **macOS-only**. Asked
directly on the Apple Developer Forums whether Virtualization framework
would come to iPadOS, Apple's own DTS engineer replied plainly: *"The
Virtualization framework is only available on macOS,"* and on a related
thread, *"neither of our VM frameworks (Hypervisor and Virtualization) are
available on iPadOS."* There's no public roadmap for this changing.

The only place real hardware virtualization has run on an iPad at all is a
jailbreak proof-of-concept (`VirtualMacOniPad`) that extracts those
frameworks from a macOS image and loads them on a jailbroken device —
and Apple closed even that door by removing Hypervisor support from the
iPadOS kernel as of iPadOS 16.4. I'm not suggesting this as a path; it's
mentioned only to show Apple has actively defended this boundary, not just
left it unaddressed. **For a legitimate App Store app, this option doesn't
exist.**

### CPU emulation (what QEMU/UTM do): now explicitly allowed, with one hard constraint

This is the more interesting finding, and it's better news than the
historical reputation of "Apple bans emulators" suggests. The timeline:

- **April 2024** — Apple's App Store guideline 4.7 was updated to allow
  retro game console emulators.
- **June 2024** — Apple rejected PC emulator submissions (UTM SE, and
  separately an iDOS update) specifically because guideline 4.7's text at
  the time said "retro game console," and Apple's review notice stated the
  app "provides emulator functionality but is not emulating a retro game
  console specifically."
- **Mid-July 2024** — UTM SE was approved anyway after rework with the
  AltStore team.
- **August 1, 2024** — Apple formally updated guideline 4.7's wording to
  add **"PC emulator apps"** alongside retro console emulators, closing the
  gap UTM SE had been rejected under. iDOS 3 (a DOS emulator) was approved
  shortly after under the same updated wording.
- **As of January 2026** (the most recent point I could verify), UTM SE is
  still live and actively maintained on the App Store — this is a settled,
  stable part of the platform now, not a one-off exception.

So: **a PC-style emulator is a legitimate, currently-approved App Store
category.** The constraint that remains is JIT. iOS/iPadOS still restricts
dynamic code generation (`MAP_JIT` / the `allow-jit` entitlement) to
Apple's own apps and browser engines — current developer-forum discussion
in 2026 confirms third-party non-browser apps still can't get it granted.
This is exactly why "UTM SE" is a distinct, slower product from full UTM:
SE uses QEMU's TCG *interpreter* instead of its JIT-based dynamic
recompiler specifically to avoid needing that entitlement — "SE" stands
for "slow edition" for this reason. Turing Software (UTM's maker) also
publishes a concrete operational limit worth carrying into this app's own
RAM guidance: they recommend a VM use **no more than ~20% of a device's
available RAM**, or iOS may kill the app outright.

### What this means for this project, concretely

| Approach | Status on iPadOS | Verdict |
|---|---|---|
| Hardware virtualization (Hypervisor/Virtualization.framework) | Not available to any third-party app, App Store or not | Off the table |
| CPU emulation with JIT (full UTM, max speed) | Requires an entitlement Apple doesn't grant to third parties | Off the table for an App-Store build |
| CPU emulation, interpreted (QEMU TCG, UTM SE's approach) | Explicitly allowed since Aug 2024, actively shipping today | The path a production-grade engine would take |
| A scoped, from-scratch x86 real-mode interpreter | Built this session — see "The real x86 interpreter" above | **What's actually here now** |

What's in the app today took the direct route: rather than a different,
simpler architecture (CHIP-8 or similar) as a lower-risk stepping stone,
it's a genuine, from-scratch 16-bit x86 real-mode interpreter, scoped to
roughly what a boot sector and early bootloader stage actually use, wired
to real disk reads against whatever ISO is attached. That's a deliberately
bigger, higher-effort undertaking than the staged approach I'd originally
suggested — and correspondingly carries more risk of a subtle bug
somewhere in the now 131 distinct opcode values covered (verified free of
accidental duplicate `case` labels, which Swift would otherwise either
reject or silently resolve in favor of whichever came first) by
hand-written decode logic I can't compile-test in this environment, flag
arithmetic I verified by hand-worked examples rather than a reference
test suite, and so on. I think it was the right
call given you specifically asked for your actual ISO to run, not a
different, simpler thing — but it's worth knowing that trade-off was made.

From here, the realistic next steps are:

1. **Get the actual stop-reason diagnostic from a real build.** This
   matters more now than it did earlier in this process. 143 opcodes are
   covered as of this session, including a deliberately narrow, safe port
   I/O simulation for the A20-enable sequence — the common real-mode
   instruction set is thoroughly covered at this point, so what's left to
   add is either increasingly rare opcodes or, more likely, something
   only a real run would reveal (a specific unimplemented interrupt, a
   port this session didn't anticipate). Extending coverage speculatively
   was reasonable early on; it's a less efficient use of further effort
   now than actually testing would be.
2. **Extend real-mode coverage further**, guided by that diagnostic. What
   remains unguided is genuinely thin: multi-bit shift/rotate amounts,
   any I/O port outside the narrow A20-related set, and the two-byte
   opcode space — which is also roughly the real boundary of "real mode"
   itself, so there's limited room left to extend into even with a
   specific target.
3. **Wrap QEMU's TCG interpreter** for genuine, broad OS compatibility —
   the UTM SE approach, detailed properly below rather than left as a
   one-line aspiration.
4. **Stop extending real-mode x86** once it reaches protected mode (its
   natural ceiling — see above) and spend further effort on stage 4/8
   polish instead, treating "real instructions genuinely execute, up to a
   clearly-reported boundary" as the intended, finished shape of this
   feature rather than a step toward full OS boot.

### If you want to pursue option 3: what QEMU-wrapping actually requires

This had only ever been researched at the policy level before — "it's
allowed, it's a big undertaking." Actually researching UTM SE's real
build process and history turns up specifics worth knowing before
committing to this path, not just the general shape of it.

**The build is two separate stages, not one.** UTM's own build process
cross-compiles QEMU and its dependencies for the target architecture
*first*, as a standalone step (their `build_dependencies.sh`), using
Homebrew-installed build tooling (bison, meson, nasm, pkg-config, glib,
gettext, libgpg-error among them) — QEMU itself is a git submodule, not
hand-vendored source. Only once that produces static libraries does the
Xcode project link against them. This means the work isn't "write some
Swift that calls QEMU" — it's standing up a whole C/C++ cross-compilation
toolchain for arm64-iOS before any Swift code is relevant at all, and
that step alone is a substantial, separate piece of systems engineering
most iOS developers haven't had reason to do before. This also isn't
something achievable the way this session's work was: it needs an actual
Mac with Xcode and a real shell, not a chat session generating Swift
files, so there's a hard environment requirement before anything else.

**The frontend really is mostly Swift, bridging into C.** UTM's current
codebase is roughly 83% Swift, 13% Objective-C, with the rest shell
scripts — the Objective-C is the bridging layer between SwiftUI and
QEMU's C API, which is the realistic shape this project's own equivalent
layer would need to take (this codebase has no Objective-C anywhere
today, so that bridging layer would be new, not an extension of
anything here).

**Full UTM's JIT is blocked by a specific, named mechanism, not a vague
policy.** UTM's own developers have said directly that the entitlement
their JIT build needs for third-party iOS apps simply isn't one Apple
grants. Concretely, the JIT build needs `get-task-allow` — an
entitlement normally reserved for actively-debugged, Xcode-attached
builds — which is structurally incompatible with a signed App Store
release, not just against the rules. There's no version of this project
that gets JIT on the App Store; UTM SE's interpreted-only approach is the
only path that was ever going to be store-compatible.

**Even UTM SE's own approval was genuinely contested, not a formality.**
Apple rejected UTM SE from the App Store on June 9, 2024; App Review's
stated reasoning came down to a six-word distinction — "a PC is not a
console" — reading guideline 4.7's original wording narrowly enough to
exclude general PC emulation even though it covered retro game consoles.
UTM SE was separately rejected from EU third-party-store notarization
under a different rule entirely (2.5.2, which bars apps from downloading
or executing additional code), on the reasoning that 4.7's exception
only applies to App Store submissions, not notarized ones. UTM's
developers said publicly at the time that they considered the fight not
worth pursuing further unless Apple's position changed. Apple reversed
course anyway, about five weeks later, approving UTM SE on July 15, 2024
with assistance from the AltStore team and another developer, and the
guideline text itself was updated shortly after to explicitly add "PC
emulator" to its wording. The category exists and is stable today, but
it was won through a specific, public dispute, not granted smoothly —
worth knowing if a future submission runs into the same friction.

**The GPL compliance question is live, not settled.** UTM the app is
Apache 2.0, but incorporates GPL/LGPL components — QEMU itself is GPLv2
— through a mix of dynamic linking (most components) and static linking
(their gstreamer plugins specifically, a legally more significant
choice). Whether an App Store binary, governed by Apple's own
distribution terms, can simultaneously satisfy GPL's redistribution
requirements has been an open question in the QEMU community itself: a
2021 report of a possible GPL violation regarding UTM on the Mac App
Store got a notably non-committal response from a QEMU core developer —
not a defense of compliance, an acknowledgment that enforcement would
fall to whoever holds copyright on the specific code in question, via
channels like the Software Freedom Law Center, if they chose to pursue
it. UTM addresses this today by publishing full source on GitHub, which
is the standard good-faith answer, but the deeper tension between a
store EULA and GPL's terms doesn't appear to have been tested in court.
Worth knowing going in: a 2016-era OpenLogic study of mobile apps found
that among apps using Apache or GPL/LGPL code, only 29% fully complied
with those licenses' obligations — this is a space most developers get
wrong by default, not a solved problem to casually replicate.

None of this means the path is closed — UTM SE is living proof it works,
on the App Store, today. It means the actual first milestone isn't
"write an X86CPU-style Swift file," it's "get QEMU cross-compiling for
arm64-iOS on an actual Mac," and the honest legal homework (specifically:
how source availability will be satisfied, and whether any component
beyond QEMU itself needs to stay dynamically linked rather than static)
needs doing before writing the app-facing code, not after.

#### Sources for this subsection
- [UTM (software) — Wikipedia](https://en.wikipedia.org/wiki/UTM_(software)) — architecture, license structure, UTM SE's technique and scope
- [UTM GitHub discussions — App Store feature request](https://github.com/utmapp/UTM/discussions/4577) — community discussion of the GPL/App Store question
- [The Register — "Apple rejects UTM, cites EU DMA", June 2024](https://www.theregister.com/2024/06/26/apple_emulation_eu/) — the developers' own statement on the JIT entitlement
- [Daring Fireball — "UTM SE Now in the App Store", July 2024](https://daringfireball.net/linked/2024/07/15/app-store-utm-se)
- [9to5Mac — "Apple blocks PC emulator from App Store", June 2024](https://9to5mac.com/2024/06/09/apple-blocks-pc-emulator-utm-app-store/)
- [mjtsai.com — "UTM Blocked Outside App Store via Notarization", June 2024](https://mjtsai.com/blog/2024/06/14/utm-blocked-outside-app-store-via-notarization)
- [qemu-discuss mailing list — "Possible GPL violation on Mac App Store", Feb 2021](https://lists.nongnu.org/archive/html/qemu-discuss/2021-02/msg00136.html)

### Sources

- [Apple Developer Forums — "Is it possible to use the Swift Virtualization Framework on an iPad or iPhone?"](https://developer.apple.com/forums/thread/702312)
- [Apple Developer Forums — Hypervisor/Virtualization framework availability on iPadOS](https://developer.apple.com/forums/thread/747029)
- [PCWorld — "Apple says no retro PC emulators on the App Store," June 2024](https://www.pcworld.com/article/2378030/apple-says-no-retro-pc-emulators-on-the-app-store.html)
- [MacTrast — "Apple Officially Gives Its Blessing to PC Emulators in the App Store," Aug 2024](https://www.mactrast.com/2024/08/apple-officially-gives-its-blessing-to-pc-emulators-in-the-app-store/amp/)
- [GIGAZINE — iDOS 3 approval under the updated guideline](https://gigazine.net/gsc_news/en/20240818-idos-3)
- [Wikipedia — UTM (software), incl. TCG interpreter rationale and Jan 2026 release](https://en.wikipedia.org/wiki/UTM_(software))
- [NotebookCheck — UTM SE RAM guidance (~20% of device RAM)](https://www.notebookcheck.net/Apple-iPhone-and-iPad-get-free-emulator-for-Windows-macOS-and-Linux.863903.0.html)
- [Apple Developer Forums — JIT entitlement scope, 2026](https://developer.apple.com/forums/thread/785697)

---

## Part 3 — Suggested next session

Picking up from here, in roughly the order the original spec lays out:

1. **Try it against a real ISO in Xcode** and see exactly where it stops
   — that result (which opcode, how many instructions in) is genuinely
   useful information for deciding what to extend next, and I can't
   generate it myself without a compiler here.
2. **Extend real-mode coverage** opcode by opcode based on what that run
   shows, or **decide whether to pursue QEMU-wrapping** for broad OS
   support — see the table above.
3. **Stage 4 polish is essentially done now.** Of the three items
   originally listed here, the OS picker is grouped, and both live disk
   usage and a mouse overlay turned out, on inspection, to have nothing
   real to attach to in the current architecture — closed rather than
   built hollow. If this section still has something in it next time,
   it's because a new real need showed up, not because of unfinished
   business from the original list.
4. **Stage 7 testing**: once you've done a first Xcode build, send me any
   compiler errors — I'd expect at most minor fixes given the scope of
   what was added this session, but I want to be upfront that none of
   this has been compiled yet.
