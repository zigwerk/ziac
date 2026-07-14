#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.governance-boundary-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_GOVERNANCE_STACK:-governance-boundary}"
stage="${ZIAC_GOVERNANCE_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_GOVERNANCE_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_LIVE_ORGANIZATION
  ZIAC_GOVERNANCE_DISPOSABLE_SCOPE
  ZIAC_GOVERNANCE_POLICY_CONSTRAINT
  ZIAC_GOVERNANCE_TAG_VALUE
  ZIAC_GOVERNANCE_ACCESS_POLICY
  ZIAC_GOVERNANCE_PERIMETER
  ZIAC_GOVERNANCE_DESTRUCTIVE_CONFIRMATION
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
if [[ "${ZIAC_LIVE_PROJECT}" != *-ziac-disposable ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"project_is_not_disposable"}\n' "${schema}"
  exit 2
fi
if [[ "${ZIAC_GOVERNANCE_DISPOSABLE_SCOPE}" != "projects/${ZIAC_LIVE_PROJECT}" && "${ZIAC_GOVERNANCE_DISPOSABLE_SCOPE}" != folders/* ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"governance_scope_is_not_explicitly_disposable"}\n' "${schema}"
  exit 2
fi
if [[ "${ZIAC_GOVERNANCE_DESTRUCTIVE_CONFIRMATION}" != "QUALIFY_DISPOSABLE_GOVERNANCE_SCOPE" ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"destructive_confirmation_mismatch"}\n' "${schema}"
  exit 2
fi
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

gcloud services enable orgpolicy.googleapis.com cloudresourcemanager.googleapis.com accesscontextmanager.googleapis.com cloudasset.googleapis.com \
  --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_GOVERNANCE_WORKSPACE}" && pwd)"
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
test "${resource_count}" -ge 3

phase="resource_probes"
gcloud resource-manager org-policies describe "${ZIAC_GOVERNANCE_POLICY_CONSTRAINT}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null
gcloud resource-manager tags bindings list --parent="//cloudresourcemanager.googleapis.com/projects/$(gcloud projects describe "${ZIAC_LIVE_PROJECT}" --format='value(projectNumber)')" --format=json | jq -e --arg value "${ZIAC_GOVERNANCE_TAG_VALUE}" 'map(select(.tagValue == $value)) | length > 0' >/dev/null
gcloud access-context-manager perimeters describe "${ZIAC_GOVERNANCE_PERIMETER}" --policy="${ZIAC_GOVERNANCE_ACCESS_POLICY#accessPolicies/}" --format=json >/dev/null

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
test "${retained_count}" -eq "${resource_count}"

trap - ERR
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg organization "${ZIAC_LIVE_ORGANIZATION}" \
  --arg scope "${ZIAC_GOVERNANCE_DISPOSABLE_SCOPE}" \
  --arg graph_digest "${plan_digest}" \
  --argjson resources "${resource_count}" \
  --argjson retained "${retained_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,organization:$organization,scope:$scope,graph_digest:$graph_digest,resource_count:$resources,policy_probe:"reachable",tag_binding_probe:"reachable",perimeter_probe:"reachable",import_plan:"noop",retained_resources:$retained,destructive_actions:"excluded",cleanup:"retained_for_explicit_operator_cleanup",cost_origin:"configuration_estimate",management_cost_micros:0}'
