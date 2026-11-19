#!/bin/sh
# Build upstream dwm as a static x86-64 Linux executable for the guest.
set -eu

build=$1
docker=$2
version=6.8
digest=bcf540589ad174d4073f4efa658828411e2f5ba63196cfaf6b71363700f590b7
image=alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

mkdir -p "$build"
download()
{
    file=$1
    url=$2
    checksum=$3
    if [ ! -f "$build/$file" ]; then
        curl -fL --connect-timeout 15 --retry 2 "$url" -o "$build/$file.part"
        printf '%s  %s\n' "$checksum" "$build/$file.part" | sha256sum -c -
        mv "$build/$file.part" "$build/$file"
    fi
    printf '%s  %s\n' "$checksum" "$build/$file" | sha256sum -c -
}

download "dwm-$version.tar.gz" "https://dl.suckless.org/dwm/dwm-$version.tar.gz" "$digest"
download libXau-1.0.12.tar.xz \
    https://xorg.freedesktop.org/archive/individual/lib/libXau-1.0.12.tar.xz \
    74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb

output=$(mktemp "$build/dwm.XXXXXX")
trap 'test ! -e "$output" || unlink "$output"' EXIT
"$docker" run --rm --platform linux/amd64 -v "$build:/sources:ro" "$image" sh -ec '
    version=$1
    mkdir -p /work
    tar -xzf "/sources/dwm-$version.tar.gz" -C /work
    tar -xJf /sources/libXau-1.0.12.tar.xz -C /work
    apk add --no-cache gcc musl-dev make binutils pkgconf libx11-dev libx11-static libxcb-static \
        libxft-dev libxrender-dev libxau-dev libxdmcp-dev fontconfig-dev fontconfig-static \
        freetype-dev freetype-static expat-static libpng-static zlib-static \
        brotli-static bzip2-static >&2
    cd /work/libXau-1.0.12
    ./configure --disable-shared --enable-static >&2
    make -j"$(getconf _NPROCESSORS_ONLN)" >&2
    make install >&2
    cd "/work/dwm-$version"
    make -j"$(getconf _NPROCESSORS_ONLN)" XINERAMAFLAGS= XINERAMALIBS= \
        FREETYPEINC=/usr/include/freetype2 \
        LDFLAGS="-static -no-pie -Wl,-z,separate-code -L/usr/local/lib $(pkg-config --static --libs x11 xft fontconfig)" >&2
    strip dwm
    cat dwm
' sh "$version" > "$output"
chmod 755 "$output"
mv "$output" "$build/dwm"
