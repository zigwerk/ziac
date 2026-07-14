#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.data-services-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_DATA_SERVICES_STACK:-data-services-platform}"
stage="${ZIAC_DATA_SERVICES_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_DATA_SERVICES_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_SPANNER_INSTANCE
  ZIAC_SPANNER_DATABASE
  ZIAC_REDIS_INSTANCE
  ZIAC_REDIS_AUTH_SECRET
)
missing=()
for variable in "${required[@]}"; do
  if [[ -z "${!variable:-}" ]]; then missing+=("${variable}"); fi
done
for command in "${ziac_bin}" gcloud curl jq redis-cli; do
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
  unset REDISCLI_AUTH || true
  printf '{"schema":"%s","status":"failed","authenticated":%s,"phase":"%s"}\n' "${schema}" "${authenticated}" "${phase}"
  exit "${exit_code}"
}
trap on_error ERR

gcloud services enable spanner.googleapis.com redis.googleapis.com servicenetworking.googleapis.com compute.googleapis.com secretmanager.googleapis.com --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_DATA_SERVICES_WORKSPACE}" && pwd)"
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

phase="spanner_sql_probe"
test "$(gcloud spanner databases execute-sql "${ZIAC_SPANNER_DATABASE}" --instance="${ZIAC_SPANNER_INSTANCE}" --project="${ZIAC_LIVE_PROJECT}" --sql='SELECT 1' --format='value(1)')" = "1"

phase="redis_ping_probe"
token="$(gcloud auth application-default print-access-token)"
redis_path="projects/${ZIAC_LIVE_PROJECT}/locations/${ZIAC_REDIS_LOCATION:-europe-west1}/instances/${ZIAC_REDIS_INSTANCE}"
redis_json="$(curl -fsS -H "Authorization: Bearer ${token}" "https://redis.googleapis.com/v1/${redis_path}")"
redis_host="$(printf '%s' "${redis_json}" | jq -r '.host // empty')"
redis_port="$(printf '%s' "${redis_json}" | jq -r '.port // empty')"
test -n "${redis_host}"
test -n "${redis_port}"
export REDISCLI_AUTH="$(gcloud secrets versions access latest --project="${ZIAC_LIVE_PROJECT}" --secret="${ZIAC_REDIS_AUTH_SECRET}")"
test "$(redis-cli --tls -h "${redis_host}" -p "${redis_port}" --no-auth-warning PING)" = "PONG"
unset REDISCLI_AUTH

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
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,spanner_probe:"sql",redis_probe:"pong",import_plan:"noop",cleanup:"deleted",cost_origin:"configuration_estimate"}'
