#!/bin/sh
# Build st and its X11 client libraries directly with the guest musl compiler.
set -eu

build=$1
prefix=$2
jobs=$3
cpu_flags=${APP_CPU_FLAGS:--march=native -mno-amx-tile}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
xorg=https://www.x.org/releases/individual/lib
mkdir -p "$build/sources" "$build/work"

download()
{
    archive="$build/sources/$1"
    if [ ! -f "$archive" ]; then
        curl -fsSL --connect-timeout 15 --retry 2 "$2" -o "$archive.part"
        printf '%s  %s\n' "$3" "$archive.part" | sha256sum -c -
        mv "$archive.part" "$archive"
    fi
    printf '%s  %s\n' "$3" "$archive" | sha256sum -c -
    tar -xf "$archive" -C "$build/work"
}

download st-0.9.3.tar.gz https://dl.suckless.org/st/st-0.9.3.tar.gz \
    9ed9feabcded713d4ded38c8cebf36a3b08f0042ef7934a0e2b2409da56e649b
download libxcb-1.17.0.tar.xz "$xorg/libxcb-1.17.0.tar.xz" \
    599ebf9996710fea71622e6e184f3a8ad5b43d0e5fa8c4e407123c88a59a6d55
download libX11-1.8.13.tar.xz "$xorg/libX11-1.8.13.tar.xz" \
    69606f485c2c07c14ef64f75b7bb326d48587af33795d9ab3e607c0b5f94f11c
download libXrender-0.9.12.tar.xz "$xorg/libXrender-0.9.12.tar.xz" \
    b832128da48b39c8d608224481743403ad1691bf4e554e4be9c174df171d1b97
download freetype-2.13.3.tar.gz https://codeload.github.com/freetype/freetype/tar.gz/refs/tags/VER-2-13-3 \
    bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103
download expat-2.7.3.tar.gz https://codeload.github.com/libexpat/libexpat/tar.gz/refs/tags/R_2_7_3 \
    7c853a76f7c2a562c3edfd84ca47e487d9eff3966786191dfb60cc441daf82d6
download fontconfig-2.16.0.tar.xz https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.16.0.tar.xz \
    6a33dc555cc9ba8b10caf7695878ef134eeb36d0af366041f639b1da9b6ed220
download libXft-2.3.9.tar.xz "$xorg/libXft-2.3.9.tar.xz" \
    60a25b78945ed6932635b3bb1899a517d31df7456e69867ffba27f89ff3976f5

if ! command -v gperf >/dev/null; then
    download gperf-3.1.tar.gz https://ftp.gnu.org/gnu/gperf/gperf-3.1.tar.gz \
        588546b945bba4b70b6a3a616e80b4ab466e3f33024a352fc2198112cdbb3ae2
    (
        cd "$build/work/gperf-3.1"
        ./configure --prefix="$build/host"
        make -j"$jobs"
        make install
    )
    PATH="$build/host/bin:$PATH"
    export PATH
fi

export CC="$prefix/musl/bin/musl-gcc"
export CFLAGS="-O2 $cpu_flags -fno-pie -I$prefix/include"
export CPPFLAGS="-I$prefix/include"
export LDFLAGS="-static -no-pie -L$prefix/lib"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig:/usr/share/pkgconfig"
unset PKG_CONFIG_PATH

build_auto()
(
    cd "$build/work/$1"
    shift
    ./configure --prefix="$prefix" --disable-shared --enable-static "$@"
    make -j"$jobs"
    make install
)

build_cmake()
{
    source=$1
    output=$2
    shift 2
    cmake -S "$build/work/$source" -B "$build/$output" -G Ninja \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$CFLAGS" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib "$@"
    cmake --build "$build/$output" -j"$jobs"
    cmake --install "$build/$output"
}

build_auto libxcb-1.17.0 XCBPROTO_CFLAGS=-I/usr/share/xcb XCBPROTO_LIBS=-lm
build_auto libX11-1.8.13 --disable-xf86bigfont
build_auto libXrender-0.9.12
build_cmake freetype-VER-2-13-3 freetype -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_ZLIB=ON
build_cmake libexpat-R_2_7_3/expat expat -DEXPAT_SHARED_LIBS=OFF -DEXPAT_BUILD_TESTS=OFF \
    -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_DOCS=OFF
build_auto fontconfig-2.16.0 --disable-docs --disable-nls --disable-cache-build
build_auto libXft-2.3.9

st="$build/work/st-0.9.3"
patch -d "$st" -p1 < "$script_dir/patches/st-guest-terminal.patch"
cp "$script_dir/../userspace/st-guest-poll.h" "$st/amlaot-poll.h"
cp "$st/config.def.h" "$st/config.h"
make -C "$st" -j"$jobs" clean
make -C "$st" -j"$jobs" CC="$CC" CPPFLAGS="-D_GNU_SOURCE -include amlaot-poll.h" \
    INCS="-I$prefix/include $(pkg-config --cflags xft)" LIBS="$(pkg-config --static --libs xft) -lm" \
    CFLAGS="-O2 $cpu_flags -fno-pie" LDFLAGS="-static -no-pie"
install -m 755 "$st/st" "$build/st"
