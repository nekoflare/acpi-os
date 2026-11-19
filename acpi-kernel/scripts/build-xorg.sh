#!/bin/sh
# Build the upstream X.Org virtual framebuffer server with the host toolchain.
set -eu

app_cpu_flags=${APP_CPU_FLAGS:--march=native -mno-amx-tile}

build=$1
jobs=$2
meson=$3
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix="$build/sysroot"
archive_dir="$build/sources"
work="$build/work"
xorg_release=https://www.x.org/releases/individual

mkdir -p "$archive_dir" "$work" "$prefix"
download()
{
    name=$1
    url=$2
    digest=$3
    archive="$archive_dir/$name"
    if [ ! -f "$archive" ]; then
        curl -fsSL --connect-timeout 15 --retry 2 "$url" -o "$archive.part"
        printf '%s  %s\n' "$digest" "$archive.part" | sha256sum -c -
        mv "$archive.part" "$archive"
    fi
    printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
    tar -xf "$archive" -C "$work"
}

download musl-1.2.5.tar.gz https://codeload.github.com/ifduyue/musl/tar.gz/refs/tags/v1.2.5 \
    83ff394502d1c334b040ea9bc66ec48bba453585e25b05f4bde3741d8245d883
download zlib-1.3.1.tar.gz https://codeload.github.com/madler/zlib/tar.gz/refs/tags/v1.3.1 \
    17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c
download libmd-1.1.0.tar.xz https://libbsd.freedesktop.org/releases/libmd-1.1.0.tar.xz \
    1bd6aa42275313af3141c7cf2e5b964e8b1fd488025caf2f971f43b00776b332
download xtrans-1.6.0.tar.xz "$xorg_release/lib/xtrans-1.6.0.tar.xz" \
    faafea166bf2451a173d9d593352940ec6404145c5d1da5c213423ce4d359e92
download libXau-1.0.12.tar.xz "$xorg_release/lib/libXau-1.0.12.tar.xz" \
    74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb
download libfontenc-1.1.8.tar.xz "$xorg_release/lib/libfontenc-1.1.8.tar.xz" \
    7b02c3d405236e0d86806b1de9d6868fe60c313628b38350b032914aa4fd14c6
download libXfont2-2.0.7.tar.xz "$xorg_release/lib/libXfont2-2.0.7.tar.xz" \
    8b7b82fdeba48769b69433e8e3fbb984a5f6bf368b0d5f47abeec49de3e58efb
download libxkbfile-1.1.3.tar.xz "$xorg_release/lib/libxkbfile-1.1.3.tar.xz" \
    a9b63eea997abb9ee6a8b4fbb515831c841f471af845a09de443b28003874bec
download pixman-0.46.4.tar.gz https://www.cairographics.org/releases/pixman-0.46.4.tar.gz \
    d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c
download xorg-server-21.1.21.tar.xz "$xorg_release/xserver/xorg-server-21.1.21.tar.xz" \
    c0cbe5545b3f645bae6024b830d1d1154a956350683a4e52b2fff5b0fa1ab519

patch -d "$work/xtrans-1.6.0" -p1 < "$script_dir/patches/xtrans-guest-sockets.patch"
patch -d "$work/xorg-server-21.1.21" -p1 < "$script_dir/patches/xorg-guest-keymap.patch"
patch -d "$work/xorg-server-21.1.21" -p1 < "$script_dir/patches/xorg-guest-devices.patch"
cp "$script_dir/../userspace/xorg-guest.c" "$work/xorg-server-21.1.21/hw/vfb/amlaot-guest.c"

(
    cd "$work/musl-1.2.5"
    ./configure --prefix="$prefix/musl" --disable-shared
    make -j"$jobs"
    make install
)

export CC="$prefix/musl/bin/musl-gcc"
export CFLAGS="-O2 $app_cpu_flags -fno-pie"
export CPPFLAGS="-I$prefix/include"
export LDFLAGS="-static -no-pie -L$prefix/lib"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig:/usr/share/pkgconfig"
unset PKG_CONFIG_PATH

