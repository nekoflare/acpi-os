#!/bin/sh
# Build a static Fastfetch against the ACPI kernel's mlibc sysroot.
set -eu

build=$1
sysroot=$2
cc=$(command -v "$3")
ld=$(command -v "$4")
uapi=${5:-"$(dirname "$sysroot")/linux-uapi"}
uapi=$(cd "$uapi" && pwd)
jobs=$6
version=2.71.0
revision=8c9d9c0449dd515e0088c4a60a38d2dc40c5ccd0

mkdir -p "$build"
if [ ! -d "$build/source/.git" ]; then
    git clone --depth 1 --branch "$version" https://github.com/fastfetch-cli/fastfetch.git "$build/source"
fi
test "$(git -C "$build/source" rev-parse HEAD)" = "$revision"
patch_dir=$(dirname "$(realpath "$0")")
for patch in "$patch_dir/fastfetch-mlibc.patch" "$patch_dir/fastfetch-cpu.patch"; do
    if ! git -C "$build/source" apply --reverse --check "$patch" 2>/dev/null; then
        git -C "$build/source" apply "$patch"
    fi
done

cat > "$build/toolchain.cmake" <<TOOLCHAIN
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER "$cc")
set(CMAKE_SYSROOT "$sysroot")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_C_FLAGS_INIT "-DFF_ACPI_MLIBC -march=x86-64 -fno-pie -idirafter \"$uapi\"")
set(CMAKE_EXE_LINKER_FLAGS_INIT "--ld-path=\"$ld\" -static -nostdlib -no-pie -Wl,-z,separate-loadable-segments \"$sysroot/usr/lib/crt1.o\"")
set(CMAKE_C_STANDARD_LIBRARIES_INIT "-lc")
TOOLCHAIN

# Disable optional dependencies and features that require a fuller Linux userspace.
set --
for feature in VULKAN WAYLAND XCB_RANDR XRANDR DRM VADRM VAX11 VDPAU GIO DCONF EET DBUS SQLITE3 RPM EGL GLX OPENCL ELF THREADS IMAGE_LOGO ZLIB LTO WORDEXP LUA LIBZFS; do
    set -- "$@" "-DENABLE_$feature=OFF"
done

cmake -S "$build/source" -B "$build/obj" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$build/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON -DBUILD_FLASHFETCH=OFF -DSET_TWEAK=OFF \
    -DMODULE_DISABLE_LOCALIP=ON -DDEFAULT_STRUCTURE=Title:Version:Kernel:CPU:Memory "$@"
cmake --build "$build/obj" --target fastfetch --parallel "$jobs"
cp "$build/obj/fastfetch" "$build/fastfetch.elf"
