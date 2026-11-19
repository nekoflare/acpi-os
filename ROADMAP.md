# AML AOT roadmap

AMLAOT compiles ACPI AML methods ahead of time. Use the checklist in order, starting with nested namespaces. Each stage has a completion check that can be run against uACPI.

## Working today

- [x] Parse a single DSDT or SSDT and dump instructions with byte offsets.
- [x] Decode root-level methods and derive call argument counts from declarations, including forward calls.
- [x] Compile the initial 64-bit integer subset with arguments, locals, `If`, `While`, and `Return`.
- [x] Compile reads and writes of root-level `Name` objects initialized from integer literals.
- [x] Export native functions for every supported method in the input table.
- [x] Emit, verify, and optimize LLVM IR at `O2` by default. Run the native C testbench with `make run`.
- [x] Compare the arithmetic and shared-state fixtures with uACPI.

The native backend supports 32-bit and 64-bit AML integers and `NotSerialized` methods with sync level zero. Each execution context requires exclusive access during a call.

## 1. Nested namespaces

- [x] Represent AML name paths with root and parent prefixes, single and multiple segments, and context-sensitive `NullName`.
- [x] Parse `Scope` and `Device` bodies and index their methods and named objects by absolute path.
- [x] Resolve relative references and parent-scope lookup while preserving the declared argument count of each method.
- [x] Emit distinct LLVM symbols for fully qualified names and retain the existing root-level exports.
- [x] Verify that two scopes can reuse a name and that relative, parent-prefixed, and root-prefixed reads, writes, and calls match uACPI.

Nested exports use dot-separated AML segments, for example `aml__SB_.LFT0.STEP` for `\_SB_.LFT0.STEP`. Root methods keep names such as `aml_STEP`. A `Scope` opens an existing namespace node, including ACPI's predefined scopes.

## 2. Integer operations and control flow

- [x] Add `Else` and handle local initialization at branch joins.
- [x] Add `Break`, `Continue`, and `Noop`. Verify nested loops, early returns, and unreachable instructions.
- [x] Fill out integer arithmetic, bitwise operations, and logical comparisons. Check overflow, shifts, division errors, and target writes.
- [x] Add revision-1 DSDT support and derive AML integer width for SSDTs from the loaded DSDT.
- [x] Compare boundary values and branch outcomes with uACPI in optimized and unoptimized native builds.

## 3. Runtime ABI and table loading

- [x] Define a native calling convention for the execution context, AML arguments, return values, and error statuses.
- [x] Move named state into the execution context and define how new contexts initialize it.
- [x] Resolve `External` declarations, `Alias` objects, and references across a DSDT and its SSDTs.
- [x] Define behavior for duplicate definitions, unresolved references, table initialization order, and method execution limits.
- [x] Verify that one context can run methods across two tables and that two contexts maintain independent state.

### Native ABI

Include [src/runtime.h](src/runtime.h) on a 64-bit host and link one generated module.
Call `aml_context_create()` to allocate an opaque context, then
`aml_context_destroy(ctx)` to release it. Creation returns null on allocation failure.
Each context initializes its own copy of the linked named objects.

Exported methods use the signature
`int32_t aml_METHOD(aml_context *ctx, uint64_t *result, ...)`, with one
`uint64_t` parameter per declared AML argument in order. For methods with
arguments, replace the ellipsis with the exact parameter list in the C declaration.
The return code is an `aml_status` value. Success writes the integer result,
zero-extended for 32-bit AML. Errors leave the result untouched and preserve
any named-state writes completed before the error. A call requires a live context
from the linked module and a writable result pointer. Null pointers return
`AML_INVALID_ARGUMENT`.

Each host call starts with a budget of 100,000 steps and a maximum depth of 64
active AML method frames. Method entries and loop predicate evaluations consume one
step each. Nested calls share the budget and context. Exhausting either limit
returns `AML_EXECUTION_LIMIT`, and dividing by zero returns
`AML_DIVISION_BY_ZERO`. A later host call gets a fresh budget.

### Linked tables

Pass a DSDT followed by SSDTs in load order. The DSDT revision sets the integer
width for all linked tables. A standalone SSDT uses 64-bit AML integers.
The `--dsdt` option prepends the given DSDT to the input list and now loads
its namespace and methods as well as supplying the revision.

Declarations are indexed in table and source order. A declaration's parent and a
`Scope` target must already exist. Once indexing finishes, method bodies can
refer to definitions from any input table. Aliases to named values and methods share the target's storage or implementation,
including through alias chains.
Aliases used to open a `Scope` must resolve when the scope is opened.
Duplicate definitions, invalid alias chains, and incompatible definitions for direct
`External` declarations are compile errors. Supported
`External` types are Unknown, Integer, String, Buffer, Package, BufferField,
Device, and Method. Method declarations must agree on argument count.
Context creation initializes named values and buffer fields and runs module-level
`If` and `Else` blocks containing executable statements in table and source order.
The compiler treats `External` declarations inside iASL's `If (Zero)` wrapper
as metadata. Executable references resolve against the loaded definitions.
A method `External` supplies the argument count for a call when the definition
is absent. Executing that call reports `AML_UNRESOLVED_EXTERNAL`, and
`CondRefOf` reports the method as absent. Other unresolved references are compile errors.
An `If` or `While` guarded by `CondRefOf` can skip a branch that is unreachable
because the referenced object is absent from the supplied tables.

