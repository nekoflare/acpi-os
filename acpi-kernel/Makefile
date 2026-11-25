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

.PHONY: xorg-server xorg-image xorg-desktop-image run-xorg-uefi st busybox
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
XORG_APPS := $(XORG_BUILD)/busybox $(XORG_BUILD)/xorg-probe $(XORG_BUILD)/Xvfb \
	$(XORG_DESKTOP_ASSETS)/dwm $(XORG_DESKTOP_ASSETS)/xeyes $(XORG_BUILD)/picom $(XORG_BUILD)/xsetroot $(XORG_BUILD)/xwallpaper $(XORG_BUILD)/xdpyinfo $(XORG_BUILD)/x11perf $(XORG_BUILD)/xcalc $(XORG_BUILD)/grep $(XORG_BUILD)/sed $(XORG_BUILD)/awk $(XORG_BUILD)/tail $(XORG_BUILD)/head $(XORG_BUILD)/find $(XORG_BUILD)/xargs $(XORG_BUILD)/sort $(XORG_BUILD)/uniq $(XORG_BUILD)/cut $(XORG_BUILD)/tr $(XORG_BUILD)/wc $(XORG_BUILD)/tee $(XORG_BUILD)/diff $(XORG_BUILD)/patch $(XORG_BUILD)/file $(XORG_BUILD)/strings $(XORG_BUILD)/stat $(XORG_BUILD)/readlink $(XORG_BUILD)/realpath $(XORG_BUILD)/lspci $(XORG_BUILD)/lscpu $(XORG_BUILD)/clear $(XORG_BUILD)/tar $(XORG_BUILD)/gzip $(XORG_BUILD)/xz $(XORG_BUILD)/lua $(XORG_BUILD)/sqlite3 $(XORG_BUILD)/cmatrix $(XORG_BUILD)/nyancat $(XORG_BUILD)/python3.15 $(XORG_BUILD)/python3 $(XORG_BUILD)/python $(XORG_BUILD)/date $(XORG_BUILD)/sleep $(XORG_BUILD)/conky $(XORG_BUILD)/btop $(XORG_BUILD)/git $(XORG_BUILD)/less $(XORG_BUILD)/make $(XORG_BUILD)/nproc $(XORG_BUILD)/sh $(ST_BUILD)/st \
	$(XORG_BUILD)/nsxiv $(XORG_BUILD)/nano $(XORG_BUILD)/vim $(XORG_BUILD)/lite-xl $(XORG_BUILD)/iasl $(XORG_BUILD)/acpixtract $(XORG_BUILD)/aac $(XORG_BUILD)/clang $(XORG_BUILD)/ld.lld $(XORG_BUILD)/llvm-link $(XORG_BUILD)/opt $(XORG_BUILD)/uacpi-test-runner $(XORG_BUILD)/uacpi-barebones-test-runner \
	$(BASH_BUILD)/fastfetch $(XORG_BUILD)/glxgears $(XORG_BUILD)/glxinfo
