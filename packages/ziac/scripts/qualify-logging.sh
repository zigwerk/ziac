#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.logging-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_LOGGING_STACK:-logging}"
stage="${ZIAC_LOGGING_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_LOGGING_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_LOGGING_BUCKET_RESOURCE
  ZIAC_LOGGING_VIEW_RESOURCE
  ZIAC_LOGGING_SINK_RESOURCE
  ZIAC_LOGGING_EXCLUSION_RESOURCE
  ZIAC_LOGGING_METRIC_RESOURCE
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
gcloud services enable logging.googleapis.com --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_LOGGING_WORKSPACE}" && pwd)"
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
logging_get() {
  curl --fail --silent --show-error \
    -H "Authorization: Bearer ${token}" \
    "https://logging.googleapis.com/v2/$1" | jq -e '.' >/dev/null
}

phase="remote_object_probe"
bucket_physical="$(physical_id "${ZIAC_LOGGING_BUCKET_RESOURCE}")"
logging_get "${bucket_physical}"
logging_get "$(physical_id "${ZIAC_LOGGING_VIEW_RESOURCE}")"
logging_get "$(physical_id "${ZIAC_LOGGING_SINK_RESOURCE}")"
logging_get "$(physical_id "${ZIAC_LOGGING_EXCLUSION_RESOURCE}")"
logging_get "$(physical_id "${ZIAC_LOGGING_METRIC_RESOURCE}")"

phase="route_probe"
probe_id="ziac-logging-$(date +%s)-$$"
gcloud logging write ziac-qualification "{\"probe_id\":\"${probe_id}\"}" --severity=NOTICE --project="${ZIAC_LIVE_PROJECT}" >/dev/null
routed=false
for _ in $(seq 1 18); do
  response="$(curl --fail --silent --show-error \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg bucket "${bucket_physical}" --arg id "${probe_id}" '{resourceNames:[$bucket],filter:("jsonPayload.probe_id=\\\""+$id+"\\\""),pageSize:1}')" \
    https://logging.googleapis.com/v2/entries:list)"
  if [[ "$(printf '%s' "${response}" | jq '.entries | length // 0')" -gt 0 ]]; then routed=true; break; fi
  sleep 5
done
test "${routed}" = true

phase="second_state_import"
while IFS=$'\t' read -r resource_id remote_id; do
  test -n "${resource_id}"
  test -n "${remote_id}"
  "${ziac_bin}" import --stack "${stack}" --stage "${import_stage}" --provider gcp --allow-live --live-test --resource "${resource_id}" --id "${remote_id}" --json >/dev/null
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
  --arg probe_id "${probe_id}" \
  --argjson resources "${resource_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,objects:"observed",route_probe:$probe_id,import_plan:"noop",cleanup:"deleted",cost_origin:"configuration_estimate",limitations:["retention_window_not_elapsed","billing_export_not_connected"]}'
