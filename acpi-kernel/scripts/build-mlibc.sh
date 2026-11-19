#!/bin/sh
# Stage a pinned static mlibc built with its x86-64 Linux syscall backend.
set -eu

build=$1
meson=$2
clang=$3
clangxx=$4
uapi=$5
jobs=$6
revision=2444b0997c91c327b9989f25e4b8bd2c053d3194

mkdir -p "$build"
if [ -z "$uapi" ]; then
    uapi="$build/linux-uapi"
    mkdir -p "$uapi"
    for directory in linux asm-generic asm; do
        source="/usr/include/$directory"
        if [ "$directory" = asm ] && [ ! -d "$source" ]; then
            source=/usr/include/x86_64-linux-gnu/asm
        fi
        if [ ! -d "$source" ]; then
            echo "Set MLIBC_UAPI to a directory containing Linux x86-64 UAPI headers." >&2
            exit 1
        fi
        ln -sfn "$source" "$uapi/$directory"
    done
fi
uapi=$(cd "$uapi" && pwd)

src="$build/mlibc"
if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" remote add origin https://github.com/managarm/mlibc.git
fi
if ! git -C "$src" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$src" fetch -q --depth 1 origin "$revision"
fi
git -C "$src" checkout -q --detach "$revision"

CC="$clang" CXX="$clangxx" "$meson" setup --reconfigure "$build/mlibc-build" "$src" \
    --prefix=/usr --libdir=lib -Ddefault_library=static -Dlinux_kernel_headers="$uapi" \
    -Dc_args=-march=x86-64 -Dcpp_args=-march=x86-64
"$meson" compile -C "$build/mlibc-build" -j "$jobs"
DESTDIR="$build/sysroot" "$meson" install -C "$build/mlibc-build" --no-rebuild
