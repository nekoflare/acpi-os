# Roadmap item 5 status

The Roadmap item 5 fixtures pass for scalar regions and precompiled SSDTs.

## Implemented

- Parsed and lowered serialized methods, sync-level checks, named Mutex and Event objects, recursive acquisition, queued signals, and event waits. Contexts still require exclusive access during each call.
- Added Processor, PowerResource, and ThermalZone namespace containers, including nested declarations, ObjectType, and notification targets.
- Added per-context host callbacks for Timer, Sleep, Stall, Notify, event waits, scalar operation-region transfers, and the ACPI global lock.
- Implemented scalar OperationRegion fields, BankField, and IndexField. Transfers honor access width, alignment, bit offsets, and the Preserve, WriteAsOnes, and WriteAsZeros update rules.
- Methods can declare regions and fields with per-invocation storage. A region closes on method exit, so a saved field reference cannot perform I/O through that region after the method returns.
- Added `--dynamic-ssdt` for precompiled SSDTs and per-context load and unload APIs. AML can select these tables with LoadTable or load matching bytes from a Buffer or SystemMemory region with Load. Unload retires the table's bindings. Reload uses fresh storage and handles, so saved references to the old activation stay invalid.
- Failed activation unlinks held mutexes before retiring their slots. A nested load that requires a table whose initializer is still running returns `AML_TABLE_BUSY`. The dependent can load once the required table finishes initialization.

## Verification

- The nine Rust unit tests, the original native fixture, and `cargo clippy --locked -- -D warnings` passed.
- The host namespace and region fixtures passed in optimized and unoptimized native builds. Both returned 42 under the bundled uACPI runner, which also reported the expected notification from `\TZ00` with value `0x81`.
- The optimized and unoptimized native dynamic builds passed host and AML load/unload, independent contexts, stale references, alias invalidation, and rejection of a region image that differs from the precompiled SSDT. uACPI returned 42 with the SSDT supplied as an extra table. The bundled uACPI interpreter implements AML Unload as a no-op, so the native fixture covers unload behavior.
- The activation fixture passed with and without optimization. It checks mutex cleanup after a failed initializer, rejection of a nested dependent load, successful reload, and unload ordering for an active dependency.

## Support limits

- The callback covers scalar transfers. Connection descriptors and nonzero access attributes are unsupported.
- The current AOT lifecycle accepts precompiled SSDTs. LoadTable supports an empty or root path and an empty parameter path. Arbitrary runtime tables, namespace relocation, and LoadTable parameter binding are outside the current implementation.

## Fixture commands

```sh
cargo test --locked
iasl -p target/host-namespace tests/host-namespace.asl
iasl -p target/host-regions tests/host-regions.asl
make run AML=target/host-namespace.aml TESTBENCH=tests/host-namespace.c
make run AML=target/host-regions.aml TESTBENCH=tests/host-regions.c
make run AML=target/host-namespace.aml TESTBENCH=tests/host-namespace.c PASSES= IR=target/host-namespace.unoptimized.ll
make run AML=target/host-regions.aml TESTBENCH=tests/host-regions.c PASSES= IR=target/host-regions.unoptimized.ll
target/uacpi/test-runner target/host-namespace.aml --expect int 42 --log-level warning
target/uacpi/test-runner target/host-regions.aml --expect int 42 --log-level warning

iasl -p target/host-dynamic-dsdt tests/host-dynamic-dsdt.asl
iasl -p target/host-dynamic-ssdt tests/host-dynamic-ssdt.asl
cargo run --quiet --locked -- --emit-llvm --dynamic-ssdt target/host-dynamic-ssdt.aml target/host-dynamic-dsdt.aml > target/host-dynamic.ll
opt -S -passes='verify,default<O2>,verify' target/host-dynamic.ll -o target/host-dynamic-opt.ll
clang -std=c17 -Wall -Wextra -Werror -Wno-override-module target/host-dynamic-opt.ll tests/host-dynamic.c -o target/host-dynamic-test
target/host-dynamic-test target/host-dynamic-ssdt.aml
target/uacpi/test-runner target/host-dynamic-dsdt.aml --extra-tables target/host-dynamic-ssdt.aml --expect int 42 --log-level warning

opt -passes=verify -disable-output target/host-dynamic.ll
clang -std=c17 -Wall -Wextra -Werror -Wno-override-module target/host-dynamic.ll tests/host-dynamic.c -o target/host-dynamic-unoptimized-test
target/host-dynamic-unoptimized-test target/host-dynamic-ssdt.aml

for fixture in host-activation-dsdt host-activation-ssdt host-activation-dependent; do
    iasl -p "target/$fixture" "tests/$fixture.asl"
done
cargo run --quiet --locked -- --emit-llvm --dynamic-ssdt target/host-activation-ssdt.aml --dynamic-ssdt target/host-activation-dependent.aml target/host-activation-dsdt.aml > target/host-activation.ll
opt -passes=verify -disable-output target/host-activation.ll
opt -S -passes='verify,default<O2>,verify' target/host-activation.ll -o target/host-activation-opt.ll
for ir in host-activation host-activation-opt; do
    clang -std=c17 -Wall -Wextra -Werror -Wno-override-module "target/$ir.ll" tests/host-activation.c -o "target/$ir-test"
    "target/$ir-test"
done
```

If the test environment prevents LeakSanitizer from running, set `LSAN_OPTIONS=detect_leaks=0` for the uACPI runner.
