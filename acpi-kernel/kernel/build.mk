KERNEL_FLAGS := -O2 -mcmodel=kernel -mno-red-zone -mgeneral-regs-only -fno-pic
BOOT_FLAGS := $(KERNEL_FLAGS) -std=c17 -ffreestanding -fno-stack-protector -Wall -Wextra -Werror

$(BUILD):
	mkdir -p $@

# The vDSO, linked as a shared object and embedded in the AML as a buffer.
VDSO_FLAGS := -O2 -fPIC -fasynchronous-unwind-tables -ffreestanding -fno-builtin -fno-stack-protector -fcf-protection=none -Wall -Wextra -Werror

$(BUILD)/vdso.o: kernel/vdso.c kernel/build.mk | $(BUILD)
	$(CLANG) $(VDSO_FLAGS) -c $< -o $@

$(BUILD)/vdso.so: $(BUILD)/vdso.o kernel/vdso.lds kernel/vdso.map
	$(LLD) -shared -T kernel/vdso.lds --version-script=kernel/vdso.map --hash-style=both \
		--eh-frame-hdr -soname=linux-vdso.so.1 -z max-page-size=4096 -z norelro -s $< -o $@

$(BUILD)/vdso.asl: $(BUILD)/vdso.so scripts/bin2asl.py
	$(PYTHON) scripts/bin2asl.py VDSO $< $@

$(BUILD)/kernel.aml: kernel/kernel.asl $(filter-out kernel/kernel.asl,$(wildcard kernel/*.asl)) $(BUILD)/vdso.asl | $(BUILD)
	$(IASL) -I kernel -I $(BUILD) -p $(basename $@) $<

copy-aml: $(BUILD)/kernel.aml
	cp -- "$<" ./kernel.aml

$(BUILD)/linked.ll: $(BUILD)/kernel.aml ../Cargo.toml ../Cargo.lock $(wildcard ../src/*) | $(BUILD)
	AMLAOT_CLANG="$(CLANG)" cargo run --locked --manifest-path ../Cargo.toml -- --emit-llvm --freestanding $< > $@

$(BUILD)/kernel.bc: $(BUILD)/linked.ll kernel/build.mk
	$(OPT) -force-attribute=noredzone -internalize-public-api-list=aml_context_create_with_host,aml_KERN,aml_SSTP,aml_interrupt_BRKP \
		-passes='forceattrs,internalize,always-inline,default<O2>,globaldce,verify' $< -o $@

$(BUILD)/aml.o: $(BUILD)/kernel.bc
	$(CLANG) $(KERNEL_FLAGS) -c $< -o $@

$(BUILD)/boot.o: kernel/boot.c ../src/runtime.h kernel/build.mk | $(BUILD)
	$(CLANG) $(BOOT_FLAGS) -c $< -o $@

$(BUILD)/early-memory.o: kernel/early-memory.c kernel/build.mk | $(BUILD)
	$(CLANG) $(BOOT_FLAGS) -c $< -o $@

$(BUILD)/x86.o: kernel/x86.S kernel/build.mk | $(BUILD)
	$(CLANG) $(KERNEL_FLAGS) -c $< -o $@

INITRAMFS_FILES := $(if $(INITRAMFS_FSTAB),,$(wildcard initramfs/*) $(call guest_bins,$(BUILD)/ls $(BOOT_ELF))) $(INITRAMFS_EXTRA)

$(BUILD)/initramfs.img: scripts/pack-initramfs.py initramfs $(foreach spec,$(INITRAMFS_FILES),$(lastword $(subst =, ,$(spec)))) $(INITRAMFS_FSTAB) $(if $(INITRAMFS_FSTAB),config/hosts) $(INITRAMFS_FONT) $(BUILD)/initramfs.inputs kernel/build.mk | $(BUILD)
	$(PYTHON) $< $@ $(INITRAMFS_FILES) $(if $(INITRAMFS_FSTAB),etc/fstab=$(INITRAMFS_FSTAB) etc/hosts=config/hosts) $(if $(INITRAMFS_FONT),fonts/dwm-font.ttf=$(INITRAMFS_FONT))

$(BUILD)/initramfs.o: kernel/embed-initramfs.S $(BUILD)/initramfs.img kernel/build.mk
	$(CLANG) $(KERNEL_FLAGS) -DINITRAMFS_IMAGE='"$(BUILD)/initramfs.img"' -c $< -o $@

$(BUILD)/kernel.elf: $(BUILD)/boot.o $(BUILD)/early-memory.o $(BUILD)/aml.o $(BUILD)/x86.o $(BUILD)/initramfs.o kernel/link.ld
	$(LLD) -static -T kernel/link.ld $(filter %.o,$^) -o $@

.PHONY: kernel-build-force
$(BUILD)/initramfs.inputs: kernel-build-force | $(BUILD)
	@printf '%s\n' "$(INITRAMFS_FILES)" "$(INITRAMFS_FSTAB)" "$(INITRAMFS_FONT)" > "$@.tmp"
	@if cmp -s "$@.tmp" "$@"; then rm -f "$@.tmp"; else mv -f "$@.tmp" "$@"; fi
