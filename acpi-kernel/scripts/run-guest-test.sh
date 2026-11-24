#!/bin/sh
# Build userspace/<suite>/<name>.c (jdk-tests for the Java port, net-tests for
# networking) as a static musl program, boot it as the
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
# "// disk-libs: <flags>" links those programs with more libraries from the
# volume's /usr/lib, for example "-lssl -lcrypto".
# "// timeout: <seconds>" raises the 60-second limit.
# "// net" attaches a legacy virtio-net NIC on QEMU user networking
# (guest 10.0.2.15, gateway 10.0.2.2, DNS 10.0.2.3) and captures its traffic
# in <build>/<name>.pcap.
# "// udp-echo" also runs a UDP echo server on the host, which the guest
# reaches at 10.0.2.2; its port is in /etc/udp-echo-port.
# "// tcp-server" runs scripts/tcp-test-server.py on the host; its port and a
# closed port are in /etc/tcp-port.
# "// http-server" runs scripts/http-test-server.py on the host with a fresh
# self-signed certificate for 10.0.2.2; its HTTP and HTTPS ports are in
# /etc/http-ports and the certificate is /etc/http-ca.pem.
# "// tcp-fwd: <port>" forwards a free host port to that guest port and runs
# scripts/tcp-fwd-client.py against it (needs "// net").
# Each "// expect: <text>" line must also appear in the serial log.
set -eu
cd "$(dirname "$0")/.."
name="$1"
src=
for suite in jdk-tests net-tests; do
    if [ -f "userspace/$suite/$name.c" ]; then src="userspace/$suite/$name.c"; fi
done
[ -n "$src" ] || { echo "no test named $name" >&2; exit 1; }
dir="$(dirname "$src")"
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
# The desktop initramfs carries /etc/hosts and /etc/resolv.conf; give tests
# the same files.
extra="etc/hosts=config/hosts etc/resolv.conf=config/resolv.conf"
if grep -q '^// link: static-pie' "$src"; then
    link="-static-pie -fPIE"
    crt="$musl/lib/rcrt1.o"
fi
# "// link: dynamic" links against a shared musl and packs its dynamic linker.
if grep -q '^// link: dynamic' "$src"; then
    scripts/build-musl-shared.sh "$build/musl-shared"
    link="-pie -fPIE -Wl,-dynamic-linker,/lib/ld-musl-x86_64.so.1"
    crt="$musl/lib/Scrt1.o"
    libc="-L$build/musl-shared/lib -lc"
    extra="lib/ld-musl-x86_64.so.1=$build/musl-shared/lib/libc.so"
fi
# Each "// shared-lib: lib/<x>.c" line builds /lib/lib<x>.so for the test.
for lib in $(sed -n 's|^// shared-lib: ||p' "$src"); do
    so="lib$(basename "$lib" .c).so"
    clang --target=x86_64-linux-musl -shared -fPIC -O1 -g -Wall -Wextra -Werror \
        -nostdinc -isystem "$musl/include" -isystem "$(clang -print-resource-dir)/include" \
        -nostdlib -fuse-ld=lld -Wl,-soname,"$so" "$dir/$lib" \
        -L"$build/musl-shared/lib" -lc -o "$build/$so"
    extra="$extra lib/$so=$build/$so"
done
# shellcheck disable=SC2086
clang --target=x86_64-linux-musl $link -O1 -g -Wall -Wextra -Werror \
    -nostdinc -isystem "$musl/include" -isystem "$(clang -print-resource-dir)/include" \
    -nostdlib -fuse-ld=lld "$crt" "$musl/lib/crti.o" \
    "$src" $libc "$(gcc -print-libgcc-file-name)" \
    "$musl/lib/crtn.o" -o "$build/$name.elf"
fstab=
drive=
packages=$(sed -n 's|^// disk: ||p' "$src")
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
    sed -n 's|^// prepare: ||p' "$src" | while read -r command; do
        sh -c "$command"
    done
    for spec in $(sed -n 's|^// disk-file: ||p' "$src"); do
        install -Dm644 "$dir/${spec#*=}" "$root/${spec%%=*}"
    done
    for spec in $(sed -n 's|^// disk-dir: ||p' "$src"); do
        mkdir -p "$root/${spec%%=*}"
        cp -a "${spec#*=}/." "$root/${spec%%=*}/"
    done
    for spec in $(sed -n 's|^// disk-dynamic: ||p' "$src"); do
        scripts/build-musl-shared.sh "$build/musl-shared"
        mkdir -p "$(dirname "$root/${spec%%=*}")"
        clang --target=x86_64-linux-musl -pie -fPIE -O1 -g -Wall -Wextra -Werror \
            -nostdinc -isystem "$musl/include" -isystem "$(clang -print-resource-dir)/include" \
            -isystem "$root/usr/include" -nostdlib -fuse-ld=lld \
            -Wl,-dynamic-linker,/lib/ld-musl-x86_64.so.1 "$musl/lib/Scrt1.o" "$musl/lib/crti.o" \
            "$dir/${spec#*=}" -L"$root/usr/lib" $(sed -n 's|^// disk-libs: ||p' "$src") \
            -L"$build/musl-shared/lib" -lc \
            "$(gcc -print-libgcc-file-name)" "$musl/lib/crtn.o" -o "$root/${spec%%=*}"
    done
    mkdir -p "$root/tmp"
    chmod 1777 "$root/tmp"
    # The fstab build adds /etc/hosts and /etc/resolv.conf itself.
    extra="$(printf '%s\n' $extra | grep -v "^etc/hosts=\\|^etc/resolv.conf=" | tr '\n' ' ')"
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
    if grep -q '^// disk-rw' "$src"; then
        mode=rw
        readonly=off
    fi
    printf '/dev/vda1 / ext4 %s 0 0\n' "$mode" > "$fstab"
    drive="-drive if=none,id=test,format=raw,readonly=$readonly,file=$build/$name.disk
        -device virtio-blk-pci,drive=test,disable-modern=on,queue-size=16"
