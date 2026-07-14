#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.organization-foundation-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_ORGANIZATION_STACK:-project-foundation}"
stage="${ZIAC_ORGANIZATION_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_ORGANIZATION_WORKSPACE
  ZIAC_LIVE_ORGANIZATION
  ZIAC_LIVE_BILLING_ACCOUNT
  ZIAC_FOUNDATION_PROJECT_ID
  ZIAC_ORGANIZATION_DESTRUCTIVE_CONFIRMATION
)
missing=()
for variable in "${required[@]}"; do
  if [[ -z "${!variable:-}" ]]; then missing+=("${variable}"); fi
done
for command in "${ziac_bin}" gcloud jq; do
  if ! command -v "${command}" >/dev/null 2>&1; then missing+=("tool:${command}"); fi
done
if (( ${#missing[@]} > 0 )); then
  printf '{"schema":"%s","status":"skipped","authenticated":false,"reason":"missing_credentials_configuration_or_tools","missing":[' "${schema}"
  separator=""
  for item in "${missing[@]}"; do printf '%s"%s"' "${separator}" "${item}"; separator=","; done
  printf ']}\n'
  exit 77
fi
if [[ "${ZIAC_FOUNDATION_PROJECT_ID}" != *-ziac-disposable ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"project_is_not_disposable"}\n' "${schema}"
  exit 2
fi
if [[ "${ZIAC_ORGANIZATION_DESTRUCTIVE_CONFIRMATION}" != "DELETE_DISPOSABLE_PROJECT" ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"destructive_confirmation_mismatch"}\n' "${schema}"
  exit 2
fi
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '{"schema":"%s","status":"skipped","authenticated":false,"reason":"application_default_credentials_unavailable"}\n' "${schema}"
  exit 77
fi

phase="plan_apply"
on_error() {
  exit_code=$?
  printf '{"schema":"%s","status":"failed","authenticated":true,"phase":"%s"}\n' "${schema}" "${phase}"
  exit "${exit_code}"
}
trap on_error ERR

workspace="$(cd "${ZIAC_ORGANIZATION_WORKSPACE}" && pwd)"
cd "${workspace}"
unset ZIAC_STATE_BUCKET
export ZIAC_GCP_PROJECT="${ZIAC_FOUNDATION_PROJECT_ID}"
mkdir -p .ziac/qualification

plan_path=".ziac/qualification/${stage}.plan.json"
plan_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --out "${plan_path}" --json)"
plan_digest="$(printf '%s' "${plan_receipt}" | jq -r '.plan_digest // empty')"
test -n "${plan_digest}"
"${ziac_bin}" deploy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --plan "${plan_path}" --approve "${plan_digest}" --json >/dev/null

state_file=".ziac/state/${stack}/${stage}/resources.json"
test -f "${state_file}"
resource_count="$(jq '.resources | length' "${state_file}")"
test "${resource_count}" -ge 5

phase="resource_probes"
gcloud projects describe "${ZIAC_FOUNDATION_PROJECT_ID}" --format=json >/dev/null
billing_enabled="$(gcloud billing projects describe "${ZIAC_FOUNDATION_PROJECT_ID}" --format='value(billingEnabled)')"
test "${billing_enabled}" = "True"

phase="second_state_import"
while IFS=$'\t' read -r resource_id physical_id; do
  test -n "${resource_id}"
  test -n "${physical_id}"
  "${ziac_bin}" import --stack "${stack}" --stage "${import_stage}" --provider gcp --allow-live --live-test --resource "${resource_id}" --id "${physical_id}" --json >/dev/null
done < <(jq -r '.resources[] | select(.physical_id != null) | [.resource_id, .physical_id] | @tsv' "${state_file}")
import_plan=".ziac/qualification/${import_stage}.plan.json"
import_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${import_stage}" --provider gcp --allow-live --live-test --out "${import_plan}" --json)"
test "$(printf '%s' "${import_receipt}" | jq '.create + .update + .delete')" -eq 0

phase="explicit_cleanup"
gcloud projects delete "${ZIAC_FOUNDATION_PROJECT_ID}" --quiet

trap - ERR
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_FOUNDATION_PROJECT_ID}" \
  --arg organization "${ZIAC_LIVE_ORGANIZATION}" \
  --arg billing_account "${ZIAC_LIVE_BILLING_ACCOUNT}" \
  --arg graph_digest "${plan_digest}" \
  --argjson resources "${resource_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,organization:$organization,billing_account:$billing_account,graph_digest:$graph_digest,resource_count:$resources,project_probe:"reachable",billing_probe:"enabled",import_plan:"noop",cleanup:"explicit_project_delete",cost_origin:"configuration_estimate",management_cost_micros:0}'
