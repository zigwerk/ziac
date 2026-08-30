#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packager="$root/scripts/package_distribution.sh"
install_root="$root/packages/ziac/zig-out"

if [[ ! -x "$packager" ]]; then
  echo "distribution packager is missing or not executable: $packager" >&2
  exit 1
fi

output="$(mktemp -d)"
expanded="$(mktemp -d)"
trap 'rm -rf "$output" "$expanded"' EXIT

asset="$($packager 0.1.0 "$install_root" "$output")"
test -f "$asset"
tar -xzf "$asset" -C "$expanded"

prefix="$(find "$expanded" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test -x "$prefix/bin/ziac"
test -x "$prefix/bin/zigeffect"
test -d "$prefix/share/ziac/dashboard"
test -d "$prefix/share/zigeffect-std/src"
test -d "$prefix/share/zigeffect-cli/src"
test -d "$prefix/share/ziac-templates/templates"
test -f "${asset}.sha256"

echo "Ziac paired CLI distribution test passed."
