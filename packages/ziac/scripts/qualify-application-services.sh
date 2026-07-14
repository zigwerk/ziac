#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.application-services-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_APPLICATION_SERVICES_STACK:-application-services}"
stage="${ZIAC_APPLICATION_SERVICES_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_APPLICATION_SERVICES_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_WORKFLOW_NAME
  ZIAC_API_GATEWAY_NAME
  ZIAC_IDENTITY_TENANT
  ZIAC_PARAMETER_NAME
  ZIAC_PARAMETER_VERSION
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
  for item in "${missing[@]}"; do
    printf '%s"%s"' "${separator}" "${item}"
    separator=","
  done
  printf ']}\n'
  exit 77
fi

if [[ "${ZIAC_LIVE_PROJECT}" != *-ziac-disposable ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"project_is_not_disposable"}\n' "${schema}"
  exit 2
fi
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '{"schema":"%s","status":"skipped","authenticated":false,"reason":"application_default_credentials_unavailable"}\n' "${schema}"
  exit 77
fi

authenticated=true
phase="service_enablement"
on_error() {
  exit_code=$?
  printf '{"schema":"%s","status":"failed","authenticated":%s,"phase":"%s"}\n' "${schema}" "${authenticated}" "${phase}"
  exit "${exit_code}"
}
trap on_error ERR

gcloud services enable workflows.googleapis.com apigateway.googleapis.com identitytoolkit.googleapis.com parametermanager.googleapis.com iam.googleapis.com --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_APPLICATION_SERVICES_WORKSPACE}" && pwd)"
cd "${workspace}"
unset ZIAC_STATE_BUCKET
export ZIAC_GCP_PROJECT="${ZIAC_LIVE_PROJECT}"

phase="plan_apply"
mkdir -p .ziac/qualification
plan_path=".ziac/qualification/${stage}.plan.json"
plan_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --out "${plan_path}" --json)"
plan_digest="$(printf '%s' "${plan_receipt}" | jq -r '.plan_digest // empty')"
test -n "${plan_digest}"
"${ziac_bin}" deploy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --plan "${plan_path}" --approve "${plan_digest}" --json >/dev/null

state_file=".ziac/state/${stack}/${stage}/resources.json"
test -f "${state_file}"
resource_count="$(jq '.resources | length' "${state_file}")"
test "${resource_count}" -gt 0
token="$(gcloud auth application-default print-access-token)"
location="${ZIAC_APPLICATION_SERVICES_LOCATION:-europe-west1}"

phase="workflow_probe"
curl -fsS -H "Authorization: Bearer ${token}" "https://workflows.googleapis.com/v1/projects/${ZIAC_LIVE_PROJECT}/locations/${location}/workflows/${ZIAC_WORKFLOW_NAME}" | jq -e '.state == "ACTIVE"' >/dev/null

phase="gateway_probe"
curl -fsS -H "Authorization: Bearer ${token}" "https://apigateway.googleapis.com/v1/projects/${ZIAC_LIVE_PROJECT}/locations/${location}/gateways/${ZIAC_API_GATEWAY_NAME}" | jq -e '.state == "ACTIVE" and (.defaultHostname | length > 0)' >/dev/null

phase="identity_probe"
curl -fsS -H "Authorization: Bearer ${token}" "https://identitytoolkit.googleapis.com/v2/projects/${ZIAC_LIVE_PROJECT}/tenants/${ZIAC_IDENTITY_TENANT}" | jq -e '.name | length > 0' >/dev/null

phase="parameter_probe"
curl -fsS -H "Authorization: Bearer ${token}" "https://parametermanager.googleapis.com/v1/projects/${ZIAC_LIVE_PROJECT}/locations/global/parameters/${ZIAC_PARAMETER_NAME}/versions/${ZIAC_PARAMETER_VERSION}:render" | jq -e '.renderedPayload | length > 0' >/dev/null

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

phase="destructive_cleanup"
if [[ "$(jq '[.resources[] | select(.protect == true or .retain_on_delete == true)] | length' "${state_file}")" -ne 0 ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":true,"reason":"qualification_stack_is_not_cleanup_enabled"}\n' "${schema}"
  exit 2
fi
"${ziac_bin}" destroy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --confirm --json >/dev/null

trap - ERR
jq -cn --arg schema "${schema}" --arg project "${ZIAC_LIVE_PROJECT}" --arg graph_digest "${plan_digest}" --argjson resources "${resource_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,workflow_probe:"active",gateway_probe:"active",identity_probe:"read",parameter_probe:"rendered",import_plan:"noop",cleanup:"deleted",cost_origin:"configuration_estimate"}'
