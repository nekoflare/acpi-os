#!/bin/sh
# Download the Minecraft 1.20.1 client into a directory (default
# ../target/minecraft-1.20.1), checking every file's SHA-1:
#   client.jar          the game
#   libraries/*.jar     its Java libraries, without LWJGL (scripts/fetch-lwjgl.sh)
#                       and the glibc netty epoll natives (netty falls back to NIO)
#   assets/indexes/5.json, assets/objects/xx/<sha1>   sounds, languages, icons
# Only the version manifest is trusted by URL; everything else is pinned by it.
set -eu
cd "$(dirname "$0")/.."
dest="${1:-../target/minecraft-1.20.1}"
version_url=https://piston-meta.mojang.com/v1/packages/fb730d2829f057fe26a41e5ecdc9e3307333bef5/1.20.1.json
version_sha1=fb730d2829f057fe26a41e5ecdc9e3307333bef5
mkdir -p "$dest/libraries" "$dest/assets/indexes" "$dest/assets/objects"

# fetch <url> <sha1> <file>: download unless the file already matches.
fetch()
{
    if [ -f "$3" ] && [ "$(sha1sum < "$3" | cut -d' ' -f1)" = "$2" ]; then
        return 0
    fi
    curl -sfL --retry 3 -o "$3.part" "$1"
    [ "$(sha1sum < "$3.part" | cut -d' ' -f1)" = "$2" ] || { echo "$3: bad SHA-1" >&2; exit 1; }
    mv "$3.part" "$3"
}

fetch "$version_url" "$version_sha1" "$dest/1.20.1.json"
json="$dest/1.20.1.json"
fetch "$(jq -r .downloads.client.url "$json")" "$(jq -r .downloads.client.sha1 "$json")" "$dest/client.jar"

jq -r '.libraries[] | select(.rules == null) | select(.name | startswith("org.lwjgl:") | not)
    | .downloads.artifact | "\(.url) \(.sha1) \(.path | split("/") | last)"' "$json" |
    while read -r url sha1 name; do
        fetch "$url" "$sha1" "$dest/libraries/$name"
    done

index="$dest/assets/indexes/$(jq -r .assetIndex.id "$json").json"
fetch "$(jq -r .assetIndex.url "$json")" "$(jq -r .assetIndex.sha1 "$json")" "$index"
# Objects are named by their SHA-1. Download the missing ones in parallel,
# then check them all; a failed download shows up there (rerun to retry).
jq -r '.objects[].hash' "$index" | sort -u | while read -r hash; do
    file="$dest/assets/objects/$(printf %.2s "$hash")/$hash"
    [ -f "$file" ] || printf '%s\n' "$hash"
done | xargs -r -P 16 -I{} sh -c '
    hash={}; dir="$1/assets/objects/$(printf %.2s "$hash")"; mkdir -p "$dir"
    curl -sfL --retry 3 -o "$dir/$hash.part" "https://resources.download.minecraft.net/$(printf %.2s "$hash")/$hash" &&
        mv "$dir/$hash.part" "$dir/$hash"' sh "$dest" || true
jq -r '.objects[].hash' "$index" | sort -u | while read -r hash; do
    printf '%s  %s\n' "$hash" "$dest/assets/objects/$(printf %.2s "$hash")/$hash"
done | sha1sum -c --quiet
