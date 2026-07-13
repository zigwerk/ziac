#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.bigquery-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_BIGQUERY_STACK:-analytics-warehouse}"
stage="${ZIAC_BIGQUERY_STAGE:-qualification}"
import_stage="${stage}-import"
location="${ZIAC_BIGQUERY_LOCATION:-EU}"

required=(
  ZIAC_BIGQUERY_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_BIGQUERY_DATASET
  ZIAC_BIGQUERY_TABLE
  ZIAC_BIGQUERY_VIEW
  ZIAC_BIGQUERY_ROUTINE
  ZIAC_BIGQUERY_PROBE_SQL
)
missing=()
for variable in "${required[@]}"; do
  if [[ -z "${!variable:-}" ]]; then missing+=("${variable}"); fi
done
for command in "${ziac_bin}" gcloud bq jq; do
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
phase="project_preflight"
on_error() {
  exit_code=$?
  printf '{"schema":"%s","status":"failed","authenticated":%s,"phase":"%s"}\n' "${schema}" "${authenticated}" "${phase}"
  exit "${exit_code}"
}
trap on_error ERR

phase="service_enablement"
gcloud services enable \
  bigquery.googleapis.com \
  bigqueryconnection.googleapis.com \
  bigqueryreservation.googleapis.com \
  --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_BIGQUERY_WORKSPACE}" && pwd)"
cd "${workspace}"
unset ZIAC_STATE_BUCKET
export ZIAC_GCP_PROJECT="${ZIAC_LIVE_PROJECT}"

phase="plan_apply"
mkdir -p .ziac/qualification
plan_path=".ziac/qualification/${stage}.plan.json"
plan_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --out "${plan_path}" --json)"
plan_digest="$(printf '%s' "${plan_receipt}" | jq -r '.plan_digest // empty')"
test -n "${plan_digest}"
if grep -Fq 'gcp.bigquery.CapacityCommitment' "${plan_path}"; then
  printf '{"schema":"%s","status":"failed","authenticated":true,"reason":"capacity_commitment_forbidden_in_qualification"}\n' "${schema}"
  exit 2
fi
"${ziac_bin}" deploy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --plan "${plan_path}" --approve "${plan_digest}" --json >/dev/null

state_file=".ziac/state/${stack}/${stage}/resources.json"
test -f "${state_file}"
resource_count="$(jq '.resources | length' "${state_file}")"
test "${resource_count}" -gt 0

phase="warehouse_probe"
bq show --project_id="${ZIAC_LIVE_PROJECT}" "${ZIAC_LIVE_PROJECT}:${ZIAC_BIGQUERY_DATASET}" >/dev/null
bq show --project_id="${ZIAC_LIVE_PROJECT}" "${ZIAC_LIVE_PROJECT}:${ZIAC_BIGQUERY_DATASET}.${ZIAC_BIGQUERY_TABLE}" >/dev/null
bq show --project_id="${ZIAC_LIVE_PROJECT}" "${ZIAC_LIVE_PROJECT}:${ZIAC_BIGQUERY_DATASET}.${ZIAC_BIGQUERY_VIEW}" >/dev/null
bq show --routine --project_id="${ZIAC_LIVE_PROJECT}" "${ZIAC_LIVE_PROJECT}:${ZIAC_BIGQUERY_DATASET}.${ZIAC_BIGQUERY_ROUTINE}" >/dev/null
bq query --project_id="${ZIAC_LIVE_PROJECT}" --location="${location}" --nouse_legacy_sql --format=json "${ZIAC_BIGQUERY_PROBE_SQL}" | jq -e 'type == "array"' >/dev/null

if [[ -n "${ZIAC_BIGQUERY_CONNECTION:-}" ]]; then
  phase="connection_probe"
  bq show --connection --location="${location}" --project_id="${ZIAC_LIVE_PROJECT}" "${ZIAC_BIGQUERY_CONNECTION}" >/dev/null
fi
if [[ -n "${ZIAC_BIGQUERY_RESERVATION:-}" ]]; then
  phase="reservation_probe"
  bq show --reservation --location="${location}" --project_id="${ZIAC_LIVE_PROJECT}" "${ZIAC_BIGQUERY_RESERVATION}" >/dev/null
fi

phase="second_state_import"
while IFS=$'\t' read -r resource_id physical_id; do
  test -n "${resource_id}"
  test -n "${physical_id}"
  "${ziac_bin}" import --stack "${stack}" --stage "${import_stage}" --provider gcp --allow-live --live-test \
    --resource "${resource_id}" --id "${physical_id}" --json >/dev/null
done < <(jq -r '.resources[] | select(.physical_id != null) | [.resource_id, .physical_id] | @tsv' "${state_file}")

import_plan=".ziac/qualification/${import_stage}.plan.json"
import_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${import_stage}" --provider gcp --allow-live --live-test --out "${import_plan}" --json)"
test "$(printf '%s' "${import_receipt}" | jq '.create + .update + .delete')" -eq 0
test "$(printf '%s' "${import_receipt}" | jq '.noop')" -eq "${resource_count}"

phase="retention_aware_destroy"
"${ziac_bin}" destroy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --confirm --json >/dev/null
bq show --project_id="${ZIAC_LIVE_PROJECT}" "${ZIAC_LIVE_PROJECT}:${ZIAC_BIGQUERY_DATASET}" >/dev/null

trap - ERR
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg graph_digest "${plan_digest}" \
  --argjson resources "${resource_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,query_probe:"observed",import_plan:"noop",retained_dataset:"present",cost_origin:"configuration_estimate"}'
