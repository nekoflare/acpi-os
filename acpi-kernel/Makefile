BUILD := ../target/acpi-kernel
BOOT_ELF = $(BUILD)/hello.elf
BOOT_CONFIG = limine.conf
BOOT_MODULE = hello.elf
BASH_BUILD := $(abspath ../target/acpi-kernel-bash)
MLIBC_BUILD := $(abspath ../target/acpi-kernel-mlibc)
MLIBC_SYSROOT := $(MLIBC_BUILD)/sysroot/usr
MESON ?= meson
MLIBC_UAPI ?=
MLIBC_JOBS ?= 8
CLANG ?= clang
CLANGXX ?= clang++
OPT ?= opt
LLD ?= ld.lld
IASL ?= iasl
LIMINE_DIR ?= /usr/share/limine
QEMU ?= qemu-system-x86_64
QEMU_CPU ?=
XORRISO ?= xorriso
PYTHON ?= python3
OVMF ?= /usr/share/edk2/x64/OVMF_CODE.4m.fd

KERNEL_FLAGS := -O2 -mcmodel=kernel -mno-red-zone -mgeneral-regs-only -fno-pic
BOOT_FLAGS := $(KERNEL_FLAGS) -std=c17 -ffreestanding -fno-stack-protector -Wall -Wextra -Werror
QEMU_FLAGS := -m 8G -boot d -cdrom $(BUILD)/acpi-kernel.iso -serial stdio -monitor none -no-reboot -enable-kvm $(if $(QEMU_CPU),-cpu $(QEMU_CPU))
CHECK_QEMU_FLAGS := $(QEMU_FLAGS) -smp 4
BOOT_CHECK = awk '/ASL GDT loaded/ && stage == 0 { stage = 1 } \
	/ASL IDT loaded with 256 gates/ && stage == 1 { stage = 2 } \
	/ASL breakpoint handler/ && stage == 2 { stage = 3 } \
	stage == 3 && /^[A-Z0-9]+=0x[0-9a-f]+/ { split($$0, fields, "="); regs[fields[1]] = 1 } \
	/ASL resumed after int3/ && stage == 3 { stage = 4; print } \
	stage == 4 && /^Memory base=0x[0-9a-f]+ length=0x[0-9a-f]+ type=Usable\r?$$/ { ++ranges } \
	stage == 4 && /^ASL page [12] physical=0x[0-9a-f]+000\r?$$/ { examples[$$3] = $$4 } \
	stage == 4 && /^ASL virtual page mapper ready\r?$$/ { virtual_pages = 1 } \
	stage == 4 && /^ASL virtual range allocator ready\r?$$/ { virtual_ranges = 1 } \
	stage == 4 && /^ASL page allocator ready\r?$$/ { pages = 1 } \
	stage == 4 && /^ACPI table / && $$4 ~ /^address=0x[0-9a-f]+$$/ && \
		length($$4) == 26 && $$5 ~ /^size=0x[0-9a-f]+$$/ { tables[$$3] = 1 } \
	stage == 4 && /^LAPIC ID=0x[0-9a-f]+ ACPI UID=0x[0-9a-f]+ flags=0x0*1\r?$$/ { lapics[$$2] = 1 } \
	stage == 4 && /^IOAPIC ID=0x[0-9a-f]+ address=0x0*fec00000 GSI base=0x0+\r?$$/ { ioapic = 1 } \
	stage == 4 && /^LAPIC address=0x0*fee00000\r?$$/ { lapic_base = 1 } \
	stage == 4 && /^PIT routed through IOAPIC GSI=0x0*2\r?$$/ { pit = 1 } \
	stage == 4 && /^LAPIC timer calibrated ticks per PIT period=0x[0-9a-f]*[1-9a-f][0-9a-f]*\r?$$/ { calibration = 1 } \
	stage == 4 && /^LAPIC periodic timer delivered 3 interrupts\r?$$/ { timer = 1 } \
	stage == 4 && timer && /^LAPIC tick counter reached 100\r?$$/ { ticks = 1 } \
	stage == 4 && timer && /^PS\/2 keyboard IRQ ready\r?$$/ { keyboard = 1 } \
	stage == 4 && ticks && keyboard && /^What is your name\?\r?$$/ { prompt = 1 } \
	stage == 4 && prompt && /^Hello, Ada!\r?$$/ { hello = 1 } \
	stage == 4 && hello && /^hello\.elf exited status=0x0000000000000000\r?$$/ { user_exit = 1 } \
	stage == 4 && bash_check && ticks && keyboard && /^0\r?$$/ { bash_pid = 1 } \
	stage == 4 && bash_pid && /^Bash sourced the read-only initramfs\r?$$/ { bash_source = 1 } \
	stage == 4 && bash_source && /^bash\.elf exited status=0x0000000000000000\r?$$/ { user_exit = 1 } \
	BEGIN { n = split("R15 R14 R13 R12 R11 R10 R9 R8 RDI RSI RBP RBX RDX RCX RAX RIP CS RFLAGS RSP SS", expected, " ") } \
	END { for (i = 1; i <= n; ++i) if (!(expected[i] in regs)) exit 1; \
	      for (i = 0; i < 4; ++i) if (!(sprintf("ID=0x%016x", i) in lapics)) exit 1; \
	      n = split("RSDP FACP FACS DSDT APIC HPET WAET", expected, " "); \
	      for (i = 1; i <= n; ++i) if (!(expected[i] in tables)) exit 1; \
	      if (!(root in tables)) exit 1; \
	      exit stage != 4 || !pages || !virtual_pages || !virtual_ranges || !ranges || !ioapic || !lapic_base || !pit || !calibration || !user_exit || \
	           !(1 in examples) || !(2 in examples) || examples[1] == examples[2] }'

