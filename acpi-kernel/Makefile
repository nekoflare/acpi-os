.DEFAULT_GOAL := all
BUILD := ../target/acpi-kernel
BOOT_ELF = $(BUILD)/hello.elf
BOOT_CONFIG = config/limine.conf
BOOT_MODULE = hello.elf
BASH_BUILD := $(abspath ../target/acpi-kernel-bash)
MLIBC_BUILD := $(abspath ../target/acpi-kernel-mlibc)
MLIBC_JOBS ?= 8
DWM ?= 0
DWM_BUILD := $(abspath ../target/acpi-kernel-dwm)
DWM_FONT ?= $(shell fc-match -f '%{file}' monospace)
DWM_APPS = $(if $(filter 1,$(DWM)),$(DWM_BUILD)/dwm $(DWM_BUILD)/xeyes)
DWM_EXTRA = $(if $(DWM_APPS),$(DWM_APPS) $(DWM_BUILD)/dwm-font.ttf config/dwm-fonts.conf)
BASH_IMAGE_BUILD = $(if $(DWM_EXTRA),$(DWM_BUILD),$(BASH_BUILD))
BASH_CONFIG = $(if $(DWM_EXTRA),config/limine-dwm.conf,config/limine-bash.conf)
BASH_STARTUP = $(if $(DWM_EXTRA),config/dwm-start.sh,config/x11-start.sh)
CLANG ?= clang
OPT ?= opt
LLD ?= ld.lld
IASL ?= iasl
LIMINE_DIR ?= /usr/share/limine
QEMU ?= qemu-system-x86_64
QEMU_CPU ?= host
SMP_CPUS ?= 4
XORRISO ?= xorriso
PYTHON ?= python3
OVMF ?= /usr/share/edk2/x64/OVMF_CODE.4m.fd

guest_bins = $(foreach app,$(1),bin/$(notdir $(app))=$(app))

APP_ARCH ?= native
include ports/Makefile

QEMU_FLAGS := -m 8G -boot d -cdrom $(BUILD)/acpi-kernel.iso -serial stdio -monitor none -no-reboot -enable-kvm $(if $(QEMU_CPU),-cpu $(QEMU_CPU)) -smp $(SMP_CPUS)
CHECK_QEMU_FLAGS := $(QEMU_FLAGS)
BOOT_CHECK = awk -v cpus="$(SMP_CPUS)" '/ASL GDT loaded/ && stage == 0 { stage = 1 } \
	/ASL IDT loaded with 256 gates/ && stage == 1 { stage = 2 } \
	/^SMP CPUs online=0x/ && stage == 2 { sub(/\r$$/, ""); online = ($$3 == sprintf("online=0x%016x", cpus)) } \
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
	stage == 4 && /^SMP tasks ran simultaneously on multiple CPUs\r?$$/ { parallel = 1 } \
	stage == 4 && ticks && keyboard && /^What is your name\?\r?$$/ { prompt = 1 } \
	stage == 4 && prompt && /^Hello, Ada!\r?$$/ { hello = 1 } \
	stage == 4 && hello && /^hello\.elf exited status=0x0000000000000000\r?$$/ { user_exit = 1 } \
	stage == 4 && bash_check && ticks && keyboard && /^0\r?$$/ { bash_pid = 1 } \
	stage == 4 && bash_pid && /^Bash sourced the read-only initramfs\r?$$/ { bash_source = 1 } \
	stage == 4 && bash_source && /^bash\.elf exited status=0x0000000000000000\r?$$/ { user_exit = 1 } \
	BEGIN { n = split("R15 R14 R13 R12 R11 R10 R9 R8 RDI RSI RBP RBX RDX RCX RAX RIP CS RFLAGS RSP SS", expected, " ") } \
	END { for (i = 1; i <= n; ++i) if (!(expected[i] in regs)) exit 1; \
	      if (length(lapics) != cpus || !online || (cpus > 1 && !parallel)) exit 1; \
	      n = split("RSDP FACP FACS DSDT APIC HPET WAET", expected, " "); \
	      for (i = 1; i <= n; ++i) if (!(expected[i] in tables)) exit 1; \
	      if (!(root in tables)) exit 1; \
	      exit stage != 4 || !pages || !virtual_pages || !virtual_ranges || !ranges || !ioapic || !lapic_base || !pit || !calibration || !user_exit || \
	           !(1 in examples) || !(2 in examples) || examples[1] == examples[2] }'

.DELETE_ON_ERROR:
.PHONY: all run run-uefi check check-uefi copy-aml
all: $(BUILD)/acpi-kernel.iso

include kernel/build.mk

$(eval $(call jinx_artifact,$(BUILD)/hello.elf,hello,usr/bin/hello.elf))

