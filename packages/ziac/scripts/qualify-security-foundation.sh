#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.security-foundation-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_SECURITY_STACK:-security-foundation}"
stage="${ZIAC_SECURITY_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_SECURITY_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_SECURITY_SCC_NOTIFICATION
  ZIAC_SECURITY_ATTESTOR
  ZIAC_SECURITY_CA_POOL
  ZIAC_SECURITY_CA_AUTHORITY
  ZIAC_SECURITY_DESTRUCTIVE_CONFIRMATION
)
missing=()
for variable in "${required[@]}"; do
  if [[ -z "${!variable:-}" ]]; then missing+=("${variable}"); fi
done
for command in "${ziac_bin}" gcloud curl jq; do
  if ! command -v "${command}" >/dev/null 2>&1; then missing+=("tool:${command}"); fi
done
if (( ${#missing[@]} > 0 )); then
  printf '{"schema":"%s","status":"skipped","authenticated":false,"reason":"missing_credentials_configuration_or_tools","missing":[' "${schema}"
  separator=""
  for item in "${missing[@]}"; do printf '%s"%s"' "${separator}" "${item}"; separator=","; done
  printf ']}\n'
  exit 77
fi
if [[ "${ZIAC_LIVE_PROJECT}" != *-ziac-disposable ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"project_is_not_disposable"}\n' "${schema}"
  exit 2
fi
if [[ "${ZIAC_SECURITY_DESTRUCTIVE_CONFIRMATION}" != "QUALIFY_DISPOSABLE_SECURITY_FOUNDATION" ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"destructive_confirmation_mismatch"}\n' "${schema}"
  exit 2
fi
for resource_name in "${ZIAC_SECURITY_ATTESTOR}" "${ZIAC_SECURITY_CA_POOL}" "${ZIAC_SECURITY_CA_AUTHORITY}"; do
  if [[ "${resource_name}" != projects/"${ZIAC_LIVE_PROJECT}"/* ]]; then
    printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"probe_resource_outside_disposable_project"}\n' "${schema}"
    exit 2
  fi
done
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '{"schema":"%s","status":"skipped","authenticated":false,"reason":"application_default_credentials_unavailable"}\n' "${schema}"
  exit 77
fi

phase="service_enablement"
on_error() {
  exit_code=$?
  printf '{"schema":"%s","status":"failed","authenticated":true,"phase":"%s"}\n' "${schema}" "${phase}"
  exit "${exit_code}"
}
trap on_error ERR

gcloud services enable securitycenter.googleapis.com binaryauthorization.googleapis.com privateca.googleapis.com containeranalysis.googleapis.com cloudasset.googleapis.com \
  --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_SECURITY_WORKSPACE}" && pwd)"
cd "${workspace}"
unset ZIAC_STATE_BUCKET
export ZIAC_GCP_PROJECT="${ZIAC_LIVE_PROJECT}"
mkdir -p .ziac/qualification

phase="plan_apply"
plan_path=".ziac/qualification/${stage}.plan.json"
plan_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --out "${plan_path}" --json)"
plan_digest="$(printf '%s' "${plan_receipt}" | jq -r '.plan_digest // empty')"
test -n "${plan_digest}"
"${ziac_bin}" deploy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --plan "${plan_path}" --approve "${plan_digest}" --json >/dev/null

state_file=".ziac/state/${stack}/${stage}/resources.json"
test -f "${state_file}"
resource_count="$(jq '.resources | length' "${state_file}")"
test "${resource_count}" -ge 9

phase="authenticated_probes"
access_token="$(gcloud auth application-default print-access-token)"
curl --fail --silent --show-error --output .ziac/qualification/scc-notification.json \
  --header "Authorization: Bearer ${access_token}" \
  "https://securitycenter.googleapis.com/v2/${ZIAC_SECURITY_SCC_NOTIFICATION}"
curl --fail --silent --show-error --output .ziac/qualification/binary-policy.json \
  --header "Authorization: Bearer ${access_token}" \
  "https://binaryauthorization.googleapis.com/v1/projects/${ZIAC_LIVE_PROJECT}/policy"
curl --fail --silent --show-error --output .ziac/qualification/attestor.json \
  --header "Authorization: Bearer ${access_token}" \
  "https://binaryauthorization.googleapis.com/v1/${ZIAC_SECURITY_ATTESTOR}"
curl --fail --silent --show-error --output .ziac/qualification/ca-pool.json \
  --header "Authorization: Bearer ${access_token}" \
  "https://privateca.googleapis.com/v1/${ZIAC_SECURITY_CA_POOL}"
curl --fail --silent --show-error --output .ziac/qualification/ca-authority.json \
  --header "Authorization: Bearer ${access_token}" \
  "https://privateca.googleapis.com/v1/${ZIAC_SECURITY_CA_AUTHORITY}"

phase="second_state_import"
while IFS=$'\t' read -r resource_id physical_id; do
  test -n "${resource_id}"
  test -n "${physical_id}"
  "${ziac_bin}" import --stack "${stack}" --stage "${import_stage}" --provider gcp --allow-live --live-test --resource "${resource_id}" --id "${physical_id}" --json >/dev/null
done < <(jq -r '.resources[] | select(.physical_id != null) | [.resource_id, .physical_id] | @tsv' "${state_file}")
import_plan=".ziac/qualification/${import_stage}.plan.json"
import_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${import_stage}" --provider gcp --allow-live --live-test --out "${import_plan}" --json)"
test "$(printf '%s' "${import_receipt}" | jq '.create + .update + .delete')" -eq 0
test "$(printf '%s' "${import_receipt}" | jq '.noop')" -eq "${resource_count}"

phase="retention_proof"
retained_count="$(jq '[.resources[] | select(.retain_on_delete == true)] | length' "${state_file}")"
test "${retained_count}" -gt 0

trap - ERR
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg graph_digest "${plan_digest}" \
  --argjson resources "${resource_count}" \
  --argjson retained "${retained_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,scc_probe:"reachable",binary_authorization_probe:"reachable",private_ca_probe:"reachable",import_plan:"noop",retained_resources:$retained,ca_state_actions:"excluded",certificate_revocation:"excluded",cleanup:"retained_for_explicit_operator_cleanup",cost_origin:"unavailable_without_observed_usage"}'
