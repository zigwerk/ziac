#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.build-delivery-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_BUILD_DELIVERY_STACK:-build-delivery}"
stage="${ZIAC_BUILD_DELIVERY_STAGE:-qualification}"
import_stage="${stage}-import"

required=(
  ZIAC_BUILD_DELIVERY_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_BUILD_DELIVERY_LOCATION
  ZIAC_BUILD_DELIVERY_CONNECTION
  ZIAC_BUILD_DELIVERY_REPOSITORY
  ZIAC_BUILD_DELIVERY_WORKER_POOL
  ZIAC_BUILD_DELIVERY_TRIGGER
  ZIAC_BUILD_DELIVERY_ARTIFACT_REPOSITORY
  ZIAC_BUILD_DELIVERY_BRANCH
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
applied=false
cleanup_safe=false
on_exit() {
  exit_code=$?
  if (( exit_code != 0 )) && [[ "${applied}" = true && "${cleanup_safe}" = true ]]; then
    phase="failure_cleanup"
    "${ziac_bin}" destroy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --confirm --json >/dev/null 2>&1 || true
  fi
  if (( exit_code != 0 )); then
    printf '{"schema":"%s","status":"failed","authenticated":true,"phase":"%s"}\n' "${schema}" "${phase}"
  fi
  exit "${exit_code}"
}
trap on_exit EXIT

gcloud services enable cloudbuild.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com \
  --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_BUILD_DELIVERY_WORKSPACE}" && pwd)"
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
connection_json="$(gcloud builds connections describe "${ZIAC_BUILD_DELIVERY_CONNECTION}" --region="${ZIAC_BUILD_DELIVERY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json)"
test "$(printf '%s' "${connection_json}" | jq -r '.installationState.stage // empty')" = COMPLETE
gcloud builds repositories describe "${ZIAC_BUILD_DELIVERY_REPOSITORY}" --connection="${ZIAC_BUILD_DELIVERY_CONNECTION}" --region="${ZIAC_BUILD_DELIVERY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null
gcloud builds worker-pools describe "${ZIAC_BUILD_DELIVERY_WORKER_POOL}" --region="${ZIAC_BUILD_DELIVERY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null
gcloud builds triggers describe "${ZIAC_BUILD_DELIVERY_TRIGGER}" --region="${ZIAC_BUILD_DELIVERY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null
gcloud artifacts repositories describe "${ZIAC_BUILD_DELIVERY_ARTIFACT_REPOSITORY}" --location="${ZIAC_BUILD_DELIVERY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format=json >/dev/null

phase="trigger_build"
trigger_result="$(gcloud builds triggers run "${ZIAC_BUILD_DELIVERY_TRIGGER}" --region="${ZIAC_BUILD_DELIVERY_LOCATION}" --branch="${ZIAC_BUILD_DELIVERY_BRANCH}" --project="${ZIAC_LIVE_PROJECT}" --format=json)"
build_id="$(printf '%s' "${trigger_result}" | jq -r '.id // .metadata.build.id // .metadata.build.name // empty' | sed 's#.*/##')"
test -n "${build_id}"
build_status=""
for _ in $(seq 1 90); do
  build_status="$(gcloud builds describe "${build_id}" --region="${ZIAC_BUILD_DELIVERY_LOCATION}" --project="${ZIAC_LIVE_PROJECT}" --format='value(status)')"
  if [[ "${build_status}" = SUCCESS ]]; then break; fi
  if [[ "${build_status}" = FAILURE || "${build_status}" = INTERNAL_ERROR || "${build_status}" = TIMEOUT || "${build_status}" = CANCELLED || "${build_status}" = EXPIRED ]]; then break; fi
  sleep 10
done
test "${build_status}" = SUCCESS

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
"${ziac_bin}" destroy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --confirm --json >/dev/null
applied=false

trap - EXIT
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg graph_digest "${plan_digest}" \
  --arg build_id "${build_id}" \
  --argjson resources "${resource_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,connection:"complete",repository:"reachable",worker_pool:"reachable",trigger:"reachable",artifact_repository:"reachable",build:{id:$build_id,status:"SUCCESS"},import_plan:"noop",cleanup:"deleted",cost_origin:"configuration_estimate"}'
