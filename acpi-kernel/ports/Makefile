# Jinx caches by package version. Give each set of local inputs its own
# package repository and source tree, while sharing downloads and host tools.
JINX := $(abspath ports/jinx)
JINX_INPUTS := $(shell find recipes userspace -type f | LC_ALL=C sort) \
	Jinxfile ports/jinx ports/Makefile ports/stage.sh config/xorg-default.xkb
JINX_ID := $(shell { printf '%s\n' "$(APP_ARCH)"; sha256sum $(JINX_INPUTS); } | sha256sum | cut -c1-20)
JINX_ROOT := $(abspath ../target/acpi-os-jinx)
JINX_BUILD := $(JINX_ROOT)/$(JINX_ID)/build
JINX_SOURCE := $(JINX_ROOT)/$(JINX_ID)/source
JINX_CONFIG := $(JINX_BUILD)/.jinx-parameters
export JINX_CACHE_DIR := $(abspath .jinx-cache)
export JINX_PARALLELISM := $(MLIBC_JOBS)

$(JINX_CONFIG): | $(JINX_INPUTS)
	@mkdir -p "$(@D)" "$(JINX_CACHE_DIR)"
	@flock "$(@D)/.init.lock" sh -ec '\
		if test ! -f "$$1/.jinx-parameters"; then \
			mkdir -p "$$2/config"; \
			cp -R Jinxfile recipes userspace "$$2/"; \
			cp config/xorg-default.xkb "$$2/config/"; \
			cd "$$1"; "$$3" init "$$2" ARCH=x86_64 APP_ARCH="$$4"; \
		fi' sh "$(@D)" "$(JINX_SOURCE)" "$(JINX)" "$(APP_ARCH)"

.PHONY: userspace jinx-restage
userspace: $(JINX_CONFIG)
	cd "$(JINX_BUILD)" && flock "$(JINX_ROOT)/.lock" "$(JINX)" update -b '*'

define jinx_artifact
ifneq ($(JINX_ID),$(shell cat "$(1).jinx-id" 2>/dev/null))
$(1): jinx-restage
endif
$(1): | $(JINX_CONFIG)
	flock "$(JINX_ROOT)/.lock" bash ports/stage.sh "$(JINX_BUILD)" "$(2)" "$(3)" "$$@" "$(JINX_ID)"
endef
