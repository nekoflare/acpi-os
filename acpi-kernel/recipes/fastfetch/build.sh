#!/bin/sh
# Build a static Fastfetch against the ACPI kernel's mlibc sysroot.
set -eu

app_cpu_flags=${APP_CPU_FLAGS:--march=native -mno-amx-tile}

build=$1
source=$2
sysroot=$3
cc=$(command -v "$4")
ld=$(command -v "$5")
uapi=$6
jobs=$7

cat > "$build/toolchain.cmake" <<TOOLCHAIN
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER "$cc")
set(CMAKE_SYSROOT "$sysroot")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_EXE_LINKER_FLAGS_INIT "--ld-path=\"$ld\" -static -nostdlib -no-pie -Wl,-z,separate-loadable-segments \"$sysroot/usr/lib/crt1.o\"")
set(CMAKE_C_STANDARD_LIBRARIES_INIT "-lc")
TOOLCHAIN

# Disable optional dependencies and features that require a fuller Linux userspace.
set --
for feature in VULKAN WAYLAND XCB_RANDR XRANDR DRM VADRM VAX11 VDPAU GIO DCONF EET DBUS SQLITE3 RPM EGL GLX OPENCL ELF THREADS IMAGE_LOGO ZLIB LTO WORDEXP LUA LIBZFS; do
    set -- "$@" "-DENABLE_$feature=OFF"
done

printf 'Configuring Fastfetch\n'
cmake -S "$source" -B "$build/obj" -G Ninja \
    -DCMAKE_C_FLAGS="-DFF_ACPI_MLIBC $app_cpu_flags -fno-pie -idirafter \"$uapi\"" \
    -DCMAKE_TOOLCHAIN_FILE="$build/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON -DBUILD_FLASHFETCH=OFF -DSET_TWEAK=OFF \
    -DMODULE_DISABLE_LOCALIP=ON -DDEFAULT_STRUCTURE=Title:Version:Kernel:Uptime:Shell:WM:CPU:Memory "$@"
printf 'Compiling Fastfetch\n'
cmake --build "$build/obj" --target fastfetch --parallel "$jobs"
cp "$build/obj/fastfetch" "$build/fastfetch.elf"
