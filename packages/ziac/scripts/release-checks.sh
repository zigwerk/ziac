#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "${package_dir}/../.." && pwd)"

required=(
  "README.md"
  "docs/architecture.md"
  "docs/authentication.md"
  "docs/keyless-ci.md"
  "docs/live-gcp.md"
  "docs/remote-state.md"
  "docs/rollouts-recovery.md"
  "examples/production_global_service.zig"
  "release/live-tests.json"
  "scripts/live-global-gate.sh"
)
for path in "${required[@]}"; do
  if [[ ! -f "${package_dir}/${path}" ]]; then
    printf 'release gate missing required file: %s\n' "${path}" >&2
    exit 1
  fi
done

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
