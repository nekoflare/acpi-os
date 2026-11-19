# Move ACPI kernel qword access into ASL

Work in the AMLAOT repository. Read `acpi-kernel/AGENTS.md` and inspect `git status --short` before editing. Preserve the existing worktree changes.

`XRGB`, `XNXE`, and `XPLK` are already implemented in ASL. `KERN` loads the direct-map offset into `HHDO` from the boot handoff. `XPLK` calls `XVWD (HHDO + Arg0, Arg1)` to access allocator free-list links. Both existing boot logs report `ASL page allocator ready`.

## Implement the migration

1. Extend the kernel region callback in `acpi-kernel/boot.c` to support `SystemMemory` accesses for aligned 64-bit words at already-mapped kernel virtual addresses. Use a volatile 64-bit load or store and preserve the existing byte-wide `SystemIO` behavior and port allowlist. Check the callback contract in `src/runtime.h` and field transfer logic in `src/objects.c`.
2. Replace the external declarations for `XVWD` and `XSTQ` with ASL methods using a method-local `OperationRegion` and a full-width `QWordAcc` field. See `tests/method-region.asl` for a region whose base comes from a method argument. `XVWD (Address, Ones)` reads. Other `XVWD` values write and return zero. `XSTQ` always writes and returns zero, including when the value is `Ones`. Review callers for alignment and check that repeated accesses fit the freestanding runtime's allocation and execution limits. The early allocator is bounded and does not reclaim individual allocations.
3. Remove the superseded C helpers and compiler mappings from `src/llvm.rs`. Update the helper documentation in `acpi-kernel/README.md`.

Keep this change focused on qword RAM access. The follow-on work covers `XDWD`, whose MMIO accesses must remain single 32-bit transactions, and `XMEM`, which takes a firmware physical address and validates it against the boot memory map.

## Verify

- Collect baseline BIOS and UEFI boot timings before editing. Compare them with the modified build using the same QEMU configuration and report the comparison.
- Run `make -C acpi-kernel` and `make -C acpi-kernel -j2 check check-uefi`. Confirm both serial logs report `ASL page allocator ready` and `ASL virtual page mapper ready`, and that the normal userspace boot test completes.
- Verify that storing `Ones` through `XSTQ` and reading it back through `XVWD` works. Check the existing tests for coverage and add a focused check if they miss this case.
- Run `cargo test --locked`, `cargo clippy --locked -- -D warnings`, and `git diff --check`. Inspect `kernel.bc` for `noredzone` and disassemble `kernel.elf` to check for SIMD registers, per `acpi-kernel/AGENTS.md`.
- Report what changed, the actual verification results, and any runtime costs observed.
