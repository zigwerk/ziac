#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.monitoring-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_MONITORING_STACK:-monitoring}"
stage="${ZIAC_MONITORING_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_MONITORING_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_MONITORING_ENDPOINT
  ZIAC_MONITORING_SERVICE_RESOURCE
  ZIAC_MONITORING_SLO_RESOURCE
  ZIAC_MONITORING_UPTIME_RESOURCE
  ZIAC_MONITORING_ALERT_RESOURCE
  ZIAC_MONITORING_CHANNEL_RESOURCE
  ZIAC_MONITORING_DASHBOARD_RESOURCE
)
missing=()
for variable in "${required[@]}"; do
  if [[ -z "${!variable:-}" ]]; then missing+=("${variable}"); fi
done
for command in "${ziac_bin}" gcloud jq curl; do
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
token="$(gcloud auth application-default print-access-token 2>/dev/null || true)"
if [[ -z "${token}" ]]; then
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
gcloud services enable monitoring.googleapis.com --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_MONITORING_WORKSPACE}" && pwd)"
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
test "${resource_count}" -gt 0

physical_id() {
  jq -r --arg id "$1" '.resources[] | select(.resource_id == $id) | .physical_id // empty' "${state_file}"
}
monitoring_get() {
  curl --fail --silent --show-error \
    -H "Authorization: Bearer ${token}" \
    "https://monitoring.googleapis.com/$1" | jq -e '.name | length > 0' >/dev/null
}

phase="remote_object_probe"
monitoring_get "v3/$(physical_id "${ZIAC_MONITORING_SERVICE_RESOURCE}")"
monitoring_get "v3/$(physical_id "${ZIAC_MONITORING_SLO_RESOURCE}")"
monitoring_get "v3/$(physical_id "${ZIAC_MONITORING_UPTIME_RESOURCE}")"
monitoring_get "v3/$(physical_id "${ZIAC_MONITORING_ALERT_RESOURCE}")"
monitoring_get "v3/$(physical_id "${ZIAC_MONITORING_CHANNEL_RESOURCE}")"
monitoring_get "v1/$(physical_id "${ZIAC_MONITORING_DASHBOARD_RESOURCE}")"

phase="endpoint_probe"
curl --fail --silent --show-error --output .ziac/qualification/endpoint-response.txt "${ZIAC_MONITORING_ENDPOINT}"

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
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg graph_digest "${plan_digest}" \
  --argjson resources "${resource_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,objects:"observed",endpoint:"healthy",import_plan:"noop",cleanup:"deleted",cost_origin:"configuration_estimate",limitations:["alert_incident_not_forced","notification_delivery_not_forced","slo_window_not_elapsed"]}'
