#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.cloud-deploy-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_CLOUD_DEPLOY_STACK:-cloud-deploy}"
stage="${ZIAC_CLOUD_DEPLOY_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_CLOUD_DEPLOY_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_CLOUD_DEPLOY_LOCATION
  ZIAC_CLOUD_DEPLOY_PIPELINE
  ZIAC_CLOUD_DEPLOY_TARGET
  ZIAC_CLOUD_DEPLOY_RELEASE
  ZIAC_CLOUD_DEPLOY_SKAFFOLD_FILE
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

workspace="$(cd "${ZIAC_CLOUD_DEPLOY_WORKSPACE}" && pwd)"
skaffold_file="${workspace}/${ZIAC_CLOUD_DEPLOY_SKAFFOLD_FILE}"
if [[ ! -f "${skaffold_file}" ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":true,"reason":"skaffold_file_missing"}\n' "${schema}"
  exit 2
fi

phase="service_enablement"
applied=false
pipeline_has_release=false
cleanup_safe=false
cleanup() {
  if [[ "${pipeline_has_release}" = true ]]; then
    gcloud deploy delivery-pipelines delete "${ZIAC_CLOUD_DEPLOY_PIPELINE}" \
      --region="${ZIAC_CLOUD_DEPLOY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --force --quiet >/dev/null 2>&1 || true
    pipeline_has_release=false
  fi
  if [[ "${applied}" = true && "${cleanup_safe}" = true ]]; then
    "${ziac_bin}" destroy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --confirm --json >/dev/null 2>&1 || true
    applied=false
  fi
}
on_exit() {
  exit_code=$?
  if (( exit_code != 0 )); then cleanup; fi
  if (( exit_code != 0 )); then
    printf '{"schema":"%s","status":"failed","authenticated":true,"phase":"%s"}\n' "${schema}" "${phase}"
  fi
  exit "${exit_code}"
}
trap on_exit EXIT

gcloud services enable clouddeploy.googleapis.com cloudbuild.googleapis.com storage.googleapis.com iam.googleapis.com \
  --project="${ZIAC_LIVE_PROJECT}" --quiet

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
applied=true

state_file=".ziac/state/${stack}/${stage}/resources.json"
test -f "${state_file}"
resource_count="$(jq '.resources | length' "${state_file}")"
test "${resource_count}" -gt 0
if [[ "$(jq '[.resources[] | select(.protect == true or .retain_on_delete == true)] | length' "${state_file}")" -ne 0 ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":true,"reason":"qualification_stack_is_not_cleanup_enabled"}\n' "${schema}"
  exit 2
fi
cleanup_safe=true

phase="resource_probes"
gcloud deploy delivery-pipelines describe "${ZIAC_CLOUD_DEPLOY_PIPELINE}" --region="${ZIAC_CLOUD_DEPLOY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null
gcloud deploy targets describe "${ZIAC_CLOUD_DEPLOY_TARGET}" --region="${ZIAC_CLOUD_DEPLOY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null

phase="release_and_rollout"
release_json="$(gcloud deploy releases create "${ZIAC_CLOUD_DEPLOY_RELEASE}" \
  --delivery-pipeline="${ZIAC_CLOUD_DEPLOY_PIPELINE}" \
  --region="${ZIAC_CLOUD_DEPLOY_LOCATION}" \
  --project="${ZIAC_LIVE_PROJECT}" \
  --source="${workspace}" \
  --skaffold-file="${ZIAC_CLOUD_DEPLOY_SKAFFOLD_FILE}" \
  --to-target="${ZIAC_CLOUD_DEPLOY_TARGET}" \
  --format=json)"
pipeline_has_release=true
test "$(printf '%s' "${release_json}" | jq -r '.renderState // empty')" = "SUCCEEDED"

rollout_name=""
rollout_state=""
for _ in $(seq 1 90); do
  rollouts="$(gcloud deploy rollouts list --release="${ZIAC_CLOUD_DEPLOY_RELEASE}" --delivery-pipeline="${ZIAC_CLOUD_DEPLOY_PIPELINE}" --region="${ZIAC_CLOUD_DEPLOY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json)"
  rollout_name="$(printf '%s' "${rollouts}" | jq -r '.[0].name // empty' | sed 's#.*/##')"
  rollout_state="$(printf '%s' "${rollouts}" | jq -r '.[0].state // empty')"
  if [[ "${rollout_state}" = "SUCCEEDED" ]]; then break; fi
  if [[ "${rollout_state}" = "FAILED" || "${rollout_state}" = "CANCELLED" || "${rollout_state}" = "HALTED" || "${rollout_state}" = "PENDING_APPROVAL" ]]; then break; fi
  sleep 10
done
test -n "${rollout_name}"
test "${rollout_state}" = "SUCCEEDED"

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
cleanup

trap - EXIT
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg graph_digest "${plan_digest}" \
  --arg release "${ZIAC_CLOUD_DEPLOY_RELEASE}" \
  --arg rollout "${rollout_name}" \
  --argjson resources "${resource_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,pipeline:"reachable",target:"reachable",release:{id:$release,render:"SUCCEEDED"},rollout:{id:$rollout,state:"SUCCEEDED"},import_plan:"noop",cleanup:"deleted",cost_origin:"configuration_estimate"}'
