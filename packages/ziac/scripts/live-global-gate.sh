#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ziac_bin="${package_dir}/zig-out/bin/ziac"
stage="${ZIAC_LIVE_STAGE:-global-smoke}"
readiness_timeout="${ZIAC_LIVE_READINESS_TIMEOUT_SECONDS:-2400}"

required=(
  ZIAC_LIVE_PROJECT
  ZIAC_LIVE_IMAGE
  ZIAC_LIVE_REGIONS
  ZIAC_LIVE_DOMAIN
  ZIAC_LIVE_DNS_ZONE
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'missing required environment variable: %s\n' "${name}" >&2
    exit 2
  fi
done

if [[ "${ZIAC_LIVE_PROJECT}" != *-ziac-disposable ]]; then
  printf 'ZIAC_LIVE_PROJECT must end in -ziac-disposable\n' >&2
  exit 2
fi

IFS=',' read -r -a regions <<<"${ZIAC_LIVE_REGIONS}"
if (( ${#regions[@]} < 2 )); then
  printf 'ZIAC_LIVE_REGIONS must contain at least two regions\n' >&2
  exit 2
fi
failed_region="${ZIAC_LIVE_FAIL_REGION:-${regions[0]}}"

common=(
  --stack global-container
  --stage "${stage}"
  --provider gcp
  --allow-live
  --live-test
)

cleanup_enabled=0
cleanup() {
  if (( cleanup_enabled == 1 )); then
    "${ziac_bin}" destroy "${common[@]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

wait_https() {
  local url="$1"
  local deadline=$((SECONDS + readiness_timeout))
  until curl --silent --show-error --fail --max-time 20 "${url}" >/dev/null; do
    if (( SECONDS >= deadline )); then
      printf 'timed out waiting for %s\n' "${url}" >&2
      return 1
    fi
    sleep 10
  done
}

run_remote_probes() {
  local probes="${ZIAC_LIVE_REMOTE_PROBES:-}"
  [[ -z "${probes}" ]] && return 0
  local probe
  IFS=',' read -r -a probe_urls <<<"${probes}"
  for probe in "${probe_urls[@]}"; do
    curl --silent --show-error --fail --max-time 30 "${probe}" >/dev/null
  done
}

cd "${package_dir}"
zig build
cleanup_enabled=1

"${ziac_bin}" deploy "${common[@]}"
global_url="https://${ZIAC_LIVE_DOMAIN}"
wait_https "${global_url}"
run_remote_probes

outputs="$(${ziac_bin} outputs --stack global-container --stage "${stage}")"
regional_key="service_url_${failed_region}"
regional_url="$(printf '%s\n' "${outputs}" | awk -F= -v key="${regional_key}" '$1 == key { print $2 }')"
if [[ -z "${regional_url}" ]]; then
  printf 'missing regional service output: %s\n' "${regional_key}" >&2
  exit 1
fi
if curl --silent --show-error --fail --max-time 20 "${regional_url}" >/dev/null 2>&1; then
  printf 'direct run.app ingress unexpectedly succeeded: %s\n' "${regional_url}" >&2
  exit 1
fi

"${ziac_bin}" fail-region "${common[@]}" --region "${failed_region}"
wait_https "${global_url}"
run_remote_probes

"${ziac_bin}" refresh "${common[@]}"
"${ziac_bin}" deploy "${common[@]}"
wait_https "${global_url}"
run_remote_probes

plan_output="$(${ziac_bin} plan "${common[@]}")"
if ! grep -Fq 'Plan: 0 create, 0 update, 0 delete, 14 noop' <<<"${plan_output}"; then
  printf 'restored stack did not plan noop:\n%s\n' "${plan_output}" >&2
  exit 1
fi

if [[ -n "${ZIAC_LIVE_SECRET_SENTINEL:-}" ]] &&
  grep -R -Fq "${ZIAC_LIVE_SECRET_SENTINEL}" "${package_dir}/.ziac/state/global-container/${stage}"; then
  printf 'secret sentinel found in Ziac state artifacts\n' >&2
  exit 1
fi

"${ziac_bin}" destroy "${common[@]}"
cleanup_enabled=0
trap - EXIT INT TERM
printf 'Ziac global live gate passed for %s with regional failure in %s\n' "${global_url}" "${failed_region}"
