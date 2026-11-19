#!/bin/sh
# Build upstream xeyes and its static X.Org dependencies for the guest.
set -eu

build=$1
docker=$2
image=alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
xorg=https://xorg.freedesktop.org/archive/individual
mkdir -p "$build"

fetch()
{
    file=${1##*/}
    if [ ! -f "$build/$file" ]; then
        curl -fLsS --connect-timeout 15 --retry 2 "$xorg/$1" -o "$build/$file.part"
        printf '%s  %s\n' "$2" "$build/$file.part" | sha256sum -c -
        mv "$build/$file.part" "$build/$file"
    fi
    printf '%s  %s\n' "$2" "$build/$file" | sha256sum -c -
}

fetch app/xeyes-1.3.0.tar.xz 0950c600bf33447e169a539ee6655ef9f36d6cebf2c1be67f7ab55dacb753023
fetch lib/libXau-1.0.12.tar.xz 74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb
fetch lib/libSM-1.2.6.tar.xz be7c0abdb15cbfd29ac62573c1c82e877f9d4047ad15321e7ea97d1e43d835be
fetch lib/libXt-1.3.1.tar.xz e0a774b33324f4d4c05b199ea45050f87206586d81655f8bef4dba434d931288
fetch lib/libXmu-1.3.1.tar.xz 81a99e94c4501e81c427cbaa4a11748b584933e94b7a156830c3621256857bc4

output=$(mktemp "$build/xeyes.XXXXXX")
trap 'test ! -e "$output" || unlink "$output"' EXIT
"$docker" run --rm --platform linux/amd64 -v "$build:/sources:ro" "$image" sh -ec '
    apk add --no-cache gcc musl-dev make binutils pkgconf libx11-dev libx11-static libxcb-static         libxau-dev libxdmcp-dev libxt-dev libxmu-dev libxi-dev libxi-static libxfixes-dev         libxext-dev libxext-static libice-static util-linux-static >&2
    mkdir /work
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
    for library in libXau-1.0.12 libSM-1.2.6 libXt-1.3.1 libXmu-1.3.1; do
        tar -xJf "/sources/$library.tar.xz" -C /work
        cd "/work/$library"
        ./configure --disable-shared --enable-static >&2
        make -j"$(getconf _NPROCESSORS_ONLN)" >&2
        make install >&2
    done
    tar -xJf /sources/xeyes-1.3.0.tar.xz -C /work
    cd /work/xeyes-1.3.0
    XEYES_LIBS="$(pkg-config --static --libs xi x11 xt xext xmu)"         ./configure --without-xrender --without-present >&2
    make -j"$(getconf _NPROCESSORS_ONLN)" LDFLAGS="-static -no-pie -Wl,-z,separate-code" >&2
    strip xeyes
    cat xeyes
' > "$output"
chmod 755 "$output"
mv "$output" "$build/xeyes"
