#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.kms-secret-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_KMS_SECRET_STACK:-kms-secret}"
stage="${ZIAC_KMS_SECRET_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_KMS_SECRET_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_KMS_LOCATION
  ZIAC_KMS_KEY_RING
  ZIAC_KMS_KEY
  ZIAC_SECRET_ID
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

gcloud services enable cloudkms.googleapis.com secretmanager.googleapis.com cloudasset.googleapis.com \
  --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_KMS_SECRET_WORKSPACE}" && pwd)"
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

phase="resource_probes"
gcloud kms keyrings describe "${ZIAC_KMS_KEY_RING}" --location="${ZIAC_KMS_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null
gcloud kms keys describe "${ZIAC_KMS_KEY}" --keyring="${ZIAC_KMS_KEY_RING}" --location="${ZIAC_KMS_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null
gcloud secrets describe "${ZIAC_SECRET_ID}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null

phase="reversible_transitions"
kms_version="$(gcloud kms keys versions list --key="${ZIAC_KMS_KEY}" --keyring="${ZIAC_KMS_KEY_RING}" --location="${ZIAC_KMS_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --sort-by='~name' --limit=1 --format='value(name.basename())')"
secret_version="$(gcloud secrets versions list "${ZIAC_SECRET_ID}" --project="${ZIAC_LIVE_PROJECT}" --sort-by='~name' --limit=1 --format='value(name.basename())')"
test -n "${kms_version}"
test -n "${secret_version}"
gcloud kms keys versions disable "${kms_version}" --key="${ZIAC_KMS_KEY}" --keyring="${ZIAC_KMS_KEY_RING}" --location="${ZIAC_KMS_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --quiet
gcloud kms keys versions enable "${kms_version}" --key="${ZIAC_KMS_KEY}" --keyring="${ZIAC_KMS_KEY_RING}" --location="${ZIAC_KMS_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --quiet
gcloud secrets versions disable "${secret_version}" --secret="${ZIAC_SECRET_ID}" --project="${ZIAC_LIVE_PROJECT}" --quiet
gcloud secrets versions enable "${secret_version}" --secret="${ZIAC_SECRET_ID}" --project="${ZIAC_LIVE_PROJECT}" --quiet

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

phase="retention_plan"
retained_count="$(jq '[.resources[] | select(.retain_on_delete == true)] | length' "${state_file}")"
test "${retained_count}" -ge 4

trap - ERR
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg graph_digest "${plan_digest}" \
  --argjson resources "${resource_count}" \
  --argjson retained "${retained_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,key_ring:"reachable",crypto_key:"reachable",secret:"reachable",reversible_transitions:["kms_disable_enable","secret_disable_enable"],import_plan:"noop",retained_resources:$retained,irreversible_actions:"excluded",cleanup:"delete_disposable_project",cost_origin:"configuration_estimate"}'
