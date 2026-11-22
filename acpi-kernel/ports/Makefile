# Jinx caches by package version. Give each set of local inputs its own
# package repository and source tree. Reuse binaries with matching package inputs.
JINX := $(abspath ports/jinx)
# The aac recipe builds the AML AOT compiler from the repository root. Its
# sources go in the recipe directory, which Jinx fingerprints per package.
AMLAOT_INPUTS := ../Cargo.toml ../Cargo.lock $(shell find ../src -type f | LC_ALL=C sort)
JINX_INPUTS := $(shell find recipes userspace -type f | LC_ALL=C sort) \
	Jinxfile ports/jinx ports/Makefile ports/stage.sh config/xorg-default.xkb \
	$(AMLAOT_INPUTS)
JINX_ID := $(shell { printf '%s\n' "$(APP_ARCH)"; sha256sum $(JINX_INPUTS); } | sha256sum | cut -c1-20)
JINX_ROOT := $(abspath ../target/acpi-os-jinx)
JINX_BUILD := $(JINX_ROOT)/$(JINX_ID)/build
JINX_SOURCE := $(JINX_ROOT)/$(JINX_ID)/source
JINX_CONFIG := $(JINX_BUILD)/.jinx-parameters
export ACPI_JINX_PACKAGE_CACHE := $(JINX_ROOT)/packages
export JINX_CACHE_DIR := $(abspath .jinx-cache)
export JINX_PARALLELISM := $(MLIBC_JOBS)

$(JINX_CONFIG): | $(JINX_INPUTS)
	@mkdir -p "$(@D)" "$(JINX_CACHE_DIR)"
	@flock "$(@D)/.init.lock" sh -ec '\
		if test ! -f "$$1/.jinx-parameters"; then \
			mkdir -p "$$2/config"; \
			cp -R Jinxfile recipes userspace "$$2/"; \
			cp config/xorg-default.xkb "$$2/config/"; \
			mkdir -p "$$2/recipes/aac/amlaot"; \
			cp -R ../Cargo.toml ../Cargo.lock ../src "$$2/recipes/aac/amlaot/"; \
			cd "$$1"; "$$3" init "$$2" ARCH=x86_64 APP_ARCH="$$4"; \
		fi' sh "$(@D)" "$(JINX_SOURCE)" "$(JINX)" "$(APP_ARCH)"

.PHONY: userspace jinx-restage
userspace: $(JINX_CONFIG)
	cd "$(JINX_BUILD)" && flock "$(JINX_ROOT)/.lock" "$(JINX)" update -b '*'

define jinx_artifact
ifneq ($(JINX_ID),$(shell head -n 1 "$(1).jinx-id" 2>/dev/null))
$(1): jinx-restage
endif
$(1): | $(JINX_CONFIG)
	flock "$(JINX_ROOT)/.lock" bash ports/stage.sh "$(JINX_BUILD)" "$(2)" "$(3)" "$$@" "$(JINX_ID)"
endef
