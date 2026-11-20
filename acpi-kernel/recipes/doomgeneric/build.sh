#!/bin/sh
set -eu

app_cpu_flags=${APP_CPU_FLAGS:--march=native -mno-amx-tile}

build=$1
source=$2
sysroot=$3
uapi=$4
clang=$5
lld=$6
platform=$(dirname "$(realpath "$0")")/../../userspace/doomgeneric-asl.c

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

printf 'Compiling and linking DoomGeneric\n'
"$clang" -v -O2 $app_cpu_flags -fno-pie -fno-strict-aliasing -fwrapv \
    -DNORMALUNIX -DLINUX -D_DEFAULT_SOURCE -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 \
    -Wno-incompatible-pointer-types -Wno-int-conversion \
    -nostdinc -isystem "$sysroot/include" -isystem "$resource/include" \
    -idirafter "$uapi" -I . --ld-path="$lld" -nostdlib -static \
    -Wl,--wrap=fopen,--wrap=rename,--wrap=remove,-z,separate-loadable-segments "$sysroot/lib/crt1.o" "$@" "$platform" \
    "$sysroot/lib/libm.a" "$sysroot/lib/libc.a" -o "$build/doom.elf"