```sh
mkdir -p target
iasl -p target/runtime-dsdt tests/runtime-dsdt.asl
iasl -p target/runtime-ssdt tests/runtime-ssdt.asl
cargo run --quiet --locked -- --emit-llvm target/runtime-dsdt.aml target/runtime-ssdt.aml > target/runtime.ll
opt -S -passes='verify,default<O2>,verify' target/runtime.ll -o target/runtime-opt.ll
clang -std=c17 -Wall -Wextra -Werror -Wno-override-module target/runtime-opt.ll tests/runtime.c -o target/runtime-test
target/runtime-test
target/uacpi/test-runner target/runtime-dsdt.aml --extra-tables target/runtime-ssdt.aml --expect int 4242 --log-level warning
```

## 4. AML values and object semantics

- [x] Add strings, buffers, and packages one type at a time, including dynamic sizes where supported.
- [x] Define value ownership, lifetime, and copy behavior across method calls and returns.
- [x] Add references and indexing, including `RefOf`, `CondRefOf`, `DerefOf`, and `Index`.
- [x] Add buffer fields and test bit-level reads and writes through them.
- [x] Implement type conversions, comparisons across supported values, and target-specific `Store` behavior.
- [x] Compare object types, returned values, and mutations through references with uACPI.

Strings, buffers, and packages can be stored in locals, passed between AML
methods, and returned. Buffer and variable-package sizes can come from AML
expressions. `Store` into an ordinary local copies its source. Index and
explicit references retain the underlying storage so writes through them are
visible to other references. `Store` into a named integer, string, or buffer
writes into its existing storage. `CopyObject` can replace a named value's type.
Buffer fields can be declared at table or method scope.

The `aml_value_<path>` exports accept the same integer arguments as
`aml_<path>` and use an `aml_value *` result. A host result contains a snapshot
with references resolved to their values. Result data is readable until the next
method invocation on its context or context destruction. Recompile clients of
the initial string-only value ABI against the expanded
[src/runtime.h](src/runtime.h). The integer ABI is unchanged. Each context can
allocate up to 64 MiB of object storage and reclaims unreachable allocations
between host calls.

LLVM emission requires matching versions of `clang` and `llvm-link` on a
64-bit host. To select specific executables, set `AMLAOT_CLANG` and
`AMLAOT_LLVM_LINK`.

```sh
mkdir -p target
iasl -p target/objects tests/objects.asl
make run AML=target/objects.aml TESTBENCH=tests/objects.c
make run AML=target/objects.aml TESTBENCH=tests/objects.c PASSES=
target/uacpi/test-runner target/objects.aml --expect int 49 --log-level warning

iasl -D STRING_RESULT -p target/object-string tests/objects.asl
target/uacpi/test-runner target/object-string.aml --expect str xy --log-level warning
```

## 5. Host interaction and synchronization

- [x] Implement serialized methods, mutexes, events, and sync levels.
- [x] Handle additional namespace objects such as `Processor`, `PowerResource`, and `ThermalZone`.
- [x] Add host callbacks for timing, notifications, and operation-region access.
- [x] Implement `OperationRegion`, `Field`, `BankField`, and `IndexField`, including access widths and update rules.
- [x] Handle dynamic table loading and unloading and invalidate affected method and namespace bindings.
- [x] Use a simulated host to compare reads, writes, notifications, timeout behavior, and synchronization with uACPI.

See [Roadmap item 5 status](ROADMAP-5-STATUS.md) for the scalar region and precompiled SSDT support limits.

## 6. Coverage and compiler validation

- [ ] Automate the comparison with uACPI so one command can run the supported fixture suite.
- [ ] Track parser, lowering, and runtime support by opcode and operand form. Record the coverage target and remaining gaps for each release.
- [ ] Add malformed-input checks and parser fuzzing for package boundaries, name encodings, and deep nesting.
- [ ] Run a corpus of real DSDT and SSDT tables. Compare supported method results and side effects and report unsupported constructs with file offsets.
- [ ] Produce a reusable native object and list its exported methods and their AML paths.
- [ ] Document the supported native ABI, LLVM toolchain, fixture commands, and known compatibility limits.

## Run the current fixtures

```sh
make run

mkdir -p target
iasl -p target/named-integers tests/named-integers.asl
make run AML=target/named-integers.aml TESTBENCH=tests/named-integers.c

# Preserve the explicit AML name encodings for the namespace comparison.
iasl -on -p target/nested-namespaces tests/nested-namespaces.asl
make run AML=target/nested-namespaces.aml TESTBENCH=tests/nested-namespaces.c

cmake -S uacpi/tests/runner -B target/uacpi
cmake --build target/uacpi --target test-runner
target/uacpi/test-runner target/nested-namespaces.aml --expect int 15041122 --log-level warning
```
