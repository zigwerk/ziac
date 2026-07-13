#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.cloud-sql-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_CLOUD_SQL_STACK:-managed-postgres}"
stage="${ZIAC_CLOUD_SQL_STAGE:-qualification}"
import_stage="${stage}-import"
proxy_pid=""

required=(
  ZIAC_CLOUD_SQL_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_CLOUD_SQL_INSTANCE
  ZIAC_CLOUD_SQL_DATABASE
  ZIAC_CLOUD_SQL_USER
  ZIAC_CLOUD_SQL_PASSWORD_SECRET
)
missing=()
for variable in "${required[@]}"; do
  if [[ -z "${!variable:-}" ]]; then missing+=("${variable}"); fi
done
for command in "${ziac_bin}" gcloud curl jq cloud-sql-proxy psql; do
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
stop_proxy() {
  if [[ -n "${proxy_pid}" ]]; then
    kill "${proxy_pid}" >/dev/null 2>&1 || true
    wait "${proxy_pid}" >/dev/null 2>&1 || true
    proxy_pid=""
  fi
}
on_error() {
  exit_code=$?
  stop_proxy
  unset PGPASSWORD || true
  printf '{"schema":"%s","status":"failed","authenticated":%s,"phase":"%s"}\n' "${schema}" "${authenticated}" "${phase}"
  exit "${exit_code}"
}
trap on_error ERR

phase="service_enablement"
gcloud services enable sqladmin.googleapis.com secretmanager.googleapis.com --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_CLOUD_SQL_WORKSPACE}" && pwd)"
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

phase="sql_admin_probe"
token="$(gcloud auth application-default print-access-token)"
api="https://sqladmin.googleapis.com/v1/projects/${ZIAC_LIVE_PROJECT}/instances/${ZIAC_CLOUD_SQL_INSTANCE}"
instance_json="$(curl -fsS -H "Authorization: Bearer ${token}" "${api}")"
connection_name="$(printf '%s' "${instance_json}" | jq -r '.connectionName // empty')"
test -n "${connection_name}"
printf '%s' "${instance_json}" | jq -e '.state == "RUNNABLE"' >/dev/null
curl -fsS -H "Authorization: Bearer ${token}" "${api}/databases" | jq -e '.items // [] | type == "array"' >/dev/null
curl -fsS -H "Authorization: Bearer ${token}" "${api}/users" | jq -e '.items // [] | type == "array"' >/dev/null
curl -fsS -H "Authorization: Bearer ${token}" "${api}/sslCerts" | jq -e '.items // [] | type == "array"' >/dev/null

phase="postgres_connection_probe"
proxy_port="${ZIAC_CLOUD_SQL_PROXY_PORT:-55432}"
cloud-sql-proxy --address 127.0.0.1 --port "${proxy_port}" "${connection_name}" >.ziac/qualification/cloud-sql-proxy.log 2>&1 &
proxy_pid=$!
export PGPASSWORD="$(gcloud secrets versions access latest --project="${ZIAC_LIVE_PROJECT}" --secret="${ZIAC_CLOUD_SQL_PASSWORD_SECRET}")"
connected=false
for _ in $(seq 1 30); do
  if psql "host=127.0.0.1 port=${proxy_port} dbname=${ZIAC_CLOUD_SQL_DATABASE} user=${ZIAC_CLOUD_SQL_USER} sslmode=disable connect_timeout=2" --no-psqlrc --tuples-only --command 'SELECT 1' >/dev/null 2>&1; then
    connected=true
    break
  fi
  sleep 2
done
unset PGPASSWORD
stop_proxy
test "${connected}" = true

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

phase="destructive_cleanup"
if [[ "$(jq '[.resources[] | select(.protect == true or .retain_on_delete == true)] | length' "${state_file}")" -ne 0 ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":true,"reason":"qualification_stack_is_not_cleanup_enabled"}\n' "${schema}"
  exit 2
fi
"${ziac_bin}" destroy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --confirm --json >/dev/null
if gcloud sql instances describe "${ZIAC_CLOUD_SQL_INSTANCE}" --project="${ZIAC_LIVE_PROJECT}" >/dev/null 2>&1; then
  printf '{"schema":"%s","status":"failed","authenticated":true,"reason":"instance_remained_after_cleanup"}\n' "${schema}"
  exit 2
fi

trap - ERR
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg graph_digest "${plan_digest}" \
  --argjson resources "${resource_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,admin_probe:"observed",postgres_probe:"connected",import_plan:"noop",cleanup:"deleted",cost_origin:"configuration_estimate"}'
