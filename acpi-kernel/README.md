# ACPI Kernel

`kernel.asl` defines the kernel entry point `KERN` and the console drivers.
AMLAOT compiles the AML to native code. Limine loads the x86-64 ELF, and
`boot.c` supplies the entry point, byte port I/O, and the handoff to ASL.
The kernel builds a GDT and all 256 IDT gates in ASL. It runs the
breakpoint and memory smoke tests, lists ACPI tables and APICs, then
calibrates and arms the boot CPU's periodic LAPIC timer.

The kernel mirrors console text to COM1 and the first supported
Limine framebuffer. The framebuffer console supports 24- and 32-bit
RGB modes, wraps and scrolls text, and handles Backspace. ANSI SGR
sequences set foreground and background colors using the standard,
bright, 256-color, or RGB forms. The console also handles intensity
and color resets. Other CSI commands are consumed. COM1 receives
the original bytes and serves
as the console when Limine provides no supported mode. The bitmap
glyphs come from the [public-domain font8x8 basic font](https://github.com/dhepper/font8x8).

Limine supplies the ACPI Root System Description Pointer. The ASL kernel
checks the RSDP and prefers the 64-bit XSDT, with the RSDT as a fallback.
COM1 lists the RSDP, the selected root, all of its entries, and the DSDT
and FACS referenced by the FADT. The listing includes signatures, 64-bit
physical addresses, byte lengths, and applicable revision, checksum,
OEM, and creator fields. Numeric fields are hexadecimal.

The kernel checks the MADT (signature `APIC`) before reporting local
APIC and x2APIC IDs, ACPI processor UIDs, and raw ACPI flags (bit 0 for
enabled, bit 1 for online-capable). It reports the local APIC base address,
including any MADT address override, and each I/O APIC's ID, MMIO address,
and global system interrupt base.

The timer driver uses the MADT ISA IRQ 0 source override, including its
polarity and trigger flags, to route PIT channel 0 through the matching
I/O APIC pin to vector `0x20`. The ASL driver masks the legacy PIC on
PC/AT-compatible systems and maps APIC MMIO with uncacheable page
attributes. When firmware has enabled x2APIC, the local APIC registers
are accessed through MSRs. The I/O APIC route uses an 8-bit physical
destination ID.

The PIT runs at approximately 100 Hz. The driver measures four PIT
periods with the LAPIC countdown timer at divide-by-16, then masks the
PIT route and programs the periodic LAPIC timer on vector `0x21`. The
boot check requires three LAPIC timer interrupts during setup and a
later report that the tick counter reached 100. The kernel continues to
wait for and acknowledge interrupts, incrementing the ASL integer
`TICK` once per delivered LAPIC timer interrupt. The stubs latch the
timer vector. They return to the idle wait with `iretq` or save a running
task's frame and switch back to the scheduler. ASL handles EOI with
interrupts disabled. Vector `0xff` handles spurious interrupts. Other
unhandled vectors halt with the vector number in EAX.

The PS/2 keyboard uses ISA IRQ 1, or its MADT source override, routed
through the I/O APIC to vector `0x23`. The controller is configured for
translated scan code set 1. After setup, the kernel reads keyboard data
only in response to an interrupt. The driver decodes US ASCII keys,
including Shift, Caps Lock, Backspace, and Enter, and buffers input for
waiting readers.

In freestanding builds, AMLAOT recognizes these x86 kernel intrinsics:

| ASL call | Operation |
| --- | --- |
| `XADR (Buffer)` | Return the address of the buffer's storage |
| `XGDT (Pointer, Code, Data)` | Load the 10-byte GDTR and reload the segment selectors |
| `XIDT (Pointer)` | Load the 10-byte IDTR |
| `XVEC ()` | Return the base of the 256 interrupt stubs, each 16 bytes |
| `XDWD (Address, Value)` | Write a 32-bit MMIO register, or read it when `Value` is `Ones` |
| `XAPC ()` | Return whether CPUID reports a local APIC |
| `XMSR (Index, Value)` | Write an MSR, or read it when `Value` is `Ones` |
| `XWAI (Cycles)` | Enable maskable interrupts while waiting for a latched vector, then return with interrupts disabled. A zero argument waits with `hlt`. A nonzero argument bounds the wait in TSC cycles |
| `XRUN (Frame, SaveAddress, KernelStack, Root, FxState)` | Dispatch a task with its interrupt frame. A user task supplies its ring-0 stack top and physical PML4 address. Restore and save the user x87/SSE state using the aligned `FxState` area, restore the kernel root on return, save the resulting frame pointer, and return the dispatch event |
| `XIMG (Offset, Width)` | Read a little-endian word from the first Limine module, or get its size when width is zero |
| `XCPY (Address, Offset, Length)` | Copy a validated span of the first Limine module into mapped memory |
| `XBYT (Address)` | Read one byte from mapped memory |
| `XSTB (Address, Value)` | Write one byte to mapped memory |
| `XTRG (Selector)` | Load the task register with a TSS selector |
| `XSYE ()` | Return the SYSCALL entry address |
| `XEXT ()` | Return the native task exit trampoline |
| `XTST ()` | Return the native scheduler test entry point |
| `XSTQ (Address, Value)` | Write an aligned virtual 64-bit word |
| `XHND ()` | Return the vector-3 trampoline address |
| `XBRK ()` | Trigger `int3` and dispatch to the root ASL `BRKP` method |
| `XMAP (Index, Field)` | Fields 0 and 1 return the aligned start and exclusive end of a usable range, or zero for a skipped entry. Fields 2, 3, and 4 return the raw Limine base, length, and type. Returns `Ones` past the map |
| `XPLK (PhysicalAddress, Link)` | Write the free-list link in an allocator-owned page, or read it when `Link` is `Ones` |
| `XCR3 ()` | Return the active four-level page-table root's physical address, or zero if unavailable |
| `XFBQ (Field)` | Query the selected framebuffer address, width, height, pitch, bytes per pixel, or packed foreground color (fields 0–5) |
| `XRGB (Rgb)` | Pack a 24-bit RGB color using the selected framebuffer's channel layout |
| `XPRW (Address, Bits, Colors, BytesPerPixel)` | Draw eight pixels with foreground in the low 32 bits and background in the high 32 bits |
| `XFBL (Destination, Source, Length)` | Copy framebuffer bytes forward, or clear them when source is zero |
| `XNXE ()` | Return one if the CPU has enabled execute-disable page permissions |
| `XHHD ()` | Return Limine's higher-half direct-map offset |
| `XCLR (Address)` | Zero one writable virtual page |
| `XINV (Address)` | Invalidate the local CPU's translation for a virtual page |
| `XVWD (Address, Value)` | Write an aligned virtual 64-bit word, or read it when `Value` is `Ones` |
| `XMEM (PhysicalAddress, Width)` | Read a little-endian 1-, 4-, or 8-byte value from firmware memory mapped by Limine, or return `Ones` on failure |

Keep any buffer referenced by a loaded table register alive and at the
same address while the table is installed. The ASL kernel stores both
tables in named buffers for this reason. The x86 trampoline uses
`iretq` to resume the interrupted ASL code.

The trampoline captures the general-purpose registers together with the
CPU-saved RIP, CS, RFLAGS, RSP, and SS. AMLAOT copies the frame into an
AML buffer and passes it as `Arg0` to `BRKP`. The handler formats all
20 slots in hex and prints them through the ASL COM1 driver.

The ASL physical page allocator runs on the boot CPU. `PALC ()` returns
the physical address of one 4 KiB page, or zero at exhaustion. It walks
Limine's usable ranges and reuses returned pages first. `PDEL (Page)`
takes ownership of a page from `PALC` and stores a free-list link in it.
Callers must return each allocated page at most once and initialize its
contents before use. The BIOS and UEFI checks exercise page alignment,
distinct allocations, and reuse. COM1 prints the full Limine memory map
with each entry's physical base, byte length, and Limine type name,
followed by the two example physical page addresses.

`VMAP (VirtualAddress, PhysicalAddress, Flags)` maps one physical page, such
as a caller-owned `PALC` page or a device MMIO page, into the active four-level address space. The virtual address
must be canonical and 4 KiB aligned. The method sets the present bit and
accepts these x86-64 leaf flags. Passing zero gives a read-only supervisor
mapping with default caching and execution permitted.

| Flag | Value |
| --- | --- |
| Writable | `0x02` |
| User accessible | `0x04` |
| Page-level write-through | `0x08` |
| Page-level cache disable | `0x10` |
| Global (effective with CR4.PGE enabled) | `0x100` |
| Execute disable (requires EFER.NXE) | `0x8000000000000000` |

The method returns one on success and zero for invalid arguments,
unsupported flags, occupied mappings (including large pages), existing
ancestors that restrict requested permissions, or allocation failure.
ASL allocates missing page tables from `PALC` and returns them on failure.
The caller is responsible for the physical page and its cache type for
the mapping's lifetime.
The boot CPU invalidates its local translation after installation.

The BIOS and UEFI checks verify writable supervisor and read-only user
leaf entries, execute-disable when enabled, and the user bits through
the page-table hierarchy. They exercise alias read/write and rejection
of invalid addresses, flags, and occupied mappings. The test keeps its
page and mappings for the rest of the boot.

The anonymous kernel range allocator runs on the boot CPU.

| ASL call | Operation |
| --- | --- |
| `VALL (Length, Flags)` | Round the byte length up to 4 KiB, allocate a contiguous virtual interval, and back it immediately with zeroed physical pages. Returns the virtual base, or zero on failure. Supported flags are writable, global, and execute disable |
| `VUNM (Base, Length)` | Unmap anonymous pages and return their backing frames and any newly empty kernel page tables. The base must be page-aligned, and the byte length rounds up. Returns one on success or zero if any page in the interval is outside an anonymous mapping |

For example, `VALL (6000, WRIT | NOEX)` gives two writable, non-executable
pages on a CPU with EFER.NXE enabled. `VUNM (Base, 6000)` releases them.
Physical frames may be scattered. If a mapping fails partway, the
allocator rolls back the range. Unmapping can release a page-aligned
subrange, and leaves the range intact when validation fails.

The four-level address space has a 128 TiB canonical higher half. Each
PML4 entry covers 512 GiB. The allocator's window is
`[0xffff800000000000, 0xffffff0000000000)`, which leaves out the top two
PML4 entries and spans `254 × 512 GiB = 127 TiB`. It searches top-down
and also excludes inherited PML4 slots, including Limine's direct map.
The 127 TiB is the size of the search window. Actual allocations are
limited by occupied address space and available physical memory.

The boot CPU runs a preemptive round-robin scheduler. `SSPN (Entry, Arg)`
queues a trusted native kernel task with a single 64-bit argument. Each
task gets a 16 KiB allocation for its record and stack. The linked run
queue grows with available memory and has no fixed task count. Each
delivered LAPIC tick preempts the current task and moves it to the back
of the queue. Returning from the entry function exits through vector
`0x22` and allows the scheduler to reclaim the task's pages. An empty
queue idles until the next interrupt.

Native tasks share the kernel address space and use the kernel's
no-red-zone, general-purpose-register-only calling convention. Scheduler and AML
code run with interrupts disabled outside the idle wait. Freestanding
AML has no execution-step budget so the scheduler can run indefinitely.
Hosted AML retains the budget. The optional `STST` boot test exercises
preemption, FIFO rotation, register preservation, and cleanup for 32
native tasks. Its call in `KERN` is commented out for faster userspace
startup.

The default ISO boots `hello.elf` as a Limine module. ASL validates its ELF64
headers, loads its `PT_LOAD` segments at their declared user addresses,
zeros memory beyond the file bytes, and creates a 64 KiB user stack
with a guard page below it. The loader accepts static x86-64
`ET_EXEC` images with disjoint load pages. The static runtime handles any TLS metadata
in the program headers. It rejects writable executable segments and applies execute
disable where the CPU supports it.

Each user task owns a PML4 and its lower-half mappings. The scheduler
refreshes the supervisor-only higher-half entries from the kernel root
before dispatch and switches CR3 before entering ring 3. On a timer
interrupt, the TSS supplies the task's supervisor stack. On `syscall`,
the entry stub switches to that stack and saves the same frame layout.
The return path restores the kernel root before resuming ASL. Syscall
buffer accesses walk the caller's page tables and use the physical
direct map. The scheduler saves and restores per-task x87 and SSE state
and the FS base set by `arch_prctl(ARCH_SET_FS)`. The kernel builds with
general-purpose registers only. Userspace uses the baseline x86-64 ISA.

The Linux x86-64 syscall subset includes `read` (0) from PS/2 stdin or
an open VFS file, `write` (1) to stdout or stderr, and `close` (3)
and `lseek` (8) for open VFS files. Console seeks return `ESPIPE`.
Other supported calls include `mmap` (9) for private anonymous read/write
memory, `munmap`
(11) for a complete mapped range, `ioctl` (16) with `TIOCGWINSZ` on console
descriptors, `getpid` (39), fork-style `clone` (56), `fork` (57), `execve` (59), `exit` (60),
`wait4` (61), `uname` (63), `getcwd` (79), the UID and GID queries (which return zero),
`getppid` (110), `arch_prctl` (158) with `ARCH_SET_FS`, `gettid` (186),
`getdents64` (217), `exit_group` (231), `openat` (257), `newfstatat` (262),
and `faccessat` (269). The interactive
init process has PID and TID 0. Other boot processes have PID and TID 1.
Each process can open up to 16 VFS files or directories.
The working directory is the VFS root. Reads with an empty
input queue block until a keystroke arrives. `uname` reports `ASL kernel`
as the system name and `x86_64` as the machine type. Reads and writes may return
short counts. Unknown syscall numbers return `-ENOSYS`.

Fork eagerly copies the user mappings, saved registers, and TLS state.
The parent receives the child PID and the child receives zero. Inherited
descriptors share file offsets. The libc-compatible clone form takes
`SIGCHLD` and a null stack. On exit or a handled user fault, the scheduler
releases the task's memory and descriptors. The parent can collect the
exit status with `wait4`, optionally using `WNOHANG`. Faults report
`SIGSEGV` in the wait status. Orphans are reaped automatically.
Signal delivery, resource accounting, and process group changes are
outside this syscall subset.

`execve` loads static ELF64 programs directly from the initramfs.
It preserves the PID and open descriptors except those marked
`O_CLOEXEC`. The initial exec stack accepts up to 64 argument and
environment strings sharing 3,488 bytes including terminators.

When a Limine framebuffer is available in 32-bit mode, the kernel exposes
`/dev/fb0` as a minimal fbdev-compatible device. Programs can open it for
writing, stream packed XRGB8888 pixels with `write()`, and query fixed
screen information with `FBIOGET_VSCREENINFO` (`0x4600`) or
`FBIOGET_FSCREENINFO` (`0x4602`). Writes may be short and advance the open
file offset. Framebuffer `mmap()` and mode changes are not implemented.

At boot, the kernel starts one
interactive copy of `hello.elf`. Type your name in the QEMU display window
and press Enter. The prompt, echoed input, and greeting appear in that
window and on the serial console.

After the demo exits, the kernel opens the ASL shell at the `asl>`
prompt. Type in the QEMU display window. Enter runs the command and
Backspace edits the line. The shell supports `help`, `ls /` to list the
VFS root, and `cat welcome.txt` to display a file. Filenames are
case-sensitive and may have a leading slash.

The build packs the flat files in `initramfs/` into a small archive and
links it into the kernel's read-only ELF segment. The archive includes
the standalone `/ls` executable, built from `ls.c`. ASL validates the
archive's record bounds at startup and adds the files to a read-only VFS
tree with their data left in place. The same tree exposes `/proc/meminfo`.
Each open of that file snapshots `MemTotal`, `MemFree`, and `MemAvailable`
in KiB. The total counts the page-aligned usable ranges managed by the
physical allocator. Free and available memory both count allocator pages
that are currently unallocated. Add or edit
files in that directory and rebuild the ISO to change its contents.
Names can contain ASCII letters, digits, underscores, hyphens and dots,
start with a letter, digit or underscore, and have at most 63 characters.
The shell's `cat` command is intended for text files.

Build from the repository root with matching Clang, LLVM tools, and LLD.
The build also needs Python 3, Rust/Cargo, iASL, xorriso, and Limine binary files
under `/usr/share/limine`. Override `LIMINE_DIR` for other installations.
The boot checks use Python 3 and QEMU's monitor to inject keystrokes
after the userspace prompt. They verify the greeting after editing the
name with Backspace, exit status zero, the ACPI and APIC reports, and
the shell's directory listing, file read, and missing-file response.
They also confirm the framebuffer changes and save captures as
`serial.ppm` and `serial-uefi.ppm` under `target/acpi-kernel`. The UEFI
target uses OVMF.

```sh
make -C acpi-kernel
make -C acpi-kernel run
make -C acpi-kernel check
make -C acpi-kernel check-uefi
```

## Static mlibc userspace

The optional mlibc build boots `hello-mlibc.c` as `hello.elf`. It uses
mlibc 6.3.1's Linux syscall backend and standard static CRT. The build
fetches the pinned sources and stages headers, `crt1.o`, and `libc.a` in
`target/acpi-kernel-mlibc/sysroot/usr`. It needs Git, Meson, Ninja, Clang,
Clang++, and Linux x86-64 UAPI headers. Set `MESON` to the Meson
executable if it is outside PATH. Set `MLIBC_UAPI` to an absolute path
containing installed UAPI headers if they are outside the standard
host include directories.

```sh
make -C acpi-kernel mlibc
make -C acpi-kernel run-mlibc
make -C acpi-kernel -j2 check-mlibc check-mlibc-uefi
```

The mlibc boot checks exercise the C program's TLS before and after
blocking, both fork entry points, private memory and TLS across fork,
shared file offsets, child reaping, allocation, formatted output, and the
same keyboard and shell flow as the assembly demo. Threads, dynamic linking, and a
general Linux syscall ABI are outside its current scope.

## Static Bash

The interactive UEFI image boots GNU Bash 5.2.37 and bundles Fastfetch
in the initramfs. Run `make run-uefi` from the repository root or
`make -C acpi-kernel run-uefi`. This launch uses KVM with host CPU
passthrough so Fastfetch reports the host CPU model. The build uses the mlibc sysroot and
needs curl, tar, and sha256sum in addition to the mlibc and Fastfetch
build tools. The Bash build omits Readline and job control.

```sh
make -C acpi-kernel -j8 bash
make -C acpi-kernel run-bash
make -C acpi-kernel -j2 check-bash check-bash-uefi
```

The Bash Limine entry starts interactive Bash as PID 0. Type in the QEMU
display window and press Enter. The kernel echoes the keys and handles
Backspace. Run `ls /` to list the root or `ls -a /` to include the dot
entries. Bash starts with `PATH=/` and runs the bundled `/ls` as a
separate process. Type `fastfetch` to run the bundled system summary.
Run `echo $$` to check the PID or `source /boot-test.sh`
to run the bundled script. `exit` hands control to the ASL shell.

The `init:` prefix in `module_string` selects PID 0 and line-based console
input. The remaining string supplies `-i` to Bash. The module basename
supplies `argv[0]`. If the remaining string contains a pipe character,
the first pipe separates two optional arguments.

This build supports Bash builtins, sourced scripts, and external static
programs that stay within the supported syscall subset. Pipelines and
job control remain outside its scope.

The ELF, ISO, and boot logs are under `target/acpi-kernel`. The kernel
uses general-purpose registers only and disables the x86-64 red zone.
The freestanding runtime uses a 64 KiB early allocation arena that keeps
allocations until shutdown.

Limine reference material is available in the [boot protocol specification](https://github.com/Limine-Bootloader/limine-protocol/blob/trunk/PROTOCOL.md).

## Fastfetch

The build produces Fastfetch 2.71.0 as a static x86-64 mlibc executable.
It uses CMake and Ninja, fetches a pinned upstream revision, and applies
the local compatibility patch. The commands below build and boot the
standalone Fastfetch image.

```sh
make -C acpi-kernel fastfetch
make -C acpi-kernel run-fastfetch
```

The executable and boot ISO are under `target/acpi-kernel/fastfetch/`.
This port uses a short default module list and disables Local IP detection
because mlibc's Linux `getifaddrs()` requires netlink support. Fastfetch
reads the ASL kernel identity through `uname()`.
CPU and memory detection depend on Linux-style `/proc` data.