.DELETE_ON_ERROR:
.PHONY: all run run-uefi check check-uefi
all: $(BUILD)/acpi-kernel.iso

$(BUILD):
	mkdir -p $@

$(BUILD)/kernel.aml: kernel.asl font8x8.asl | $(BUILD)
	$(IASL) -p $(basename $@) $<

$(BUILD)/linked.ll: $(BUILD)/kernel.aml ../Cargo.toml ../Cargo.lock $(wildcard ../src/*)
	AMLAOT_CLANG="$(CLANG)" cargo run --quiet --locked --manifest-path ../Cargo.toml -- --emit-llvm --freestanding $< > $@

$(BUILD)/kernel.bc: $(BUILD)/linked.ll Makefile
	$(OPT) -force-attribute=noredzone -internalize-public-api-list=aml_context_create_with_host,aml_KERN,aml_interrupt_BRKP \
		-passes='forceattrs,internalize,always-inline,default<O2>,globaldce,verify' $< -o $@

$(BUILD)/aml.o: $(BUILD)/kernel.bc
	$(CLANG) $(KERNEL_FLAGS) -c $< -o $@

$(BUILD)/boot.o: boot.c ../src/runtime.h Makefile | $(BUILD)
	$(CLANG) $(BOOT_FLAGS) -c $< -o $@

$(BUILD)/early-memory.o: early-memory.c Makefile | $(BUILD)
	$(CLANG) $(BOOT_FLAGS) -c $< -o $@

$(BUILD)/x86.o: x86.S Makefile | $(BUILD)
	$(CLANG) $(KERNEL_FLAGS) -c $< -o $@

$(BUILD)/hello.o: hello.S Makefile | $(BUILD)
	$(CLANG) --target=x86_64-unknown-none-elf -c $< -o $@

$(BUILD)/hello.elf: $(BUILD)/hello.o Makefile
	$(LLD) -static -e _start $< -o $@

$(BUILD)/ls.o: ls.c Makefile | $(BUILD)
	$(CLANG) --target=x86_64-unknown-none-elf -O2 -ffreestanding -fno-stack-protector \
		-fno-pie -Wall -Wextra -Werror -c $< -o $@

$(BUILD)/ls: $(BUILD)/ls.o Makefile
	$(LLD) -static -z separate-loadable-segments -e _start $< -o $@

INITRAMFS_FILES := $(wildcard initramfs/*) $(BUILD)/ls $(INITRAMFS_EXTRA)

$(BUILD)/initramfs.img: pack-initramfs.py initramfs $(INITRAMFS_FILES) Makefile | $(BUILD)
	$(PYTHON) $< $@ $(INITRAMFS_FILES)

$(BUILD)/initramfs.o: embed-initramfs.S $(BUILD)/initramfs.img Makefile
	$(CLANG) $(KERNEL_FLAGS) -DINITRAMFS_IMAGE='"$(BUILD)/initramfs.img"' -c $< -o $@

$(BUILD)/kernel.elf: $(BUILD)/boot.o $(BUILD)/early-memory.o $(BUILD)/aml.o $(BUILD)/x86.o $(BUILD)/initramfs.o link.ld
	$(LLD) -static -T link.ld $(filter %.o,$^) -o $@

LIMINE_FILES := $(addprefix $(LIMINE_DIR)/,limine-bios-cd.bin limine-bios.sys limine-uefi-cd.bin)

$(BUILD)/acpi-kernel.iso: $(BUILD)/kernel.elf $(BOOT_ELF) $(BOOT_CONFIG) $(LIMINE_FILES) $(LIMINE_DIR)/BOOTX64.EFI Makefile
	mkdir -p $(BUILD)/iso/boot/limine $(BUILD)/iso/EFI/BOOT
	cp $(BUILD)/kernel.elf $(BUILD)/iso/boot/
	cp $(BOOT_ELF) $(BUILD)/iso/boot/$(BOOT_MODULE)
	cp $(BOOT_CONFIG) $(BUILD)/iso/boot/limine/limine.conf
	cp $(LIMINE_FILES) $(BUILD)/iso/boot/limine/
	cp $(LIMINE_DIR)/BOOTX64.EFI $(BUILD)/iso/EFI/BOOT/
	$(XORRISO) -as mkisofs -R -b boot/limine/limine-bios-cd.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		-eltorito-alt-boot -e boot/limine/limine-uefi-cd.bin -no-emul-boot \
		$(BUILD)/iso -o $@

run: all
	$(QEMU) $(QEMU_FLAGS)

run-uefi: bash
	$(MAKE) $(BASH_BOOT) QEMU_CPU="$(or $(QEMU_CPU),host)" boot-uefi

.PHONY: boot-uefi
boot-uefi: all
	$(QEMU) $(QEMU_FLAGS) -drive if=pflash,format=raw,readonly=on,file="$(OVMF)"

check: all
	@if ! MLIBC_CHECK="$(MLIBC_CHECK)" BASH_CHECK="$(BASH_CHECK)" $(PYTHON) boot-check.py $(BUILD)/serial.log $(BUILD)/qemu.log $(QEMU) $(CHECK_QEMU_FLAGS) || \
		! $(BOOT_CHECK) root=RSDT bash_check="$(BASH_CHECK)" $(BUILD)/serial.log; then \
		    cat $(BUILD)/serial.log $(BUILD)/qemu.log; exit 1; \
		fi

check-uefi: all
	@if ! MLIBC_CHECK="$(MLIBC_CHECK)" BASH_CHECK="$(BASH_CHECK)" $(PYTHON) boot-check.py $(BUILD)/serial-uefi.log $(BUILD)/qemu-uefi.log $(QEMU) $(CHECK_QEMU_FLAGS) \
		-drive if=pflash,format=raw,readonly=on,file="$(OVMF)" || \
		! $(BOOT_CHECK) root=XSDT bash_check="$(BASH_CHECK)" $(BUILD)/serial-uefi.log; then \
		    cat $(BUILD)/serial-uefi.log $(BUILD)/qemu-uefi.log; exit 1; \
		fi

.PHONY: mlibc run-mlibc check-mlibc check-mlibc-uefi
mlibc: $(MLIBC_BUILD)/hello-mlibc.elf
	$(MAKE) BUILD="$(MLIBC_BUILD)" BOOT_ELF="$<" all

run-mlibc: mlibc
	$(MAKE) BUILD="$(MLIBC_BUILD)" BOOT_ELF="$(MLIBC_BUILD)/hello-mlibc.elf" run

check-mlibc: mlibc
	$(MAKE) BUILD="$(MLIBC_BUILD)" BOOT_ELF="$(MLIBC_BUILD)/hello-mlibc.elf" MLIBC_CHECK=1 check

check-mlibc-uefi: mlibc
	$(MAKE) BUILD="$(MLIBC_BUILD)" BOOT_ELF="$(MLIBC_BUILD)/hello-mlibc.elf" MLIBC_CHECK=1 check-uefi

$(MLIBC_SYSROOT)/lib/libc.a: build-mlibc.sh
	sh $< "$(MLIBC_BUILD)" "$(MESON)" "$(CLANG)" "$(CLANGXX)" "$(MLIBC_UAPI)" "$(MLIBC_JOBS)"

$(MLIBC_BUILD)/hello-mlibc.elf: hello-mlibc.c $(MLIBC_SYSROOT)/lib/libc.a Makefile
	$(CLANG) -O2 -march=x86-64 -fno-pie -Wall -Wextra -Werror -nostdinc \
		-isystem "$(MLIBC_SYSROOT)/include" -c $< -o $(MLIBC_BUILD)/hello-mlibc.o
	$(LLD) -static -z separate-loadable-segments -e _start "$(MLIBC_SYSROOT)/lib/crt1.o" \
		$(MLIBC_BUILD)/hello-mlibc.o "$(MLIBC_SYSROOT)/lib/libc.a" -o $@

BASH_BOOT = BUILD="$(BASH_BUILD)" BOOT_ELF="$(BASH_BUILD)/bash.elf" \
	BOOT_CONFIG=limine-bash.conf BOOT_MODULE=bash.elf BASH_CHECK=1 \
	INITRAMFS_EXTRA="$(BASH_BUILD)/fastfetch $(BASH_BUILD)/fbtest $(BASH_BUILD)/doom $(DOOM_DATA)"

.PHONY: bash run-bash check-bash check-bash-uefi
bash: $(BASH_BUILD)/bash.elf $(BASH_BUILD)/fbtest $(BASH_BUILD)/doom doom-wad
	$(MAKE) $(BASH_BOOT) all

run-bash: bash
	$(MAKE) $(BASH_BOOT) run

check-bash: bash
	$(MAKE) $(BASH_BOOT) check

check-bash-uefi: bash
	$(MAKE) $(BASH_BOOT) check-uefi

$(BASH_BUILD)/bash.elf: build-bash.sh $(MLIBC_SYSROOT)/lib/libc.a
	+sh $< "$(BASH_BUILD)" "$(MLIBC_BUILD)/sysroot" "$(CLANG)" "$(LLD)" "$(MLIBC_UAPI)"

$(BASH_BUILD)/fbtest: fbtest.c $(MLIBC_SYSROOT)/lib/libc.a Makefile
	$(CLANG) -O2 -march=x86-64 -fno-pie -Wall -Wextra -Werror -nostdinc \
		-isystem "$(MLIBC_SYSROOT)/include" -idirafter "$(if $(MLIBC_UAPI),$(MLIBC_UAPI),$(MLIBC_BUILD)/linux-uapi)" \
		-c $< -o $(BASH_BUILD)/fbtest.o
	$(LLD) -static -z separate-loadable-segments "$(MLIBC_SYSROOT)/lib/crt1.o" \
		$(BASH_BUILD)/fbtest.o "$(MLIBC_SYSROOT)/lib/libc.a" -o $@

FASTFETCH_BUILD := $(abspath ../target/acpi-kernel/fastfetch)
$(BASH_BUILD)/fastfetch: $(FASTFETCH_BUILD)/fastfetch.elf
	cp $< $@

FASTFETCH_BOOT = BUILD="$(FASTFETCH_BUILD)" BOOT_ELF="$(FASTFETCH_BUILD)/fastfetch.elf" \
	BOOT_CONFIG=limine-fastfetch.conf BOOT_MODULE=fastfetch.elf

.PHONY: fastfetch run-fastfetch
fastfetch: $(FASTFETCH_BUILD)/fastfetch.elf
	$(MAKE) $(FASTFETCH_BOOT) all

run-fastfetch: fastfetch
	$(MAKE) $(FASTFETCH_BOOT) run

$(FASTFETCH_BUILD)/fastfetch.elf: build-fastfetch.sh fastfetch-mlibc.patch fastfetch-cpu.patch $(MLIBC_SYSROOT)/lib/libc.a
	sh $< "$(FASTFETCH_BUILD)" "$(MLIBC_BUILD)/sysroot" "$(CLANG)" "$(LLD)" "$(MLIBC_UAPI)" "$(MLIBC_JOBS)"

DOOM_BUILD := $(abspath ../target/acpi-kernel-doom)
DOOM_SHAREWARE_ARCHIVE := $(DOOM_BUILD)/doom-1.8.wad.gz
DOOM_SHAREWARE_WAD := $(DOOM_BUILD)/doom1.wad
DOOM_WAD ?= $(DOOM_SHAREWARE_WAD)
DOOM_DATA := $(DOOM_BUILD)/doom.wad
ifeq ($(DOOM_WAD),$(DOOM_SHAREWARE_WAD))
doom-wad: $(DOOM_SHAREWARE_WAD)
endif
DOOM_BOOT = BUILD="$(DOOM_BUILD)" BOOT_ELF="$(DOOM_BUILD)/doom.elf" \
	BOOT_CONFIG=limine-doom.conf BOOT_MODULE=doom.elf INITRAMFS_EXTRA="$(DOOM_DATA)"

.PHONY: doom run-doom run-doom-uefi doom-wad
doom: $(DOOM_BUILD)/doom.elf doom-wad
	$(MAKE) $(DOOM_BOOT) all

run-doom: doom
	$(MAKE) $(DOOM_BOOT) run

run-doom-uefi: doom
	$(MAKE) $(DOOM_BOOT) boot-uefi

doom-wad:
	@test -n "$(DOOM_WAD)" && test -f "$(DOOM_WAD)" || \
		{ echo "Set DOOM_WAD to the path of a Doom or Freedoom IWAD." >&2; exit 1; }
	mkdir -p "$(DOOM_BUILD)"
	@cmp -s -- "$(DOOM_WAD)" "$(DOOM_BUILD)/doom.wad" || cp -- "$(DOOM_WAD)" "$(DOOM_BUILD)/doom.wad"

$(BASH_BUILD)/doom: $(DOOM_BUILD)/doom.elf
	mkdir -p "$(BASH_BUILD)"
	cp "$<" "$@"

$(DOOM_SHAREWARE_ARCHIVE):
	mkdir -p "$(DOOM_BUILD)"
	curl -fL --retry 2 "https://www.gamers.org/pub/idgames/idstuff/doom/doom-1.8.wad.gz" -o "$@.tmp"
	printf '%s  %s\n' 58cf6a563b631a47561630afa6276d853c27079342f7969ec3006965da8557a1 "$@.tmp" | sha256sum -c -
	mv "$@.tmp" "$@"

$(DOOM_SHAREWARE_WAD): $(DOOM_SHAREWARE_ARCHIVE)
	gzip -dc "$<" > "$@"

$(DOOM_BUILD)/doom.elf: build-doom.sh doomgeneric-asl.c $(MLIBC_SYSROOT)/lib/libc.a Makefile
	+sh $< "$(DOOM_BUILD)" "$(MLIBC_SYSROOT)" \
		"$(abspath $(if $(MLIBC_UAPI),$(MLIBC_UAPI),$(MLIBC_BUILD)/linux-uapi))" "$(CLANG)" "$(LLD)"
