#!/bin/sh
# Build musl's shared libc.so (also the dynamic linker ld-musl-x86_64.so.1)
# from the source tree jinx unpacked, with the same compiler as the guest tests.
# The result is cached at $1 (default ../target/acpi-kernel-jdk-tests/musl-shared).
set -eu
cd "$(dirname "$0")/.."
out="$(realpath -m "${1:-../target/acpi-kernel-jdk-tests/musl-shared}")"
[ -f "$out/lib/libc.so" ] && exit 0
src="$(ls -d ../target/acpi-os-jinx/*/source/sources/musl-clean 2>/dev/null | head -n 1)"
[ -n "$src" ] || { echo "musl source not found; build the musl recipe first" >&2; exit 1; }
work="$out.build"
rm -rf "$work"
cp -a "$src" "$work"
cd "$work"
CC="clang --target=x86_64-linux-musl -fuse-ld=lld" LIBCC="$(gcc -print-libgcc-file-name)" \
    ./configure --prefix="$out" --syslibdir="$out/lib" --enable-shared --disable-static \
    >configure.log 2>&1 || { cat configure.log; exit 1; }
make -j"$(nproc)" >build.log 2>&1 || { tail -30 build.log; exit 1; }
make install >install.log 2>&1 || { tail -30 install.log; exit 1; }
