#!/bin/sh
# Download the LWJGL 3.3.1 Java jars that Minecraft 1.20.1 uses from Mojang's
# library server into a directory (default ../target/lwjgl-3.3.1) and check
# their SHA-1 against the 1.20.1 version manifest. The native libraries are
# built by the lwjgl* recipes instead; the natives-linux jars are glibc builds.
set -eu
cd "$(dirname "$0")/.."
dest="${1:-../target/lwjgl-3.3.1}"
mkdir -p "$dest"
while read -r sha1 name; do
    file="$dest/$name-3.3.1.jar"
    if [ -f "$file" ] && [ "$(sha1sum < "$file" | cut -d' ' -f1)" = "$sha1" ]; then
        continue
    fi
    curl -sfL -o "$file.part" "https://libraries.minecraft.net/org/lwjgl/$name/3.3.1/$name-3.3.1.jar"
    [ "$(sha1sum < "$file.part" | cut -d' ' -f1)" = "$sha1" ] || { echo "$name: bad SHA-1" >&2; exit 1; }
    mv "$file.part" "$file"
done <<'LIST'
ae58664f88e18a9bb2c77b063833ca7aaec484cb lwjgl
cbac1b8d30cb4795149c1ef540f912671a8616d0 lwjgl-glfw
a817bcf213db49f710603677457567c37d53e103 lwjgl-jemalloc
2623a6b8ae1dfcd880738656a9f0243d2e6840bd lwjgl-openal
831a5533a21a5f4f81bbc51bb13e9899319b5411 lwjgl-opengl
b119297cf8ed01f247abe8685857f8e7fcf5980f lwjgl-stb
0ff1914111ef2e3e0110ef2dabc8d8cdaad82347 lwjgl-tinyfd
LIST
