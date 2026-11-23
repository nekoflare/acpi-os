#!/bin/sh
# Build userspace/jdk-tests/<name>.c as a static musl program, boot it as the
# init module and print its serial output. The test passes when it exits with
# status zero and prints "PASS". The program is also packed into the
# initramfs as /bin/<name>.elf, so it can execute itself.
#   scripts/run-guest-test.sh mmap-exec [smp]
# A "// disk: <package>..." line unpacks those jinx packages onto an ext4
# volume that /etc/fstab mounts at /, for tests that need large files.
# "// disk-rw" mounts that volume read-write; it is rebuilt on every run.
# "// disk-file: <path>=<source>" copies a file onto that volume.
# "// disk-dir: <path>=<directory>" copies a host directory (relative to
# acpi-kernel/) onto that volume.
# "// prepare: <command>" runs a host command from acpi-kernel/ first, for
# example to download files that disk-dir copies.
# "// disk-dynamic: <path>=<source>" builds a dynamically linked program (PIE,
# shared musl) onto that volume; the volume's /usr/include is on its path.
# "// timeout: <seconds>" raises the 60-second limit.
set -eu
cd "$(dirname "$0")/.."
name="$1"
smp="${2:-4}"
build="$(realpath -m ../target/acpi-kernel-jdk-tests)"
musl_pkg="$(ls ../target/acpi-os-jinx/*/build/pkgs/musl-*.xbps 2>/dev/null | head -n 1)"
mkdir -p "$build"
if [ ! -f "$build/musl/opt/acpi-musl/lib/libc.a" ]; then
    mkdir -p "$build/musl"
    tar -xf "$musl_pkg" -C "$build/musl"
fi
musl="$build/musl/opt/acpi-musl"
# A "// link: static-pie" line builds a position-independent executable.
link="-static"
crt="$musl/lib/crt1.o"
libc="$musl/lib/libc.a"
# The desktop initramfs carries /etc/hosts; give tests the same file.
extra="etc/hosts=config/hosts"
if grep -q '^// link: static-pie' "userspace/jdk-tests/$name.c"; then
    link="-static-pie -fPIE"
    crt="$musl/lib/rcrt1.o"
fi
# "// link: dynamic" links against a shared musl and packs its dynamic linker.
if grep -q '^// link: dynamic' "userspace/jdk-tests/$name.c"; then
    scripts/build-musl-shared.sh "$build/musl-shared"
    link="-pie -fPIE -Wl,-dynamic-linker,/lib/ld-musl-x86_64.so.1"
    crt="$musl/lib/Scrt1.o"
    libc="-L$build/musl-shared/lib -lc"
    extra="lib/ld-musl-x86_64.so.1=$build/musl-shared/lib/libc.so"
fi
# Each "// shared-lib: lib/<x>.c" line builds /lib/lib<x>.so for the test.
for lib in $(sed -n 's|^// shared-lib: ||p' "userspace/jdk-tests/$name.c"); do
    so="lib$(basename "$lib" .c).so"
    clang --target=x86_64-linux-musl -shared -fPIC -O1 -g -Wall -Wextra -Werror \
        -nostdinc -isystem "$musl/include" -isystem "$(clang -print-resource-dir)/include" \
        -nostdlib -fuse-ld=lld -Wl,-soname,"$so" "userspace/jdk-tests/$lib" \
        -L"$build/musl-shared/lib" -lc -o "$build/$so"
    extra="$extra lib/$so=$build/$so"
done
# shellcheck disable=SC2086
clang --target=x86_64-linux-musl $link -O1 -g -Wall -Wextra -Werror \
    -nostdinc -isystem "$musl/include" -isystem "$(clang -print-resource-dir)/include" \
    -nostdlib -fuse-ld=lld "$crt" "$musl/lib/crti.o" \
    "userspace/jdk-tests/$name.c" $libc "$(gcc -print-libgcc-file-name)" \
    "$musl/lib/crtn.o" -o "$build/$name.elf"
