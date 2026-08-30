#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <version> <install-root> <output-directory>" >&2
  exit 64
fi

version="${1#v}"
install_root="$2"
output="$3"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "version must be a semantic version without a leading v" >&2
  exit 64
fi
for required in bin/ziac bin/zigeffect share/ziac share/zigeffect share/zigeffect-std share/zigeffect-cli; do
  if [[ ! -e "$install_root/$required" ]]; then
    echo "install root is missing $required" >&2
    exit 1
  fi
done

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *) echo "unsupported release operating system: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) echo "unsupported release architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$output"
output="$(cd "$output" && pwd)"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT
prefix="ziac-${version}-${os}-${arch}"
stage="$workspace/$prefix"
mkdir -p "$stage"
cp -R "$install_root/bin" "$stage/bin"
cp -R "$install_root/share" "$stage/share"

asset="$output/${prefix}.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$asset" -C "$workspace" "$prefix"
if command -v sha256sum >/dev/null 2>&1; then
  digest="$(sha256sum "$asset" | awk '{ print $1 }')"
else
  digest="$(shasum -a 256 "$asset" | awk '{ print $1 }')"
fi
printf '%s  %s\n' "$digest" "$(basename "$asset")" > "${asset}.sha256"
printf '%s\n' "$asset"