$(eval $(call jinx_artifact,$(BUILD)/ls,ls,usr/bin/ls))

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

run: all copy-aml
	$(QEMU) $(QEMU_FLAGS)

run-uefi: bash
	$(MAKE) $(BASH_BOOT) QEMU_CPU="$(or $(QEMU_CPU),host)" boot-uefi

.PHONY: boot-uefi
boot-uefi: all copy-aml
	$(QEMU) $(QEMU_FLAGS) -drive if=pflash,format=raw,readonly=on,file="$(OVMF)"

check: all
	@if ! MLIBC_CHECK="$(MLIBC_CHECK)" BASH_CHECK="$(BASH_CHECK)" DWM_CHECK="$(DWM_CHECK)" $(PYTHON) scripts/boot-check.py $(BUILD)/serial.log $(BUILD)/qemu.log $(QEMU) $(CHECK_QEMU_FLAGS) || \
		! $(BOOT_CHECK) root=RSDT bash_check="$(BASH_CHECK)" $(BUILD)/serial.log; then \
		    cat $(BUILD)/serial.log $(BUILD)/qemu.log; exit 1; \
		fi

check-uefi: all
	@if ! MLIBC_CHECK="$(MLIBC_CHECK)" BASH_CHECK="$(BASH_CHECK)" DWM_CHECK="$(DWM_CHECK)" $(PYTHON) scripts/boot-check.py $(BUILD)/serial-uefi.log $(BUILD)/qemu-uefi.log $(QEMU) $(CHECK_QEMU_FLAGS) \
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

$(eval $(call jinx_artifact,$(MLIBC_BUILD)/hello-mlibc.elf,hello-mlibc,usr/bin/hello-mlibc.elf))

$(eval $(call jinx_artifact,$(BASH_BUILD)/x11-demo,x11-demo,usr/bin/x11-demo))

BASH_BOOT = BUILD="$(BASH_IMAGE_BUILD)" BOOT_ELF="$(BASH_BUILD)/bash.elf" \
	BOOT_CONFIG="$(BASH_CONFIG)" BOOT_MODULE=bash.elf BASH_CHECK=1 DWM_CHECK="$(DWM)" \
	INITRAMFS_EXTRA="$(call guest_bins,$(BASH_BUILD)/fastfetch $(BASH_BUILD)/fbtest $(BASH_BUILD)/doom $(BASH_BUILD)/x11-demo $(DWM_APPS)) $(DOOM_DATA) $(BASH_STARTUP) $(filter %.conf,$(DWM_EXTRA))" \
	INITRAMFS_FONT="$(filter $(DWM_BUILD)/dwm-font.ttf,$(DWM_EXTRA))"

.PHONY: bash run-bash check-bash check-bash-uefi
bash: $(BASH_BUILD)/bash.elf $(BASH_BUILD)/fastfetch $(BASH_BUILD)/fbtest $(BASH_BUILD)/doom $(BASH_BUILD)/x11-demo $(DWM_EXTRA) doom-wad
	$(MAKE) $(BASH_BOOT) all

run-bash: bash
	$(MAKE) $(BASH_BOOT) run

check-bash: bash
	$(MAKE) $(BASH_BOOT) check

check-bash-uefi: bash
	$(MAKE) $(BASH_BOOT) check-uefi

.PHONY: xorg-server xorg-image xorg-desktop-image run-xorg-uefi st
XORG_BUILD ?= $(abspath ../target/acpi-kernel-xorg)
XORG_IMAGE_BUILD ?= $(abspath ../target/acpi-kernel-xorg-probe)
XORG_DESKTOP_BUILD ?= $(abspath ../target/acpi-kernel-xorg-desktop)
XORG_DESKTOP_ASSETS ?= $(DWM_BUILD)
ST_BUILD ?= $(abspath ../target/acpi-kernel-st)
xorg-server: $(XORG_BUILD)/Xvfb

$(eval $(call jinx_artifact,$(XORG_BUILD)/Xvfb,xvfb,usr/bin/Xvfb))

$(eval $(call jinx_artifact,$(XORG_BUILD)/xorg-default.xkm,xorg-keymap,usr/share/acpi-os/xorg-default.xkm))

$(eval $(call jinx_artifact,$(XORG_BUILD)/xorg-probe,xorg-probe,usr/bin/xorg-probe))

st: $(ST_BUILD)/st

$(eval $(call jinx_artifact,$(ST_BUILD)/st,st,usr/bin/st))

xorg-image: $(XORG_BUILD)/xorg-probe $(XORG_BUILD)/Xvfb $(XORG_BUILD)/xorg-default.xkm
	$(MAKE) BUILD="$(XORG_IMAGE_BUILD)" BOOT_ELF="$(XORG_BUILD)/xorg-probe" \
		BOOT_CONFIG=config/limine-xorg.conf BOOT_MODULE=xorg-probe \
		INITRAMFS_EXTRA="$(call guest_bins,$(XORG_BUILD)/Xvfb) $(XORG_BUILD)/xorg-default.xkm" all

