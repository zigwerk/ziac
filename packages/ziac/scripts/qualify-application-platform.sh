#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.application-platform-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_APPLICATION_STACK:-application-platform}"
stage="${ZIAC_APPLICATION_STAGE:-qualification}"
import_stage="${stage}-import"
name="${ZIAC_APPLICATION_NAME:-platform}"
region="${ZIAC_APPLICATION_REGION:-europe-west1}"

required=(
  ZIAC_APPLICATION_PLATFORM_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_GCP_PROJECT_NUMBER
  ZIAC_LIVE_IMAGE
  ZIAC_APPLICATION_BUCKET
  ZIAC_APPLICATION_SERVICE_ORIGIN
  ZIAC_TASKS_SERVICE_ACCOUNT
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
if [[ "${ZIAC_LIVE_IMAGE}" != *@sha256:* ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"image_is_not_immutable"}\n' "${schema}"
  exit 2
fi
if (( ${#name} > 20 )); then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"qualification_name_too_long"}\n' "${schema}"
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

actual_project_number="$(gcloud projects describe "${ZIAC_LIVE_PROJECT}" --format='value(projectNumber)')"
test "${actual_project_number}" = "${ZIAC_GCP_PROJECT_NUMBER}"

phase="service_enablement"
gcloud services enable \
  run.googleapis.com \
  storage.googleapis.com \
  pubsub.googleapis.com \
  cloudtasks.googleapis.com \
  eventarc.googleapis.com \
  cloudscheduler.googleapis.com \
  iam.googleapis.com \
  logging.googleapis.com \
  --project="${ZIAC_LIVE_PROJECT}" --quiet

workspace="$(cd "${ZIAC_APPLICATION_PLATFORM_WORKSPACE}" && pwd)"
cd "${workspace}"
unset ZIAC_STATE_BUCKET
export ZIAC_GCP_PROJECT="${ZIAC_LIVE_PROJECT}"
export ZIAC_APPLICATION_NAME="${name}"
export ZIAC_APPLICATION_REGION="${region}"

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

qualification_id="ziac-$(date +%s)-$$"
payload="{\"qualification_id\":\"${qualification_id}\"}"
started_at="$(date +%s)"

phase="storage_probe"
probe_file="$(mktemp)"
trap 'rm -f "${probe_file}"' EXIT
printf '%s' "${payload}" >"${probe_file}"
gcloud storage cp "${probe_file}" "gs://${ZIAC_APPLICATION_BUCKET}/qualification/${qualification_id}.json" --project="${ZIAC_LIVE_PROJECT}" --quiet
test "$(gcloud storage cat "gs://${ZIAC_APPLICATION_BUCKET}/qualification/${qualification_id}.json" --project="${ZIAC_LIVE_PROJECT}")" = "${payload}"

phase="pubsub_probe"
gcloud pubsub topics publish "${name}-events" --message="${payload}" --attribute="qualification_id=${qualification_id}" --project="${ZIAC_LIVE_PROJECT}" >/dev/null

phase="tasks_probe"
gcloud tasks create-http-task "${qualification_id}" \
  --queue="${name}-tasks" \
  --location="${region}" \
  --url="${ZIAC_APPLICATION_SERVICE_ORIGIN}/tasks" \
  --method=POST \
  --header="content-type:application/json" \
  --body-content="${payload}" \
  --oidc-service-account-email="${ZIAC_TASKS_SERVICE_ACCOUNT}" \
  --oidc-token-audience="${ZIAC_APPLICATION_SERVICE_ORIGIN}" \
  --project="${ZIAC_LIVE_PROJECT}" >/dev/null

phase="eventarc_probe"
gcloud pubsub topics publish "${name}-trigger" --message="${payload}" --attribute="qualification_id=${qualification_id}" --project="${ZIAC_LIVE_PROJECT}" >/dev/null
gcloud eventarc triggers describe "${name}-trigger" --location="${region}" --project="${ZIAC_LIVE_PROJECT}" --format='value(name)' >/dev/null

phase="job_and_scheduler_probe"
gcloud run jobs execute "${name}-job" --region="${region}" --project="${ZIAC_LIVE_PROJECT}" --wait --quiet >/dev/null
gcloud scheduler jobs run "${name}-job" --location="${region}" --project="${ZIAC_LIVE_PROJECT}" --quiet
gcloud run worker-pools describe "${name}-worker" --region="${region}" --project="${ZIAC_LIVE_PROJECT}" --format='value(name)' >/dev/null

phase="delivery_evidence"
delivery_observed=false
for _ in $(seq 1 60); do
  if gcloud logging read \
    "resource.type=cloud_run_revision AND (textPayload:${qualification_id} OR jsonPayload.qualification_id=${qualification_id})" \
    --project="${ZIAC_LIVE_PROJECT}" --freshness=30m --limit=1 --format='value(timestamp)' | grep -q .; then
    delivery_observed=true
    break
  fi
  sleep 5
done
test "${delivery_observed}" = true

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

phase="bounded_destroy"
"${ziac_bin}" destroy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --confirm --json >/dev/null
gcloud storage buckets describe "gs://${ZIAC_APPLICATION_BUCKET}" --project="${ZIAC_LIVE_PROJECT}" --format='value(name)' >/dev/null
gcloud pubsub topics describe "${name}-events" --project="${ZIAC_LIVE_PROJECT}" --format='value(name)' >/dev/null
gcloud tasks queues describe "${name}-tasks" --location="${region}" --project="${ZIAC_LIVE_PROJECT}" --format='value(name)' >/dev/null

ended_at="$(date +%s)"
duration_seconds="$((ended_at - started_at))"
trap - ERR
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg graph_digest "${plan_digest}" \
  --argjson resources "${resource_count}" \
  --argjson duration_seconds "${duration_seconds}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,graph_digest:$graph_digest,resource_count:$resources,delivery:"observed",import_plan:"noop",retained_resources:"present",cost_origin:"configuration_estimate",duration_seconds:$duration_seconds}'
