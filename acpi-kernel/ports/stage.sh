#!/bin/bash
set -euo pipefail

build=$1
package=$2
member=$3
output=$4
build_id=$5
jinx=$(realpath ports/jinx)
output=$(realpath -m "$output")
cd "$build"

# Install into a fresh root so concurrent image builds cannot replace each
# other's packages or leave a partially staged executable behind.
stage=$(mktemp -d)
trap 'rm -rf "$stage" "${temporary:-}"' EXIT
"$jinx" update -b "$package"
"$jinx" install "$stage" "$package"
mkdir -p "$(dirname "$output")"
temporary=$(mktemp "$output.XXXXXX")
cp --preserve=mode "$stage/$member" "$temporary"
rm -f "$output.jinx-id"
mv -f "$temporary" "$output"
temporary=$(mktemp "$output.jinx-id.XXXXXX")
printf '%s\n' "$build_id" > "$temporary"
mv -f "$temporary" "$output.jinx-id"
