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

package_key=$("$jinx" local-package-key "$package")
artifact_key="$package_key $package $member"
if [[ -f "$output" && -f "$output.jinx-id" &&
      $(sed -n '2p' "$output.jinx-id") == "$artifact_key" ]]; then
    temporary=$(mktemp "$output.jinx-id.XXXXXX")
    trap 'rm -f "$temporary"' EXIT
    printf '%s\n' "$build_id" "$artifact_key" > "$temporary"
    mv -f "$temporary" "$output.jinx-id"
    exit 0
fi

# Install into a fresh root so concurrent image builds cannot replace each
# other's packages or leave a partially staged executable behind.
stage=$(mktemp -d)
trap 'rm -rf "$stage" "${temporary:-}"' EXIT
"$jinx" update -b "$package"
"$jinx" install "$stage" "$package"
mkdir -p "$(dirname "$output")"
if ! cmp -s "$stage/$member" "$output" ||
   [[ $(stat -c %a -- "$stage/$member") != $(stat -c %a -- "$output") ]]; then
    temporary=$(mktemp "$output.XXXXXX")
    cp --preserve=mode "$stage/$member" "$temporary"
    rm -f "$output.jinx-id"
    mv -f "$temporary" "$output"
fi
temporary=$(mktemp "$output.jinx-id.XXXXXX")
printf '%s\n' "$build_id" "$artifact_key" > "$temporary"
mv -f "$temporary" "$output.jinx-id"