# Xlib and the protocol headers are architecture-independent. Guest
# libraries and their pkg-config metadata come from the private prefix.
for subdir in '' /extensions /fonts; do
    mkdir -p "$prefix/include/X11$subdir"
    for header in /usr/include/X11"$subdir"/*.h; do
        dest="$prefix/include/X11$subdir/${header##*/}"
        if [ ! -e "$dest" ]; then ln -s "$header" "$dest"; fi
    done
done

build_autoconf()
(
    cd "$work/$1"
    shift
    ./configure --prefix="$prefix" --disable-shared --enable-static "$@"
    make -j"$jobs"
    make install
)

(
    cd "$work/zlib-1.3.1"
    ./configure --prefix="$prefix" --static
    make -j"$jobs"
    make install
)
build_autoconf libmd-1.1.0
build_autoconf xtrans-1.6.0
build_autoconf libXau-1.0.12
build_autoconf libfontenc-1.1.8
build_autoconf libXfont2-2.0.7 --disable-freetype
build_autoconf libxkbfile-1.1.3 XKBFILE_CFLAGS="-I$prefix/include" XKBFILE_LIBS=-lm
# The server contains its own XKB implementation and needs no Xlib.
sed -i '/^Requires.private: x11$/d' "$prefix/lib/pkgconfig/xkbfile.pc"

meson_setup()
{
    if [ -f "$1/build.ninja" ]; then
        "$meson" setup --reconfigure "$@"
    else
        "$meson" setup "$@"
    fi
}

meson_setup "$build/pixman" "$work/pixman-0.46.4" --prefix="$prefix" --libdir=lib \
    -Dc_args="-O2 $app_cpu_flags -fno-pie" \
    --default-library=static -Dtests=disabled -Ddemos=disabled -Dgtk=disabled
"$meson" compile -C "$build/pixman" -j "$jobs"
"$meson" install -C "$build/pixman"

# Stage the host's exported Linux UAPI for the guest framebuffer ioctls.
for headers in linux asm-generic; do
    ln -sfn "/usr/include/$headers" "$prefix/include/$headers"
done
asm_headers=/usr/include/asm
if [ ! -d "$asm_headers" ]; then
    asm_headers="/usr/include/$(gcc -print-multiarch)/asm"
fi
ln -sfn "$asm_headers" "$prefix/include/asm"

# X.Org already has a portable poll backend for kernels without epoll.
sed -i "s/cc.has_function('epoll_create1') ? '1' : false/false/" \
    "$work/xorg-server-21.1.21/include/meson.build"
# Resolve libmd from the guest prefix even when the host ships libmd.so.
sed -i "s/cc.find_library('md', required: false)/dependency('libmd', required: false)/" \
    "$work/xorg-server-21.1.21/meson.build"
meson_setup "$build/xserver" "$work/xorg-server-21.1.21" --prefix="$prefix" --libdir=lib \
    -Dc_args="-O2 $app_cpu_flags -fno-pie -DAMLAOT_GUEST -I$prefix/include" \
    --default-library=static -Dprefer_static=true -Dxorg=false -Dxnest=false -Dxvfb=true -Dglx=false -Dudev=false \
    -Dudev_kms=false -Dinput_thread=false -Dmitshm=false -Ddrm=false -Ddri1=false \
    -Ddri2=false -Ddri3=false -Dxdmcp=false -Dxdm-auth-1=false -Dsecure-rpc=false \
    -Dipv6=false -Dsha1=libmd -Ddocs=false -Ddevel-docs=false \
    -Ddefault_font_path=built-ins -Dxkb_dir=/xkb -Dxkb_bin_dir=/ -Dxkb_output_dir=/tmp
"$meson" compile -C "$build/xserver" -j "$jobs" Xvfb
install -m 755 "$build/xserver/hw/vfb/Xvfb" "$build/Xvfb"
