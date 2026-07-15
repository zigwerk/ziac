#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "${package_dir}/../.." && pwd)"

required=(
  "README.md"
  "docs/architecture.md"
  "docs/authentication.md"
  "docs/hermes-compute.md"
  "docs/keyless-ci.md"
  "docs/live-gcp.md"
  "docs/remote-state.md"
  "docs/rollouts-recovery.md"
  "examples/production_global_service.zig"
  "examples/hermes_compute.zig"
  "release/live-tests.json"
  "proto/googleapis.lock.json"
  "proto/cloud-run-v2.contract.json"
  "src/gcp/generated/cloud-run-v2.pb"
  "scripts/live-global-gate.sh"
  "scripts/hermes-compute-startup.sh"
  "scripts/qualify-hermes-compute.sh"
)
for path in "${required[@]}"; do
  if [[ ! -f "${package_dir}/${path}" ]]; then
    printf 'release gate missing required file: %s\n' "${path}" >&2
    exit 1
  fi
done

descriptor_hash="$(shasum -a 256 "${package_dir}/src/gcp/generated/cloud-run-v2.pb" | awk '{print $1}')"
if [[ "${descriptor_hash}" != "b782942487e0e305651bf83c5f211f132e4b29e3bedcdf15a83b478df6a8b722" ]]; then
  printf 'release gate found a Google descriptor lock mismatch\n' >&2
  exit 1
fi
snapshot_hash="$(shasum -a 256 "${package_dir}/proto/cloud-run-v2.contract.json" | awk '{print $1}')"
if [[ "${snapshot_hash}" != "f4f0ca51afa49e9412d484cf3d10281519c21fdbf7e332dbe8aaf5f930d0baff" ]]; then
  printf 'release gate found a generated Google semantic snapshot mismatch\n' >&2
  exit 1
fi

if find "${package_dir}" -type f -name 'gha-creds-*.json' -print -quit | grep -q .; then
  printf 'release gate found a generated GitHub credential file\n' >&2
  exit 1
fi

while IFS= read -r path; do
  case "${path}" in
    packages/ziac/src/gcp/auth/rsa.zig|packages/ziac/test/fixtures/gcp/service_account.json|packages/ziac/scripts/release-checks.sh)
      continue
      ;;
  esac
  if grep -Eq -- '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|"private_key"[[:space:]]*:' "${repo_root}/${path}"; then
    printf 'release gate found private-key material in %s\n' "${path}" >&2
    exit 1
  fi
done < <(git -C "${repo_root}" ls-files 'packages/ziac')

artifact_dirs=("${package_dir}/.ziac" "${package_dir}/release-evidence")
sentinels=("sentinel-secret-for-tests" "sentinel-cockroach-key" "dummy-cockroach-secret-key")
if [[ -n "${ZIAC_RELEASE_SECRET_SENTINEL:-}" ]]; then
  sentinels+=("${ZIAC_RELEASE_SECRET_SENTINEL}")
fi
for directory in "${artifact_dirs[@]}"; do
  [[ -d "${directory}" ]] || continue
  for sentinel in "${sentinels[@]}"; do
    if grep -R -Fq -- "${sentinel}" "${directory}"; then
      printf 'release gate found a secret sentinel in %s\n' "${directory}" >&2
      exit 1
    fi
  done
done

printf 'Ziac release static and secret checks passed\n'