XORG_FS_COMMANDS := cat cp mkdir mv rm rmdir
XORG_FS_TOOLS := $(XORG_BUILD)/fs-tools

$(eval $(call jinx_artifact,$(XORG_FS_TOOLS),fs-tools,usr/bin/fs-tools))

XORG_LS := $(XORG_BUILD)/busybox-ls

$(eval $(call jinx_artifact,$(XORG_LS),busybox-ls,usr/bin/busybox-ls))

XORG_DISK := $(XORG_DESKTOP_BUILD)/acpi-xorg.img
XORG_APPS := $(XORG_BUILD)/xorg-probe $(XORG_BUILD)/Xvfb \
	$(XORG_DESKTOP_ASSETS)/dwm $(XORG_DESKTOP_ASSETS)/xeyes $(XORG_BUILD)/xsetroot $(XORG_BUILD)/xwallpaper $(XORG_BUILD)/date $(XORG_BUILD)/sleep $(ST_BUILD)/st \
	$(XORG_BUILD)/nsxiv $(XORG_BUILD)/nano $(XORG_BUILD)/vim \
	$(BASH_BUILD)/bash.elf $(BASH_BUILD)/fastfetch
XORG_DATA := $(XORG_BUILD)/xorg-default.xkm config/dwm-fonts.conf $(wildcard initramfs/*)
XORG_WALLPAPER := astra_and_fable_kissing.png
XORG_WALLPAPER_FILE := usr/share/wallpapers/astra_and_fable_kissing.png=$(XORG_WALLPAPER)

$(eval $(call jinx_artifact,$(XORG_BUILD)/nsxiv,nsxiv,usr/bin/nsxiv))
$(eval $(call jinx_artifact,$(XORG_BUILD)/nano,nano,usr/bin/nano))
$(eval $(call jinx_artifact,$(XORG_BUILD)/vim,vim,usr/bin/vim))
$(eval $(call jinx_artifact,$(XORG_BUILD)/xsetroot,xsetroot,usr/bin/xsetroot))
$(eval $(call jinx_artifact,$(XORG_BUILD)/xwallpaper,xwallpaper,usr/bin/xwallpaper))
$(eval $(call jinx_artifact,$(XORG_BUILD)/date,date,usr/bin/date))
$(eval $(call jinx_artifact,$(XORG_BUILD)/sleep,sleep,usr/bin/sleep))
XORG_TERMINFO := $(XORG_BUILD)/terminfo/s/st-256color
$(eval $(call jinx_artifact,$(XORG_TERMINFO),ncurses,usr/share/terminfo/s/st-256color))
XORG_FONT := $(XORG_DESKTOP_ASSETS)/dwm-font.ttf
XORG_DISK_CONFIG := config/limine-xorg-disk.conf
XORG_ACCEL ?= $(if $(wildcard /dev/kvm),kvm,tcg)
XORG_CPU ?= $(if $(filter kvm,$(XORG_ACCEL)),$(or $(QEMU_CPU),host),max)

ifneq ($(DWM),1)
ifeq ($(XORG_DESKTOP_ASSETS),$(DWM_BUILD))
$(DWM_BUILD)/dwm-font.ttf: $(DWM_FONT)
	@test -n "$(DWM_FONT)" || { echo "Set DWM_FONT to a TrueType font."; exit 1; }
	mkdir -p "$(@D)"
	cp -- "$(DWM_FONT)" "$@"
endif
endif

ifneq ($(BUILD),$(XORG_DESKTOP_BUILD))
$(XORG_DESKTOP_BUILD)/kernel.elf: kernel-build-force
	$(MAKE) BUILD="$(XORG_DESKTOP_BUILD)" INITRAMFS_FSTAB=config/fstab-xorg "$@"

endif

$(XORG_DISK): scripts/pack-xorg-disk.sh $(XORG_DESKTOP_BUILD)/kernel.elf $(LIMINE_DIR)/BOOTX64.EFI \
	$(XORG_DISK_CONFIG) $(XORG_APPS) $(XORG_DATA) $(XORG_WALLPAPER) $(XORG_TERMINFO) $(XORG_FS_TOOLS) $(XORG_LS) $(XORG_FONT) catflare.gif Makefile
	sh $< "$@" "$(XORG_DESKTOP_BUILD)/kernel.elf" "$(LIMINE_DIR)/BOOTX64.EFI" \
		"$(XORG_DISK_CONFIG)" $(call guest_bins,$(XORG_APPS)) $(XORG_DATA) $(XORG_WALLPAPER_FILE) usr/share/terminfo/s/st-256color=$(XORG_TERMINFO) \
		bin/ls=$(XORG_LS) $(foreach cmd,$(XORG_FS_COMMANDS),bin/$(cmd)=$(XORG_FS_TOOLS)) \
		fonts/dwm-font.ttf="$(XORG_FONT)" catflare.gif=catflare.gif

xorg-desktop-image: $(XORG_DISK)

run-xorg-uefi: private SMP_CPUS = 6
run-xorg-uefi: xorg-desktop-image
	flock -n "$(XORG_DISK).lock" $(QEMU) -m 8G -accel $(XORG_ACCEL) -cpu $(XORG_CPU) -smp $(SMP_CPUS) -monitor none -no-reboot \
		-chardev stdio,id=serial,logfile="$(XORG_DESKTOP_BUILD)/serial.log",logappend=off -serial chardev:serial \
		-drive if=pflash,format=raw,readonly=on,file="$(OVMF)" \
		-drive if=none,id=system,format=raw,file="$(XORG_DISK)" \
		-device virtio-blk-pci,drive=system,disable-modern=on,queue-size=16

.PHONY: dwm
dwm: $(DWM_BUILD)/dwm

$(eval $(call jinx_artifact,$(DWM_BUILD)/dwm,dwm,usr/bin/dwm))

.PHONY: xeyes
xeyes: $(DWM_BUILD)/xeyes

$(eval $(call jinx_artifact,$(DWM_BUILD)/xeyes,xeyes,usr/bin/xeyes))

ifeq ($(DWM),1)
$(DWM_BUILD)/dwm-font.ttf: $(DWM_FONT)
	@test -n "$(DWM_FONT)" || { echo "Set DWM_FONT to a TrueType font."; exit 1; }
	mkdir -p "$(DWM_BUILD)"
	cp -- "$(DWM_FONT)" "$@"
endif

$(eval $(call jinx_artifact,$(BASH_BUILD)/bash.elf,bash,usr/bin/bash.elf))

$(eval $(call jinx_artifact,$(BASH_BUILD)/fbtest,fbtest,usr/bin/fbtest))

FASTFETCH_BUILD := $(abspath ../target/acpi-kernel/fastfetch)
$(BASH_BUILD)/fastfetch: $(FASTFETCH_BUILD)/fastfetch.elf
	cp $< $@

FASTFETCH_BOOT = BUILD="$(FASTFETCH_BUILD)" BOOT_ELF="$(FASTFETCH_BUILD)/fastfetch.elf" \
	BOOT_CONFIG=config/limine-fastfetch.conf BOOT_MODULE=fastfetch.elf

.PHONY: fastfetch run-fastfetch
fastfetch: $(FASTFETCH_BUILD)/fastfetch.elf
	$(MAKE) $(FASTFETCH_BOOT) all

run-fastfetch: fastfetch
	$(MAKE) $(FASTFETCH_BOOT) run

$(eval $(call jinx_artifact,$(FASTFETCH_BUILD)/fastfetch.elf,fastfetch,usr/bin/fastfetch.elf))

DOOM_BUILD := $(abspath ../target/acpi-kernel-doom)
DOOM_SHAREWARE_ARCHIVE := $(DOOM_BUILD)/doom-1.8.wad.gz
DOOM_SHAREWARE_WAD := $(DOOM_BUILD)/doom1.wad
DOOM_WAD ?= $(DOOM_SHAREWARE_WAD)
DOOM_DATA := $(DOOM_BUILD)/doom.wad
ifeq ($(DOOM_WAD),$(DOOM_SHAREWARE_WAD))
doom-wad: $(DOOM_SHAREWARE_WAD)
endif
DOOM_BOOT = BUILD="$(DOOM_BUILD)" BOOT_ELF="$(DOOM_BUILD)/doom.elf" \
	BOOT_CONFIG=config/limine-doom.conf BOOT_MODULE=doom.elf INITRAMFS_EXTRA="$(DOOM_DATA)"

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
	@printf 'Downloading the Doom shareware WAD\n'
	curl -fL --progress-bar --retry 2 "https://www.gamers.org/pub/idgames/idstuff/doom/doom-1.8.wad.gz" -o "$@.tmp"
	printf '%s  %s\n' 58cf6a563b631a47561630afa6276d853c27079342f7969ec3006965da8557a1 "$@.tmp" | sha256sum -c -
	mv "$@.tmp" "$@"

$(DOOM_SHAREWARE_WAD): $(DOOM_SHAREWARE_ARCHIVE)
	@printf 'Extracting the Doom shareware WAD\n'
	gzip -dc "$<" > "$@"

$(eval $(call jinx_artifact,$(DOOM_BUILD)/doom.elf,doomgeneric,usr/bin/doom.elf))
