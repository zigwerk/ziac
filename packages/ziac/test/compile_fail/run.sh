#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "${script_dir}/../.." && pwd)"
zigeffect_std_root="${1:?missing zigeffect_std source path}"
zigeffect_root="${2:?missing zigeffect source path}"
zig_bin="${ZIG:-zig}"
output_file="$(mktemp)"
trap 'rm -f "${output_file}"' EXIT

compile_fixture() {
  local fixture="$1"
  "${zig_bin}" build-obj \
    --dep ziac \
    -Mroot="${fixture}" \
    --dep zigeffect_std \
    -Mziac="${package_dir}/src/ziac.zig" \
    --dep zigeffect \
    -Mzigeffect_std="${zigeffect_std_root}" \
    -Mzigeffect="${zigeffect_root}" \
    -fno-emit-bin
}

for fixture in "${script_dir}"/invalid/*.zig; do
  expected_file="${fixture%.zig}.expected"
  expected_code="$(tr -d '[:space:]' < "${expected_file}")"
  if compile_fixture "${fixture}" >"${output_file}" 2>&1; then
    echo "expected compile failure: ${fixture}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected_code}" "${output_file}"; then
    echo "wrong diagnostic for ${fixture}; expected ${expected_code}" >&2
    cat "${output_file}" >&2
    exit 1
  fi
done

for fixture in "${script_dir}"/valid/*.zig; do
  if ! compile_fixture "${fixture}" >"${output_file}" 2>&1; then
    echo "valid compile fixture failed: ${fixture}" >&2
    cat "${output_file}" >&2
    exit 1
  fi
done
