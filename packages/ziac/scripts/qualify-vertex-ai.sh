#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.vertex-ai-qualification.v1"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_VERTEX_AI_STACK:-vertex-ai}"
stage="${ZIAC_VERTEX_AI_STAGE:-qualification}"
import_stage="${stage}-import"
required=(ZIAC_VERTEX_AI_WORKSPACE ZIAC_LIVE_PROJECT ZIAC_VERTEX_AI_REGION ZIAC_VERTEX_AI_MODEL ZIAC_VERTEX_AI_ENDPOINT ZIAC_VERTEX_AI_INDEX ZIAC_VERTEX_AI_INDEX_ENDPOINT ZIAC_VERTEX_AI_DESTRUCTIVE_CONFIRMATION)
missing=()
for variable in "${required[@]}"; do if [[ -z "${!variable:-}" ]]; then missing+=("${variable}"); fi; done
for command in "${ziac_bin}" gcloud curl jq; do if ! command -v "${command}" >/dev/null 2>&1; then missing+=("tool:${command}"); fi; done
if (( ${#missing[@]} > 0 )); then
  printf '{"schema":"%s","status":"skipped","authenticated":false,"reason":"missing_credentials_configuration_or_tools","missing":[' "${schema}"
  separator=""; for item in "${missing[@]}"; do printf '%s"%s"' "${separator}" "${item}"; separator=","; done; printf ']}\n'; exit 77
fi
if [[ "${ZIAC_LIVE_PROJECT}" != *-ziac-disposable ]]; then printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"project_is_not_disposable"}\n' "${schema}"; exit 2; fi
if [[ "${ZIAC_VERTEX_AI_DESTRUCTIVE_CONFIRMATION}" != "QUALIFY_DISPOSABLE_VERTEX_AI" ]]; then printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"destructive_confirmation_mismatch"}\n' "${schema}"; exit 2; fi
for resource_name in "${ZIAC_VERTEX_AI_MODEL}" "${ZIAC_VERTEX_AI_ENDPOINT}" "${ZIAC_VERTEX_AI_INDEX}" "${ZIAC_VERTEX_AI_INDEX_ENDPOINT}"; do
  if [[ "${resource_name}" != projects/"${ZIAC_LIVE_PROJECT}"/locations/"${ZIAC_VERTEX_AI_REGION}"/* ]]; then printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"probe_resource_outside_disposable_scope"}\n' "${schema}"; exit 2; fi
done
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then printf '{"schema":"%s","status":"skipped","authenticated":false,"reason":"application_default_credentials_unavailable"}\n' "${schema}"; exit 77; fi

phase="service_enablement"
on_error() { exit_code=$?; printf '{"schema":"%s","status":"failed","authenticated":true,"phase":"%s"}\n' "${schema}" "${phase}"; exit "${exit_code}"; }
trap on_error ERR
gcloud services enable aiplatform.googleapis.com cloudasset.googleapis.com --project="${ZIAC_LIVE_PROJECT}" --quiet
workspace="$(cd "${ZIAC_VERTEX_AI_WORKSPACE}" && pwd)"; cd "${workspace}"
unset ZIAC_STATE_BUCKET; export ZIAC_GCP_PROJECT="${ZIAC_LIVE_PROJECT}"; mkdir -p .ziac/qualification
phase="plan_apply"
plan_path=".ziac/qualification/${stage}.plan.json"
plan_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --out "${plan_path}" --json)"
plan_digest="$(printf '%s' "${plan_receipt}" | jq -r '.plan_digest // empty')"; test -n "${plan_digest}"
"${ziac_bin}" deploy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --plan "${plan_path}" --approve "${plan_digest}" --json >/dev/null
state_file=".ziac/state/${stack}/${stage}/resources.json"; test -f "${state_file}"; resource_count="$(jq '.resources | length' "${state_file}")"; test "${resource_count}" -ge 4
phase="authenticated_read_probes"; access_token="$(gcloud auth application-default print-access-token)"
probe() { curl --fail --silent --show-error --output ".ziac/qualification/$1.json" --header "Authorization: Bearer ${access_token}" "https://${ZIAC_VERTEX_AI_REGION}-aiplatform.googleapis.com/v1/$2"; }
probe model "${ZIAC_VERTEX_AI_MODEL}"
probe endpoint "${ZIAC_VERTEX_AI_ENDPOINT}"
probe index "${ZIAC_VERTEX_AI_INDEX}"
probe index-endpoint "${ZIAC_VERTEX_AI_INDEX_ENDPOINT}"
phase="second_state_import"
while IFS=$'\t' read -r resource_id physical_id; do test -n "${resource_id}"; test -n "${physical_id}"; "${ziac_bin}" import --stack "${stack}" --stage "${import_stage}" --provider gcp --allow-live --live-test --resource "${resource_id}" --id "${physical_id}" --json >/dev/null; done < <(jq -r '.resources[] | select(.physical_id != null) | [.resource_id, .physical_id] | @tsv' "${state_file}")
import_plan=".ziac/qualification/${import_stage}.plan.json"; import_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${import_stage}" --provider gcp --allow-live --live-test --out "${import_plan}" --json)"
test "$(printf '%s' "${import_receipt}" | jq '.create + .update + .delete')" -eq 0; test "$(printf '%s' "${import_receipt}" | jq '.noop')" -eq "${resource_count}"
retained_count="$(jq '[.resources[] | select(.retain_on_delete == true)] | length' "${state_file}")"; test "${retained_count}" -gt 0
trap - ERR
jq -cn --arg schema "${schema}" --arg project "${ZIAC_LIVE_PROJECT}" --arg region "${ZIAC_VERTEX_AI_REGION}" --arg graph_digest "${plan_digest}" --argjson resources "${resource_count}" --argjson retained "${retained_count}" '{schema:$schema,status:"passed",authenticated:true,project:$project,region:$region,graph_digest:$graph_digest,resource_count:$resources,read_probes:"reachable",import_plan:"noop",retained_resources:$retained,governed_actions:"excluded",data_plane:"excluded",cost_origin:"unavailable_without_explicit_usage",cleanup:"retained_for_explicit_operator_cleanup"}'