XORG_BASH := bin/bash=$(BASH_BUILD)/bash.elf
XORG_DATA := $(XORG_BUILD)/xorg-default.xkm config/dwm-fonts.conf config/conky.conf $(wildcard initramfs/*)
XORG_PICOM_CONFIG := usr/share/picom/picom.conf=config/picom.conf
XORG_CONKY_CONFIG := usr/share/conky/conky.conf=config/conky.conf
XORG_LUA_TEST := usr/share/lua/test.lua=config/lua-test.lua
XORG_IASL_EXAMPLE := usr/share/iasl/examples/acpi-example.asl=config/acpi-example.asl
XORG_UACPI_TESTS := usr/share/uacpi/tests=$(XORG_BUILD)/uacpi-tests
XORG_PYTHON_LIB := usr/lib/python3.15=$(XORG_BUILD)/python-lib
XORG_PYTHON_TEST := usr/share/python/test.py=config/python-test.py
XORG_PYTHON_MARKER := usr/lib/python3.15/lib-dynload/.static-modules=config/python-static-modules.txt
XORG_DEJAVU_FONTS := DejaVuSans.ttf DejaVuSansMono.ttf DejaVuSansMono-Bold.ttf \
    DejaVuSansMono-Oblique.ttf DejaVuSansMono-BoldOblique.ttf \
    DejaVuSans-Bold.ttf DejaVuSans-Oblique.ttf DejaVuSans-BoldOblique.ttf \
    DejaVuSerif.ttf DejaVuSerif-Bold.ttf
XORG_FONT_FILES := $(foreach font,$(XORG_DEJAVU_FONTS),fonts/$(font)=$(XORG_BUILD)/$(font))
XORG_FILE_MAGIC := usr/share/misc/magic.mgc=$(XORG_BUILD)/magic.mgc
XORG_XCALC_APPDEFAULTS := usr/share/X11/app-defaults/XCalc=$(XORG_BUILD)/XCalc.ad
# clang finds its resource headers relative to /bin/clang.
XORG_CLANG_FILES := lib/clang/23=$(XORG_BUILD)/clang-resource usr/include=$(XORG_BUILD)/libc-include \
	usr/lib/musl=$(XORG_BUILD)/musl-runtime bin/clang.cfg=config/clang.cfg \
	home/serval/pthread-test.c=config/pthread-test.c
XORG_PCI_IDS := usr/share/hwdata/pci.ids=$(XORG_BUILD)/pci.ids
# Shared musl: libc.so is also the dynamic linker that PT_INTERP names.
XORG_MUSL_SHARED := $(XORG_BUILD)/musl-shared/lib/libc.so
XORG_DYNAMIC_FILES := lib/ld-musl-x86_64.so.1=$(XORG_MUSL_SHARED) bin/hello-dynamic=$(XORG_BUILD)/hello-dynamic
XORG_LITE_XL_DATA := usr/share/lite-xl=$(XORG_BUILD)/lite-xl-data
# OpenJDK 21 (Server VM, plus Zero as `java -zero`). The desktop PATH is
# /bin, so the tools are linked there. libasound is only for javax.sound.
XORG_JDK_HOME := usr/lib/jvm/java-21-openjdk
XORG_JDK_TOOLS := java javac jar jshell jlink keytool
XORG_JDK_FILES := $(XORG_JDK_HOME)=$(XORG_BUILD)/openjdk usr/lib/libasound.so.2=$(XORG_BUILD)/libasound.so.2 \
	$(foreach tool,$(XORG_JDK_TOOLS),'bin/$(tool)->/$(XORG_JDK_HOME)/bin/$(tool)')
# OpenGL for X clients (F1): Mesa's libGL with llvmpipe does GLX itself over
# Xlib, so Xvfb needs no GLX extension. GLFW (LWJGL) dlopens libX11,
# libXrandr, libXcursor (for its hidden cursor) and libXi (raw mouse motion), so these are the shared
# builds; libGL needs the C++ runtime and LWJGL's libopenal also libatomic.
XORG_GL_LIBS := mesa:libGL.so.1 libx11-shared:libX11.so.6 libxcb-shared:libxcb.so.1 libxcb-shared:libxcb-shm.so.0 \
	libxau-shared:libXau.so.6 libxdmcp-shared:libXdmcp.so.6 libxext-shared:libXext.so.6 \
	libxrender-shared:libXrender.so.1 libxrandr:libXrandr.so.2 \
	libxfixes-shared:libXfixes.so.3 libxcursor-shared:libXcursor.so.1 \
	libxi-shared:libXi.so.6
XORG_CXX_RUNTIME := libstdc++.so.6 libgcc_s.so.1 libatomic.so.1
XORG_GL_FILES := $(foreach lib,$(XORG_GL_LIBS),usr/lib/$(lastword $(subst :, ,$(lib)))=$(XORG_BUILD)/gl/$(lastword $(subst :, ,$(lib)))) \
	$(foreach lib,$(XORG_CXX_RUNTIME),usr/lib/$(lib)=$(XORG_BUILD)/gl/$(lib))
XORG_GL_DEPS := $(foreach lib,$(XORG_GL_LIBS),$(XORG_BUILD)/gl/$(lastword $(subst :, ,$(lib)))) \
	$(addprefix $(XORG_BUILD)/gl/,$(XORG_CXX_RUNTIME))
# LWJGL 3.3.3 for Minecraft 1.21.11 (F3): the natives from the lwjgl* recipes
# in /usr/lib/lwjgl, Mojang's Java jars in /opt/lwjgl (scripts/fetch-lwjgl.sh)
# and the `lwjgl-demo` launcher.
XORG_LWJGL_LIBS := lwjgl:liblwjgl.so lwjgl:liblwjgl_opengl.so lwjgl:liblwjgl_stb.so \
	lwjgl:liblwjgl_tinyfd.so lwjgl-glfw:libglfw.so lwjgl-openal:libopenal.so \
	lwjgl-jemalloc:libjemalloc.so lwjgl-freetype:libfreetype.so
XORG_LWJGL_JARS := $(abspath ../target/lwjgl-3.3.3)
XORG_LWJGL_DEPS := $(foreach lib,$(XORG_LWJGL_LIBS),$(XORG_BUILD)/lwjgl/$(lastword $(subst :, ,$(lib)))) \
	$(XORG_LWJGL_JARS)/.fetched userspace/jdk-tests/java/LwjglDemo.java config/lwjgl-demo
XORG_LWJGL_FILES := $(foreach lib,$(XORG_LWJGL_LIBS),usr/lib/lwjgl/$(lastword $(subst :, ,$(lib)))=$(XORG_BUILD)/lwjgl/$(lastword $(subst :, ,$(lib)))) \
	opt/lwjgl=$(XORG_LWJGL_JARS) usr/share/lwjgl-demo/LwjglDemo.java=userspace/jdk-tests/java/LwjglDemo.java \
	bin/lwjgl-demo=config/lwjgl-demo
# Minecraft 1.21.11 (F4) in /opt/minecraft (scripts/fetch-minecraft.sh): the
# client, its libraries and the asset objects, started by `minecraft`;
# `minecraft-login` fetches an account token from scripts/minecraft-token.sh.
XORG_MINECRAFT := $(abspath ../target/minecraft-1.21.11)
XORG_MINECRAFT_DEPS := $(XORG_MINECRAFT)/.fetched config/minecraft config/minecraft-login
XORG_MINECRAFT_FILES := opt/minecraft/client.jar=$(XORG_MINECRAFT)/client.jar \
	opt/minecraft/libraries=$(XORG_MINECRAFT)/libraries opt/minecraft/assets=$(XORG_MINECRAFT)/assets \
	bin/minecraft=config/minecraft bin/minecraft-login=config/minecraft-login
# TLS (NETPLAN C1, C2): shared OpenSSL, zlib and libcurl, openssl, curl and Mozilla's
# CA bundle in /etc/ssl, which the kernel merges with the bootstrap /etc.
XORG_TLS_LIBS := openssl:libssl.so.3 openssl:libcrypto.so.3 zlib-shared:libz.so.1 curl:libcurl.so.4
XORG_TLS_DEPS := $(foreach lib,$(XORG_TLS_LIBS),$(XORG_BUILD)/tls/$(lastword $(subst :, ,$(lib)))) \
	$(XORG_BUILD)/tls/openssl $(XORG_BUILD)/tls/ossl-modules $(XORG_BUILD)/tls/openssl.cnf \
	$(XORG_BUILD)/tls/ca-certificates.crt \
	$(XORG_BUILD)/tls/curl
XORG_TLS_FILES := $(foreach lib,$(XORG_TLS_LIBS),usr/lib/$(lastword $(subst :, ,$(lib)))=$(XORG_BUILD)/tls/$(lastword $(subst :, ,$(lib)))) \
	bin/openssl=$(XORG_BUILD)/tls/openssl bin/curl=$(XORG_BUILD)/tls/curl usr/lib/ossl-modules=$(XORG_BUILD)/tls/ossl-modules \
	etc/ssl/openssl.cnf=$(XORG_BUILD)/tls/openssl.cnf \
	etc/ssl/certs/ca-certificates.crt=$(XORG_BUILD)/tls/ca-certificates.crt \
	'etc/ssl/cert.pem->certs/ca-certificates.crt'
# Firefox probe (FIREFOX_PORT.md P3): Alpine's prebuilt firefox-esr and its
# dependencies in /opt/alpine (scripts/fetch-alpine-firefox.py), started by
# `firefox-probe`. Replaced by the source build in phase F.
XORG_ALPINE := $(abspath ../target/alpine-firefox)
XORG_ALPINE_DEPS := $(XORG_ALPINE)/.fetched config/firefox-probe config/firefox-fonts.conf config/firefox-prefs.js config/ld-musl-x86_64.path
XORG_ALPINE_FILES := opt/alpine=$(XORG_ALPINE)/root bin/firefox-probe=config/firefox-probe \
	etc/fonts/firefox.conf=config/firefox-fonts.conf \
	opt/alpine/usr/lib/firefox-esr/browser/defaults/preferences/acpi-os.js=config/firefox-prefs.js \
	etc/ld-musl-x86_64.path=config/ld-musl-x86_64.path
# Web browser: NetSurf's framebuffer frontend in an X11 window (recipes/netsurf).
XORG_NETSURF_DEPS := $(XORG_BUILD)/netsurf $(XORG_BUILD)/netsurf-res
XORG_NETSURF_FILES := bin/netsurf=$(XORG_BUILD)/netsurf usr/share/netsurf=$(XORG_BUILD)/netsurf-res
XORG_WALLPAPER := serval_wp.jpg
XORG_WALLPAPER_CREDIT := serval_wp.jpg.txt
XORG_WALLPAPER_FILES := $(addprefix usr/share/wallpapers/,$(foreach file,$(XORG_WALLPAPER) $(XORG_WALLPAPER_CREDIT),$(file)=$(file)))

$(eval $(call jinx_artifact,$(XORG_BUILD)/busybox,busybox,usr/bin/busybox))
$(foreach lib,$(XORG_TLS_LIBS),$(eval $(call jinx_artifact,$(XORG_BUILD)/tls/$(lastword $(subst :, ,$(lib))),$(firstword $(subst :, ,$(lib))),usr/lib/$(lastword $(subst :, ,$(lib))))))
$(eval $(call jinx_artifact,$(XORG_BUILD)/tls/openssl,openssl,usr/bin/openssl))
$(eval $(call jinx_artifact,$(XORG_BUILD)/tls/curl,curl,usr/bin/curl))
$(eval $(call jinx_artifact,$(XORG_BUILD)/tls/ossl-modules,openssl,usr/lib/ossl-modules))
$(eval $(call jinx_artifact,$(XORG_BUILD)/tls/openssl.cnf,openssl,etc/ssl/openssl.cnf))
$(eval $(call jinx_artifact,$(XORG_BUILD)/tls/ca-certificates.crt,ca-certificates,etc/ssl/certs/ca-certificates.crt))

busybox: $(XORG_BUILD)/busybox

$(eval $(call jinx_artifact,$(XORG_BUILD)/nsxiv,nsxiv,usr/bin/nsxiv))
$(eval $(call jinx_artifact,$(XORG_BUILD)/netsurf,netsurf,usr/bin/netsurf-fb))
$(eval $(call jinx_artifact,$(XORG_BUILD)/netsurf-res,netsurf,usr/share/netsurf))
$(eval $(call jinx_artifact,$(XORG_BUILD)/nano,nano,usr/bin/nano))
$(eval $(call jinx_artifact,$(XORG_BUILD)/vim,vim,usr/bin/vim))
$(eval $(call jinx_artifact,$(XORG_BUILD)/lite-xl,lite-xl,usr/bin/lite-xl))
$(eval $(call jinx_artifact,$(XORG_BUILD)/lite-xl-data,lite-xl,usr/share/lite-xl))
$(eval $(call jinx_artifact,$(XORG_BUILD)/openjdk,openjdk,usr/lib/jvm/java-21-openjdk))
$(eval $(call jinx_artifact,$(XORG_BUILD)/libasound.so.2,alsa-lib,usr/lib/libasound.so.2))
$(foreach lib,$(XORG_GL_LIBS),$(eval $(call jinx_artifact,$(XORG_BUILD)/gl/$(lastword $(subst :, ,$(lib))),$(firstword $(subst :, ,$(lib))),usr/lib/$(lastword $(subst :, ,$(lib))))))
$(foreach lib,$(XORG_CXX_RUNTIME),$(eval $(call jinx_artifact,$(XORG_BUILD)/gl/$(lib),musl-runtime,lib/$(lib))))
$(eval $(call jinx_artifact,$(XORG_BUILD)/glxgears,mesa-demos,usr/bin/glxgears))
$(eval $(call jinx_artifact,$(XORG_BUILD)/glxinfo,mesa-demos,usr/bin/glxinfo))
$(foreach lib,$(XORG_LWJGL_LIBS),$(eval $(call jinx_artifact,$(XORG_BUILD)/lwjgl/$(lastword $(subst :, ,$(lib))),$(firstword $(subst :, ,$(lib))),usr/lib/lwjgl/$(lastword $(subst :, ,$(lib))))))

$(XORG_LWJGL_JARS)/.fetched: scripts/fetch-lwjgl.sh
	scripts/fetch-lwjgl.sh $(XORG_LWJGL_JARS)
	touch $@

$(XORG_MINECRAFT)/.fetched: scripts/fetch-minecraft.sh
	scripts/fetch-minecraft.sh $(XORG_MINECRAFT)
	touch $@

$(XORG_ALPINE)/.fetched: scripts/fetch-alpine-firefox.py
	python3 -I scripts/fetch-alpine-firefox.py
	touch $@
$(eval $(call jinx_artifact,$(XORG_BUILD)/xsetroot,xsetroot,usr/bin/xsetroot))
$(eval $(call jinx_artifact,$(XORG_BUILD)/xwallpaper,xwallpaper,usr/bin/xwallpaper))
$(eval $(call jinx_artifact,$(XORG_BUILD)/xdpyinfo,xdpyinfo,usr/bin/xdpyinfo))
$(eval $(call jinx_artifact,$(XORG_BUILD)/x11perf,x11perf,usr/bin/x11perf))
$(eval $(call jinx_artifact,$(XORG_BUILD)/xcalc,xcalc,usr/bin/xcalc))
$(eval $(call jinx_artifact,$(XORG_BUILD)/XCalc.ad,xcalc,usr/share/X11/app-defaults/XCalc))
$(eval $(call jinx_artifact,$(XORG_BUILD)/grep,grep,usr/bin/grep))
$(eval $(call jinx_artifact,$(XORG_BUILD)/sed,sed,usr/bin/sed))
$(eval $(call jinx_artifact,$(XORG_BUILD)/awk,awk,usr/bin/awk))
$(eval $(call jinx_artifact,$(XORG_BUILD)/tail,tail,usr/bin/tail))
$(eval $(call jinx_artifact,$(XORG_BUILD)/head,head,usr/bin/head))
$(eval $(call jinx_artifact,$(XORG_BUILD)/find,find,usr/bin/find))
$(eval $(call jinx_artifact,$(XORG_BUILD)/xargs,xargs,usr/bin/xargs))
$(eval $(call jinx_artifact,$(XORG_BUILD)/sort,sort,usr/bin/sort))
$(eval $(call jinx_artifact,$(XORG_BUILD)/uniq,uniq,usr/bin/uniq))
$(eval $(call jinx_artifact,$(XORG_BUILD)/cut,cut,usr/bin/cut))
$(eval $(call jinx_artifact,$(XORG_BUILD)/tr,tr,usr/bin/tr))
$(eval $(call jinx_artifact,$(XORG_BUILD)/wc,wc,usr/bin/wc))
$(eval $(call jinx_artifact,$(XORG_BUILD)/tee,tee,usr/bin/tee))
$(eval $(call jinx_artifact,$(XORG_BUILD)/diff,diff,usr/bin/diff))
$(eval $(call jinx_artifact,$(XORG_BUILD)/patch,patch,usr/bin/patch))
$(eval $(call jinx_artifact,$(XORG_BUILD)/file,file,usr/bin/file))
$(eval $(call jinx_artifact,$(XORG_BUILD)/magic.mgc,file,usr/share/misc/magic.mgc))
$(eval $(call jinx_artifact,$(XORG_BUILD)/strings,strings,usr/bin/strings))
$(eval $(call jinx_artifact,$(XORG_BUILD)/stat,stat,usr/bin/stat))
$(eval $(call jinx_artifact,$(XORG_BUILD)/readlink,readlink,usr/bin/readlink))
$(eval $(call jinx_artifact,$(XORG_BUILD)/realpath,realpath,usr/bin/realpath))
$(eval $(call jinx_artifact,$(XORG_BUILD)/lspci,pciutils,usr/bin/lspci))
$(eval $(call jinx_artifact,$(XORG_BUILD)/lscpu,lscpu,usr/bin/lscpu))
$(eval $(call jinx_artifact,$(XORG_BUILD)/clear,clear,usr/bin/clear))
$(eval $(call jinx_artifact,$(XORG_BUILD)/tar,tar,usr/bin/tar))
$(eval $(call jinx_artifact,$(XORG_BUILD)/gzip,gzip,usr/bin/gzip))
$(eval $(call jinx_artifact,$(XORG_BUILD)/xz,xz,usr/bin/xz))
$(eval $(call jinx_artifact,$(XORG_BUILD)/lua,lua,usr/bin/lua))
$(eval $(call jinx_artifact,$(XORG_BUILD)/sqlite3,sqlite3,usr/bin/sqlite3))
$(eval $(call jinx_artifact,$(XORG_BUILD)/cmatrix,cmatrix,usr/bin/cmatrix))
$(eval $(call jinx_artifact,$(XORG_BUILD)/nyancat,nyancat,usr/bin/nyancat))
$(eval $(call jinx_artifact,$(XORG_BUILD)/python3.15,python,usr/bin/python3.15))
$(eval $(call jinx_artifact,$(XORG_BUILD)/python3,python,usr/bin/python3))
$(eval $(call jinx_artifact,$(XORG_BUILD)/python-lib,python,usr/lib/python3.15))
$(eval $(call jinx_artifact,$(XORG_BUILD)/python,python,usr/bin/python))
$(eval $(call jinx_artifact,$(XORG_BUILD)/pci.ids,pciutils,usr/share/hwdata/pci.ids))
$(eval $(call jinx_artifact,$(XORG_BUILD)/date,date,usr/bin/date))
$(eval $(call jinx_artifact,$(XORG_BUILD)/sleep,sleep,usr/bin/sleep))
$(eval $(call jinx_artifact,$(XORG_BUILD)/picom,picom,usr/bin/picom))
$(eval $(call jinx_artifact,$(XORG_BUILD)/conky,conky,usr/bin/conky))
$(eval $(call jinx_artifact,$(XORG_BUILD)/btop,btop,usr/bin/btop))
$(eval $(call jinx_artifact,$(XORG_BUILD)/git,git,usr/bin/git))
$(eval $(call jinx_artifact,$(XORG_BUILD)/less,less,usr/bin/less))
$(eval $(call jinx_artifact,$(XORG_BUILD)/make,make,usr/bin/make))
$(eval $(call jinx_artifact,$(XORG_BUILD)/nproc,nproc,usr/bin/nproc))
$(eval $(call jinx_artifact,$(XORG_BUILD)/iasl,iasl,usr/bin/iasl))
$(eval $(call jinx_artifact,$(XORG_BUILD)/acpixtract,iasl,usr/bin/acpixtract))
$(eval $(call jinx_artifact,$(XORG_BUILD)/aac,aac,usr/bin/aac))
$(eval $(call jinx_artifact,$(XORG_BUILD)/clang,clang,usr/bin/clang))
$(eval $(call jinx_artifact,$(XORG_BUILD)/ld.lld,clang,usr/bin/ld.lld))
$(eval $(call jinx_artifact,$(XORG_BUILD)/llvm-link,clang,usr/bin/llvm-link))
$(eval $(call jinx_artifact,$(XORG_BUILD)/opt,clang,usr/bin/opt))
$(eval $(call jinx_artifact,$(XORG_BUILD)/clang-resource,clang,usr/lib/clang/23))
$(eval $(call jinx_artifact,$(XORG_BUILD)/libc-include,clang,usr/include))
$(eval $(call jinx_artifact,$(XORG_BUILD)/musl-runtime,clang,usr/lib/musl))
$(eval $(call jinx_artifact,$(XORG_BUILD)/uacpi-test-runner,uacpi-test-runner,usr/bin/uacpi-test-runner))
$(eval $(call jinx_artifact,$(XORG_BUILD)/uacpi-barebones-test-runner,uacpi-test-runner,usr/bin/uacpi-barebones-test-runner))
$(eval $(call jinx_artifact,$(XORG_BUILD)/uacpi-tests,uacpi-test-suite,usr/share/uacpi/tests))
$(eval $(call jinx_artifact,$(XORG_BUILD)/git-upload-pack,git,usr/libexec/git-core/git-upload-pack))
$(eval $(call jinx_artifact,$(XORG_BUILD)/git-template-description,git,usr/share/git-core/templates/description))
$(eval $(call jinx_artifact,$(XORG_BUILD)/sh,bash,usr/bin/bash))
$(foreach font,$(XORG_DEJAVU_FONTS),$(eval $(call jinx_artifact,$(XORG_BUILD)/$(font),dejavu-fonts,usr/share/fonts/truetype/dejavu/$(font))))
XORG_TERMINFO := $(XORG_BUILD)/terminfo/s/st-256color
$(eval $(call jinx_artifact,$(XORG_TERMINFO),ncurses,usr/share/terminfo/s/st-256color))
XORG_FONT := $(XORG_DESKTOP_ASSETS)/dwm-font.ttf
XORG_DISK_CONFIG := config/limine-xorg-disk.conf
XORG_ACCEL ?= $(if $(wildcard /dev/kvm),kvm,tcg)
XORG_CPU ?= $(if $(filter kvm,$(XORG_ACCEL)),$(or $(QEMU_CPU),host),max)
# QEMU window, for example XORG_DISPLAY=sdl: on Wayland, SDL locks the mouse
# while it is captured (click in the window; Ctrl+Alt+G releases it), so the
# guest pointer does not stop where the host pointer meets the screen edge.
# Empty keeps QEMU's default window.
XORG_DISPLAY ?=
# QEMU VGA memory in MiB, for example XORG_VGAMEM=256; empty keeps the default
# 16, which flips 1920x1080 between two pages.
XORG_VGAMEM ?=

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

$(XORG_MUSL_SHARED): scripts/build-musl-shared.sh
	sh $< "$(XORG_BUILD)/musl-shared"

$(XORG_BUILD)/hello-dynamic: userspace/hello-dynamic.c $(XORG_MUSL_SHARED)
	clang --target=x86_64-linux-musl -O2 -fPIE -pie -nostdinc -nostdlib -fuse-ld=lld \
		-isystem "$(XORG_BUILD)/musl-shared/include" -isystem "$$(clang -print-resource-dir)/include" \
		-Wl,-dynamic-linker,/lib/ld-musl-x86_64.so.1 "$(XORG_BUILD)/musl-shared/lib/Scrt1.o" \
		"$(XORG_BUILD)/musl-shared/lib/crti.o" $< -L"$(XORG_BUILD)/musl-shared/lib" -lc \
		"$$(gcc -print-libgcc-file-name)" "$(XORG_BUILD)/musl-shared/lib/crtn.o" -o $@

$(XORG_DISK): scripts/pack-xorg-disk.sh $(XORG_DESKTOP_BUILD)/kernel.elf $(LIMINE_DIR)/BOOTX64.EFI \
	$(XORG_DISK_CONFIG) $(XORG_APPS) $(XORG_BUILD)/uacpi-tests config/uacpi-run-tests config/bashrc $(XORG_BUILD)/python-lib $(XORG_BUILD)/lite-xl-data $(XORG_BUILD)/openjdk $(XORG_BUILD)/libasound.so.2 $(BASH_BUILD)/bash.elf $(XORG_BUILD)/git-upload-pack $(XORG_BUILD)/git-template-description $(XORG_DATA) $(XORG_BUILD)/magic.mgc $(XORG_BUILD)/XCalc.ad $(XORG_BUILD)/clang-resource $(XORG_BUILD)/libc-include $(XORG_BUILD)/musl-runtime config/clang.cfg config/pthread-test.c $(XORG_BUILD)/pci.ids config/picom.conf config/lua-test.lua config/sqlite3-test.sh config/acpi-example.asl config/python-test.py config/python-static-modules.txt $(XORG_WALLPAPER) $(XORG_WALLPAPER_CREDIT) $(XORG_TERMINFO) $(XORG_FS_TOOLS) $(XORG_LS) $(XORG_FONT) $(addprefix $(XORG_BUILD)/,$(XORG_DEJAVU_FONTS)) $(XORG_MUSL_SHARED) $(XORG_BUILD)/hello-dynamic $(XORG_GL_DEPS) $(XORG_LWJGL_DEPS) $(XORG_MINECRAFT_DEPS) $(XORG_TLS_DEPS) $(XORG_NETSURF_DEPS) $(XORG_ALPINE_DEPS) catflare.gif Makefile
	sh $< "$@" "$(XORG_DESKTOP_BUILD)/kernel.elf" "$(LIMINE_DIR)/BOOTX64.EFI" \
		"$(XORG_DISK_CONFIG)" $(call guest_bins,$(XORG_APPS)) $(XORG_BASH) $(XORG_DATA) $(XORG_PICOM_CONFIG) $(XORG_CONKY_CONFIG) .bashrc=config/bashrc $(XORG_LUA_TEST) $(XORG_IASL_EXAMPLE) $(XORG_UACPI_TESTS) bin/uacpi-run-tests=config/uacpi-run-tests bin/sqlite3-test=config/sqlite3-test.sh $(XORG_PYTHON_LIB) $(XORG_PYTHON_TEST) $(XORG_PYTHON_MARKER) $(XORG_FILE_MAGIC) $(XORG_XCALC_APPDEFAULTS) $(XORG_CLANG_FILES) $(XORG_DYNAMIC_FILES) $(XORG_PCI_IDS) $(XORG_LITE_XL_DATA) $(XORG_JDK_FILES) $(XORG_GL_FILES) $(XORG_LWJGL_FILES) $(XORG_MINECRAFT_FILES) $(XORG_TLS_FILES) $(XORG_NETSURF_FILES) $(XORG_ALPINE_FILES) $(XORG_WALLPAPER_FILES) usr/libexec/git-core/git-upload-pack=$(XORG_BUILD)/git-upload-pack usr/share/git-core/templates/description=$(XORG_BUILD)/git-template-description usr/share/terminfo/s/st-256color=$(XORG_TERMINFO) \
		bin/ls=$(XORG_LS) $(foreach cmd,$(XORG_FS_COMMANDS),bin/$(cmd)=$(XORG_FS_TOOLS)) \
		fonts/dwm-font.ttf="$(XORG_FONT)" $(XORG_FONT_FILES) catflare.gif=catflare.gif

xorg-desktop-image: $(XORG_DISK)

# The desktop image writes only the files that changed since the last pack
# (see scripts/disk-manifest.py). This rewrites every file.
.PHONY: xorg-restage
xorg-restage:
	XORG_RESTAGE=1 $(MAKE) -W scripts/pack-xorg-disk.sh $(XORG_DISK)

run-xorg-uefi: private SMP_CPUS = 6
run-xorg-uefi: xorg-desktop-image
	@echo "X.Org VM: accel=$(XORG_ACCEL) cpu=$(XORG_CPU) vcpus=$(SMP_CPUS)"
	@echo "X.Org serial log: $(XORG_DESKTOP_BUILD)/serial.log"
	flock -n "$(XORG_DISK).lock" $(QEMU) -m 8G -accel $(XORG_ACCEL) -cpu $(XORG_CPU) -smp $(SMP_CPUS) -no-reboot \
		-monitor unix:"$(XORG_DESKTOP_BUILD)/monitor.sock",server=on,wait=off \
		$(if $(XORG_DISPLAY),-display $(XORG_DISPLAY)) \
		$(if $(XORG_VGAMEM),-global VGA.vgamem_mb=$(XORG_VGAMEM)) \
		-chardev stdio,id=serial,logfile="$(XORG_DESKTOP_BUILD)/serial.log",logappend=off -serial chardev:serial \
		-drive if=pflash,format=raw,readonly=on,file="$(OVMF)" \
		-drive if=none,id=system,format=raw,file="$(XORG_DISK)" \
		-device virtio-blk-pci,drive=system,disable-modern=on,queue-size=16 \
		-netdev user,id=n0 -device virtio-net-pci,netdev=n0,disable-modern=on,romfile=

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

$(eval $(call jinx_artifact,$(BASH_BUILD)/bash.elf,bash,usr/bin/bash))

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
