# ACPI Kernel

These instructions apply to `acpi-kernel/`.

## Architecture

- Write kernel logic and drivers in `kernel.asl`. `KERN` is the entry point, and the COM1 driver uses a `SystemIO` operation region.
- Use Limine to boot the freestanding x86-64 ELF. Keep native glue focused on the boot handoff, runtime support, and CPU operations AML cannot express. `boot.c` provides the handoff and port I/O callback, `early-memory.c` provides the early allocation arena, and `x86.S` contains the descriptor-load and interrupt stubs.
- Preserve the no-red-zone and no-SIMD requirements for the entire kernel, including generated AML code and native glue. Keep the LLVM `noredzone` attribute and general-purpose-register-only code generation. Treat assembly at the interrupt boundary as part of this requirement.
- Add instruction lowering in `../src/llvm.rs` when ASL needs an x86 operation. Keep kernel intrinsics scoped to freestanding builds and preserve hosted AML behavior.

## Descriptor and Interrupt Invariants

- Build descriptor tables and their register operands in ASL. Keep buffers used as installed GDT or IDT storage rooted and at a stable address for as long as the CPU can access them. `XADR` exposes the backing address of an AML buffer.
- The IDT installs 256 interrupt gates. Keep the 16-byte stub stride and vector numbers in `x86.S` synchronized with `SIDT` and the ASL timer driver. Vector 3 handles the controlled `XBRK` call. Fatal stubs halt with their vector in EAX, and the spurious LAPIC vector returns without an EOI.
- The PIT, LAPIC timer, and PS/2 keyboard stubs latch their vector without entering AML. They use the same APIC priority class, so an in-service interrupt holds off the others until ASL issues EOI. Read PS/2 data in the IRQ dispatcher before acknowledging the interrupt. Enable maskable interrupts inside `XWAI` or while running a native task. During native execution, the stubs save the task frame and return to the scheduler stack. Issue EOI from ASL with interrupts disabled.
- The ASL scheduler alone owns the runnable queue. `SSPN` builds the initial frame for `acpi_run_task`, and the timer entry saves that same frame layout. Vector `0x22` exits a native task. Reclaim the task's stack only after switching back to the scheduler stack.
- For ring-3 dispatch, keep the TSS RSP0 and `XRUN` syscall stack top on the selected task's supervisor stack. The syscall entry builds the same saved frame as the timer and returns to ASL on the scheduler stack. Dispatch with the selected task's private CR3 and restore the kernel CR3 before accessing the scheduler stack. Refresh the shared supervisor-only upper entries before dispatch. Validate syscall buffers against the calling task's ranges and translate through its private page tables while running in the kernel root.
- Keep the register frame in `x86.S`, the generated `aml_interrupt_BRKP` bridge, and the `REGS` labels and indexing in `kernel.asl` in agreement. The current frame is 20 little-endian 64-bit slots. `BRKP (Arg0)` receives a context-owned buffer copy, formats the register values, and writes them over COM1.
- Use the interrupt bridge to enter ASL while another AML method is running. The normal host method wrappers collect AML objects and release mutexes, so they are unsuitable for reentering the active context from the trampoline.
- The early allocator reserves 64 KiB and does not reclaim individual allocations. Account for that lifetime when adding loops, recurring events, or persistent state.

## Build and Verify

Run these from the repository root:

```sh
make -C acpi-kernel
make -C acpi-kernel -j2 check check-uefi
```

- Use `make -C acpi-kernel run` for an interactive BIOS boot or `make -C acpi-kernel run-uefi` for OVMF. See `README.md` for toolchain requirements and path overrides.
- Inspect `target/acpi-kernel/serial.log` and `serial-uefi.log` for boot results. Both checks expect GDT and IDT load messages, the ASL breakpoint handler, all 20 register values, a message confirming execution resumed after `int3`, PIT delivery via the MADT IRQ 0 override, successful calibration, a periodic LAPIC tick count of 100, and the ring-3 `hello.elf` prompt, a greeting after injected PS/2 keystrokes, and exit status zero.
- When changing code generation or compiler flags, inspect `kernel.bc` for `noredzone` and disassemble `kernel.elf` to check that the final executable uses no SIMD registers. Run `cargo test --locked` and `cargo clippy --locked -- -D warnings` when changing AMLAOT.
- Build products and VM logs belong under `target/acpi-kernel/`.
