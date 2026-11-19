#!/bin/sh
set -eu

build=$1
sysroot=$2
uapi=$3
clang=$4
lld=$5
source=$build/upstream
revision=e257a09527062bfb986b6e5e0780839b6cbd5b71
platform=$(pwd)/doomgeneric-asl.c

mkdir -p "$build"
if [ ! -d "$source/.git" ]; then
    git init -q "$source"
fi
if ! git -C "$source" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$source" fetch https://github.com/ozkl/doomgeneric.git refs/heads/master
fi
git -C "$source" checkout -q --detach "$revision"

resource=$("$clang" -print-resource-dir)
cd "$source/doomgeneric"
# Use the pinned upstream build's engine list and replace its X11 backend.
objects=$(make --no-print-directory -s print OBJDIR=.)
set --
for object in $objects; do
    case "$object" in
        ./doomgeneric_xlib.o|OBJS:) ;;
        *) set -- "$@" "${object%.o}.c" ;;
    esac
done

"$clang" -O2 -march=x86-64 -fno-pie -fno-strict-aliasing -fwrapv \
    -DNORMALUNIX -DLINUX -D_DEFAULT_SOURCE -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 \
    -Wno-incompatible-pointer-types -Wno-int-conversion \
    -nostdinc -isystem "$sysroot/include" -isystem "$resource/include" \
    -idirafter "$uapi" -I . --ld-path="$lld" -nostdlib -static \
    -Wl,--wrap=fopen,--wrap=rename,--wrap=remove,-z,separate-loadable-segments "$sysroot/lib/crt1.o" "$@" "$platform" \
    "$sysroot/lib/libm.a" "$sysroot/lib/libc.a" -o "$build/doom.elf"
