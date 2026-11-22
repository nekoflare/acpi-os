#!/bin/sh
# Build a static GNU Bash with the staged mlibc CRT and headers.
set -eu

app_cpu_flags=${APP_CPU_FLAGS:--march=native -mno-amx-tile}

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

source=$6
script=$(realpath "$0")
mkdir -p "$build/obj"
# Give the bundled interactive shell the same identity shown by Fastfetch.
sed -i 's|^#define PPROMPT .*|#define PPROMPT "root@localhost# "|' \
    "$source/config-top.h"
sed -i 's|set_if_not ("PS1", current_user.euid == 0 ? "# " : primary_prompt);|set_if_not ("PS1", primary_prompt);|' \
    "$source/variables.c"

# Export the guest shell path when Bash was started without a login environment.
sed -i '/^set_shell_var ()/,/^}/ {
    s|bind_variable ("SHELL", current_user.shell, 0)|bind_variable ("SHELL", "/bin/bash", 0)|
    /^#if 0$/d
    /^#endif$/d
}' "$source/variables.c"

cd "$build/obj"
printf 'Configuring GNU Bash\n'
CC="sh $script --cc" CFLAGS="-O2 $app_cpu_flags -fno-pie -std=gnu17" \
    "$source/configure" --enable-minimal-config --disable-nls \
    --without-bash-malloc --disable-readline --disable-job-control --enable-static-link
sed -i 's|^#  define PPROMPT .*|#  define PPROMPT "root@localhost# "|' \
    "$source/config-bot.h"
make clean
printf 'Compiling GNU Bash\n'
make -j"$7" bash
cp bash "$build/bash.elf"