fstab=
drive=
packages=$(sed -n 's|^// disk: ||p' "userspace/jdk-tests/$name.c")
if [ -n "$packages" ]; then
    root="$build/$name.root"
    rm -rf "$root"
    mkdir -p "$root"
    for package in $packages; do
        file="$(ls -t ../target/acpi-os-jinx/*/build/pkgs/"$package"-[0-9]*.xbps 2>/dev/null | head -n 1)"
        [ -n "$file" ] || { echo "package $package not built" >&2; exit 1; }
        tar -xf "$file" -C "$root"
    done
    rm -f "$root"/*.plist
    sed -n 's|^// prepare: ||p' "userspace/jdk-tests/$name.c" | while read -r command; do
        sh -c "$command"
    done
    for spec in $(sed -n 's|^// disk-file: ||p' "userspace/jdk-tests/$name.c"); do
        install -Dm644 "userspace/jdk-tests/${spec#*=}" "$root/${spec%%=*}"
    done
    for spec in $(sed -n 's|^// disk-dir: ||p' "userspace/jdk-tests/$name.c"); do
        mkdir -p "$root/${spec%%=*}"
        cp -a "${spec#*=}/." "$root/${spec%%=*}/"
    done
    for spec in $(sed -n 's|^// disk-dynamic: ||p' "userspace/jdk-tests/$name.c"); do
        scripts/build-musl-shared.sh "$build/musl-shared"
        mkdir -p "$(dirname "$root/${spec%%=*}")"
        clang --target=x86_64-linux-musl -pie -fPIE -O1 -g -Wall -Wextra -Werror \
            -nostdinc -isystem "$musl/include" -isystem "$(clang -print-resource-dir)/include" \
            -isystem "$root/usr/include" -nostdlib -fuse-ld=lld \
            -Wl,-dynamic-linker,/lib/ld-musl-x86_64.so.1 "$musl/lib/Scrt1.o" "$musl/lib/crti.o" \
            "userspace/jdk-tests/${spec#*=}" -L"$build/musl-shared/lib" -lc \
            "$(gcc -print-libgcc-file-name)" "$musl/lib/crtn.o" -o "$root/${spec%%=*}"
    done
    mkdir -p "$root/tmp"
    chmod 1777 "$root/tmp"
    # The fstab build adds /etc/hosts itself.
    extra="$(printf '%s\n' $extra | grep -v '^etc/hosts=' | tr '\n' ' ')"
    size=$(( $(du -sm "$root" | cut -f1) * 3 / 2 + 64 ))
    rm -f "$build/$name.ext4" "$build/$name.disk"
    truncate -s "${size}M" "$build/$name.ext4"
    mkfs.ext4 -q -F -b 4096 -I 256 -O none,filetype,extent -L acpi-test \
        -d "$root" "$build/$name.ext4"
    truncate -s "$((size + 2))M" "$build/$name.disk"
    printf 'label: gpt\nstart=2048, size=%d, type=L\n' $((size * 2048)) |
        sfdisk --quiet "$build/$name.disk"
    dd if="$build/$name.ext4" of="$build/$name.disk" bs=1M seek=1 conv=notrunc,sparse status=none
    rm -f "$build/$name.ext4"
    fstab="$build/$name.fstab"
    mode=ro
    readonly=on
    if grep -q '^// disk-rw' "userspace/jdk-tests/$name.c"; then
        mode=rw
        readonly=off
    fi
    printf '/dev/vda1 / ext4 %s 0 0\n' "$mode" > "$fstab"
    drive="-drive if=none,id=test,format=raw,readonly=$readonly,file=$build/$name.disk
        -device virtio-blk-pci,drive=test,disable-modern=on,queue-size=16"
fi
limit=$(sed -n 's|^// timeout: ||p' "userspace/jdk-tests/$name.c")
make -s BUILD="$build/boot" BOOT_ELF="$build/$name.elf" INITRAMFS_EXTRA="$extra" \
    INITRAMFS_FSTAB="$fstab" all \
    >"$build/make.log" 2>&1 ||
    { cat "$build/make.log"; exit 1; }
log="$build/$name.serial.log"
rm -f "$log"
# shellcheck disable=SC2086
timeout "${limit:-60}" qemu-system-x86_64 -m 4G -boot d -cdrom "$build/boot/acpi-kernel.iso" \
    -serial "file:$log" -monitor none -no-reboot -enable-kvm -cpu host -smp "$smp" \
    -display none $drive &
qemu=$!
while kill -0 "$qemu" 2>/dev/null; do
    if grep -qa "exited status=" "$log" 2>/dev/null; then break; fi
    sleep 0.2
done
kill "$qemu" 2>/dev/null || true
wait "$qemu" 2>/dev/null || true
sed -n '/SMP tasks ran simultaneously/,$p' "$log" | sed 1d
grep -qa "exited status=0x0000000000000000" "$log" && grep -qa "^PASS" "$log"
