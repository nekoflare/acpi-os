#!/bin/sh
# Build a static GNU Bash with the staged mlibc CRT and headers.
set -eu

if [ "$1" = --cc ]; then
    shift
    for arg in "$@"; do
        case "$arg" in
            -c|-E|-S|-M|-MM|--version|-v|-dumpmachine|-print-*)
                exec "$BASH_CC" --sysroot="$BASH_SYSROOT" -idirafter "$BASH_UAPI" "$@"
                ;;
        esac
    done
    exec "$BASH_CC" --sysroot="$BASH_SYSROOT" -idirafter "$BASH_UAPI" \
        --ld-path="$BASH_LD" -static -nostdlib -no-pie -Wl,-z,separate-loadable-segments \
        "$BASH_SYSROOT/usr/lib/crt1.o" "$@" -L"$BASH_SYSROOT/usr/lib" -lc
fi

build=$1
BASH_SYSROOT=$2
BASH_CC=$(command -v "$3")
BASH_LD=$(command -v "$4")
BASH_UAPI=$5
if [ -z "$BASH_UAPI" ]; then
    BASH_UAPI="$(dirname "$BASH_SYSROOT")/linux-uapi"
fi
BASH_UAPI=$(cd "$BASH_UAPI" && pwd)
export BASH_SYSROOT BASH_UAPI BASH_CC BASH_LD

script=$(realpath "$0")
version=5.2.37
archive="$build/bash-$version.tar.gz"
checksum=9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff
mkdir -p "$build/obj"
if [ ! -f "$archive" ]; then
    curl -fLsS "https://ftp.gnu.org/gnu/bash/bash-$version.tar.gz" -o "$archive.tmp"
    printf '%s  %s\n' "$checksum" "$archive.tmp" | sha256sum -c -
    mv "$archive.tmp" "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c -
tar -xf "$archive" -C "$build"

# Give the bundled interactive shell the same identity shown by Fastfetch.
sed -i 's|^#define PPROMPT .*|#define PPROMPT "root@localhost:~# "|' \
    "$build/bash-$version/config-top.h"
sed -i 's|set_if_not ("PS1", current_user.euid == 0 ? "# " : primary_prompt);|set_if_not ("PS1", primary_prompt);|' \
    "$build/bash-$version/variables.c"

cd "$build/obj"
CC="sh $script --cc" CFLAGS="-O2 -march=x86-64 -fno-pie -std=gnu17" \
    "../bash-$version/configure" --enable-minimal-config --disable-nls \
    --without-bash-malloc --disable-readline --disable-job-control --enable-static-link
sed -i 's|^#  define PPROMPT .*|#  define PPROMPT "root@localhost:~# "|' \
    "$build/bash-$version/config-bot.h"
make bash
cp bash "$build/bash.elf"
