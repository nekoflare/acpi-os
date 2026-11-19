AML ?= example.aml
IR ?=
CARGO ?= cargo
OPT ?= opt
CLANG ?= clang
PASSES ?= default<O2>
TESTBENCH ?= tests/native.c

export AML IR PASSES TESTBENCH

.PHONY: all ir run
all: ir

.PHONY: run-uefi
run-uefi:
	$(MAKE) -C acpi-kernel run-uefi

ir run:
	@set -eu; \
	input="$$AML"; \
	output="$$IR"; \
	if [ -z "$$output" ]; then \
		name=$${input##*/}; \
		output="target/$${name%.*}.ll"; \
	fi; \
	if [ "$$input" -ef "$$output" ] || [ -d "$$output" ]; then \
		printf 'Invalid IR output path: %s\n' "$$output" >&2; \
		exit 1; \
	fi; \
	mkdir -p -- "$$(dirname -- "$$output")"; \
	tmpdir=$$(mktemp -d -- "$$output.tmp.XXXXXX"); \
	trap 'rm -f -- "$$tmpdir/input.ll" "$$tmpdir/output.ll" "$$tmpdir/native-test"; rmdir -- "$$tmpdir"' EXIT; \
	trap 'exit 1' HUP INT TERM; \
	pipeline=verify; \
	if [ -n "$$PASSES" ]; then \
		pipeline="verify,$$PASSES,verify"; \
	fi; \
	$(CARGO) run --quiet --locked -- --emit-llvm "$$input" > "$$tmpdir/input.ll"; \
	$(OPT) -S -passes="$$pipeline" -o "$$tmpdir/output.ll" < "$$tmpdir/input.ll"; \
	if [ "$@" = run ]; then \
		$(CLANG) -std=c17 -Wall -Wextra -Werror -Wno-override-module \
			"$$tmpdir/output.ll" "$$TESTBENCH" -o "$$tmpdir/native-test"; \
		"$$tmpdir/native-test"; \
	fi; \
	mv -f -- "$$tmpdir/output.ll" "$$output"; \
	printf '%s\n' "$$output"
