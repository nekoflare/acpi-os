#!/bin/sh
# Download the LWJGL 3.3.3 Java jars that Minecraft 1.21.11 uses from Mojang's
# library server into a directory (default ../target/lwjgl-3.3.3) and check
# their SHA-1 against the 1.21.11 version manifest. The native libraries are
# built by the lwjgl* recipes instead; the natives-linux jars are glibc builds.
set -eu
cd "$(dirname "$0")/.."
dest="${1:-../target/lwjgl-3.3.3}"
mkdir -p "$dest"
while read -r sha1 name; do
    file="$dest/$name-3.3.3.jar"
    if [ -f "$file" ] && [ "$(sha1sum < "$file" | cut -d' ' -f1)" = "$sha1" ]; then
        continue
    fi
    curl -sfL -o "$file.part" "https://libraries.minecraft.net/org/lwjgl/$name/3.3.3/$name-3.3.3.jar"
    [ "$(sha1sum < "$file.part" | cut -d' ' -f1)" = "$sha1" ] || { echo "$name: bad SHA-1" >&2; exit 1; }
    mv "$file.part" "$file"
done <<'LIST'
29589b5f87ed335a6c7e7ee6a5775f81f97ecb84 lwjgl
a0db6c84a8becc8ca05f9dbfa985edc348a824c7 lwjgl-freetype
efa1eb78c5ccd840e9f329717109b5e892d72f8e lwjgl-glfw
b543467b7ff3c6920539a88ee602d34098628be5 lwjgl-jemalloc
daada81ceb5fc0c291fbfdd4433cb8d9423577f2 lwjgl-openal
02f6b0147078396a58979125a4c947664e98293a lwjgl-opengl
25dd6161988d7e65f71d5065c99902402ee32746 lwjgl-stb
82d755ca94b102e9ca77283b9e2dc46d1b15fbe5 lwjgl-tinyfd
LIST
