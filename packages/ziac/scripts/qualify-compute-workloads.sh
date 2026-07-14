#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.compute-workloads-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_COMPUTE_WORKLOADS_STACK:-compute-workloads}"
stage="${ZIAC_COMPUTE_WORKLOADS_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_COMPUTE_WORKLOADS_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_COMPUTE_REGION
  ZIAC_COMPUTE_TEMPLATE
  ZIAC_COMPUTE_GROUP
  ZIAC_COMPUTE_AUTOSCALER
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

authenticated=true
phase="service_enablement"
on_error() {
  exit_code=$?
  printf '{"schema":"%s","status":"failed","authenticated":%s,"phase":"%s"}\n' "${schema}" "${authenticated}" "${phase}"
  exit "${exit_code}"
}
trap on_error ERR

gcloud services enable compute.googleapis.com iam.googleapis.com --project="${ZIAC_LIVE_PROJECT}" --quiet
workspace="$(cd "${ZIAC_COMPUTE_WORKLOADS_WORKSPACE}" && pwd)"
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

phase="compute_probes"
gcloud compute instance-templates describe "${ZIAC_COMPUTE_TEMPLATE}" --project="${ZIAC_LIVE_PROJECT}" --format='value(name)' | grep -Fx "${ZIAC_COMPUTE_TEMPLATE}" >/dev/null
gcloud compute instance-groups managed describe "${ZIAC_COMPUTE_GROUP}" --region="${ZIAC_COMPUTE_REGION}" --project="${ZIAC_LIVE_PROJECT}" --format='value(status.isStable)' | grep -Fx True >/dev/null
gcloud compute autoscalers describe "${ZIAC_COMPUTE_AUTOSCALER}" --region="${ZIAC_COMPUTE_REGION}" --project="${ZIAC_LIVE_PROJECT}" --format='value(name)' | grep -Fx "${ZIAC_COMPUTE_AUTOSCALER}" >/dev/null

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
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,template_probe:"read",group_probe:"stable",autoscaler_probe:"read",import_plan:"noop",cleanup:"deleted",cost_origin:"configuration_estimate"}'