fi
net=
if grep -q '^// net$' "$src"; then
    rm -f "$build/$name.pcap"
    fwd=
    guest_port=$(sed -n 's|^// tcp-fwd: ||p' "$src")
    if [ -n "$guest_port" ]; then
        host_port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
        fwd=",hostfwd=tcp:127.0.0.1:$host_port-:$guest_port"
    fi
    net="-netdev user,id=n0$fwd -device virtio-net-pci,netdev=n0,disable-modern=on,romfile=
        -object filter-dump,id=d0,netdev=n0,file=$build/$name.pcap"
fi
echo_pid=
if grep -q '^// udp-echo$' "$src"; then
    port_file="$build/$name.udp-port"
    rm -f "$port_file"
    python3 -I -c '
import os, socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 0))
open(sys.argv[1] + ".tmp", "w").write("%d\n" % s.getsockname()[1])
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
while True:
    data, peer = s.recvfrom(65536)
    s.sendto(data, peer)
' "$port_file" &
    echo_pid=$!
    while [ ! -f "$port_file" ]; do sleep 0.05; done
    extra="$extra etc/udp-echo-port=$port_file"
fi
if grep -q '^// tcp-server$' "$src"; then
    tcp_file="$build/$name.tcp-port"
    rm -f "$tcp_file"
    python3 -I scripts/tcp-test-server.py "$tcp_file" &
    echo_pid="$echo_pid $!"
    while [ ! -f "$tcp_file" ]; do sleep 0.05; done
    extra="$extra etc/tcp-port=$tcp_file"
fi
if grep -q '^// http-server$' "$src"; then
    http_file="$build/$name.http-ports"
    rm -f "$http_file"
    # The certificate starts a day early, so a guest clock that is slightly
    # behind still accepts it.
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 7 \
        -not_before "$(date -u -d yesterday +%Y%m%d%H%M%SZ)" -subj /CN=10.0.2.2 \
        -addext subjectAltName=IP:10.0.2.2 -keyout "$build/$name.key" \
        -out "$build/$name.pem" 2>/dev/null
    python3 -I scripts/http-test-server.py "$http_file" "$build/$name.pem" "$build/$name.key" &
    echo_pid="$echo_pid $!"
    while [ ! -f "$http_file" ]; do sleep 0.05; done
    extra="$extra etc/http-ports=$http_file etc/http-ca.pem=$build/$name.pem"
fi
# shellcheck disable=SC2086
trap '[ -z "$echo_pid" ] || kill $echo_pid 2>/dev/null || true' EXIT
limit=$(sed -n 's|^// timeout: ||p' "$src")
make -s BUILD="$build/boot" BOOT_ELF="$build/$name.elf" INITRAMFS_EXTRA="$extra" \
    INITRAMFS_FSTAB="$fstab" all \
    >"$build/make.log" 2>&1 ||
    { cat "$build/make.log"; exit 1; }
log="$build/$name.serial.log"
rm -f "$log"
# shellcheck disable=SC2086
timeout "${limit:-60}" qemu-system-x86_64 -m 4G -boot d -cdrom "$build/boot/acpi-kernel.iso" \
    -serial "file:$log" -monitor none -no-reboot -enable-kvm -cpu host -smp "$smp" \
    -display none $drive $net &
qemu=$!
if [ -n "${host_port:-}" ]; then
    python3 -I scripts/tcp-fwd-client.py "$host_port" &
    echo_pid="$echo_pid $!"
fi
while kill -0 "$qemu" 2>/dev/null; do
    if grep -qa "exited status=" "$log" 2>/dev/null; then break; fi
    sleep 0.2
done
kill "$qemu" 2>/dev/null || true
wait "$qemu" 2>/dev/null || true
sed -n '/SMP tasks ran simultaneously/,$p' "$log" | sed 1d
grep -qa "exited status=0x0000000000000000" "$log" && grep -qa "^PASS" "$log" || exit 1
sed -n 's|^// expect: ||p' "$src" | while IFS= read -r text; do
    grep -qaF "$text" "$log" || { echo "missing from serial log: $text" >&2; exit 1; }
done
