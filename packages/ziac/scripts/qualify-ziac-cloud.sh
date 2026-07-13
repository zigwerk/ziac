#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "${script_dir}/.." && pwd)"

required=(
  ZIAC_CLOUD_WORKSPACE
  ZIAC_GCP_PROJECT
  ZIAC_STATE_BUCKET
  ZIAC_CONTROL_PLANE_DOMAIN
  ZIAC_DNS_ZONE
  ZIAC_DATABASE_SECRET
  ZIAC_OAUTH_CLIENT_ID_SECRET
  ZIAC_OAUTH_CLIENT_SECRET
  ZIAC_ESTATE_KMS_KEY
  ZIAC_COCKROACH_CLUSTER_ID
  ZIAC_COCKROACH_ADMIN_SECRET_VERSION
  COCKROACH_API_KEY
  ZIAC_BILLING_PROJECT
  ZIAC_BILLING_EXPORT_TABLE
  ZIAC_CONTROL_PLANE_URL
)

missing=()
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then missing+=("${name}"); fi
done
if (( ${#missing[@]} > 0 )); then
  printf '{"schema":"ziac.self-host-qualification.v1","status":"skipped","reason":"missing_credentials_or_configuration","missing":['
  separator=""
  for name in "${missing[@]}"; do
    printf '%s"%s"' "${separator}" "${name}"
    separator=","
  done
  printf ']}\n'
  exit 77
fi

ziac_bin="${ZIAC_BIN:-ziac}"
workspace="$(cd "${ZIAC_CLOUD_WORKSPACE}" && pwd)"
export ZIAC_LIVE_PROJECT="${ZIAC_GCP_PROJECT}"
command -v "${ziac_bin}" >/dev/null 2>&1 || { echo "ziac executable unavailable" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl unavailable" >&2; exit 2; }
command -v bq >/dev/null 2>&1 || { echo "bq unavailable" >&2; exit 2; }
command -v gcloud >/dev/null 2>&1 || { echo "gcloud unavailable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq unavailable" >&2; exit 2; }

cd "${workspace}/platform/bootstrap"
state_bucket="${ZIAC_STATE_BUCKET}"
export ZIAC_BOOTSTRAP_STATE_BUCKET="${state_bucket}"
unset ZIAC_STATE_BUCKET
receipt="$("${ziac_bin}" plan --stack bootstrap --stage prod --provider gcp --allow-live --out .ziac/bootstrap.plan.json --json)"
digest="$(printf '%s' "${receipt}" | sed -n 's/.*"plan_digest":"\([0-9a-f]\{64\}\)".*/\1/p')"
test -n "${digest}"
"${ziac_bin}" deploy --stack bootstrap --stage prod --provider gcp --allow-live --plan .ziac/bootstrap.plan.json --approval "${digest}" --json

export ZIAC_STATE_BUCKET="${state_bucket}"
"${ziac_bin}" state-migrate --stack bootstrap --stage prod --json

if [[ -z "${ZIAC_CONTROL_PLANE_IMAGE:-}" || -z "${ZIAC_BILLING_IMAGE:-}" ]]; then
  context_dir="$(dirname "${package_dir}")"
  repository="${ZIAC_ARTIFACT_REPOSITORY:-ziac-cloud}"
  image_prefix="${ZIAC_GCP_PROJECT}/${repository}"
  control_tag="${ZIAC_STATE_REGION:-europe-west1}-docker.pkg.dev/${image_prefix}/control-plane:bootstrap"
  billing_tag="${ZIAC_STATE_REGION:-europe-west1}-docker.pkg.dev/${image_prefix}/billing-worker:bootstrap"
  gcloud builds submit "${context_dir}" \
    --project="${ZIAC_GCP_PROJECT}" \
    --region="${ZIAC_STATE_REGION:-europe-west1}" \
    --ignore-file="${package_dir}/scripts/self-host.gcloudignore" \
    --config="${package_dir}/cloudbuild.self-host.yaml" \
    --substitutions="_CONTROL_PLANE_IMAGE=${control_tag},_BILLING_IMAGE=${billing_tag}"
  control_digest="$(gcloud artifacts docker images describe "${control_tag}" --project="${ZIAC_GCP_PROJECT}" --format='value(image_summary.digest)')"
  billing_digest="$(gcloud artifacts docker images describe "${billing_tag}" --project="${ZIAC_GCP_PROJECT}" --format='value(image_summary.digest)')"
  test -n "${control_digest}"
  test -n "${billing_digest}"
  export ZIAC_CONTROL_PLANE_IMAGE="${control_tag%:*}@${control_digest}"
  export ZIAC_BILLING_IMAGE="${billing_tag%:*}@${billing_digest}"
fi

for project in data control-plane billing; do
  cd "${workspace}/platform/${project}"
  plan_path=".ziac/${project}.plan.json"
  receipt="$("${ziac_bin}" plan --stack "${project}" --stage prod --provider gcp --allow-live --out "${plan_path}" --json)"
  digest="$(printf '%s' "${receipt}" | sed -n 's/.*"plan_digest":"\([0-9a-f]\{64\}\)".*/\1/p')"
  test -n "${digest}"
  "${ziac_bin}" deploy --stack "${project}" --stage prod --provider gcp --allow-live --plan "${plan_path}" --approval "${digest}" --json
done

control_plane_ready=false
for _ in $(seq 1 60); do
  if curl --max-time 5 --fail --silent --show-error "${ZIAC_CONTROL_PLANE_URL}/health/live" >/dev/null; then
    control_plane_ready=true
    break
  fi
  sleep 5
done
test "${control_plane_ready}" = true
bq query --project_id="${ZIAC_BILLING_PROJECT}" --use_legacy_sql=false --format=json \
  "SELECT COUNT(*) AS rows FROM \`${ZIAC_BILLING_EXPORT_TABLE}\` WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)" >/dev/null

scheduler_location="${ZIAC_STATE_REGION:-europe-west1}"
before_attempt="$(gcloud scheduler jobs describe ziac-billing-hourly --project="${ZIAC_GCP_PROJECT}" --location="${scheduler_location}" --format='value(lastAttemptTime)' 2>/dev/null || true)"
gcloud scheduler jobs run ziac-billing-hourly --project="${ZIAC_GCP_PROJECT}" --location="${scheduler_location}"
billing_ingestion_ready=false
for _ in $(seq 1 60); do
  scheduler_json="$(gcloud scheduler jobs describe ziac-billing-hourly --project="${ZIAC_GCP_PROJECT}" --location="${scheduler_location}" --format=json)"
  after_attempt="$(printf '%s' "${scheduler_json}" | jq -r '.lastAttemptTime // ""')"
  status_code="$(printf '%s' "${scheduler_json}" | jq -r '.status.code // 0')"
  if [[ -n "${after_attempt}" && "${after_attempt}" != "${before_attempt}" && "${status_code}" = "0" ]]; then
    billing_ingestion_ready=true
    break
  fi
  sleep 5
done
test "${billing_ingestion_ready}" = true

printf '{"schema":"ziac.self-host-qualification.v1","status":"passed","project":"%s","control_plane":"%s","billing_export":"%s","scheduler":"ziac-billing-hourly","billing_ingestion":"complete"}\n' \
  "${ZIAC_GCP_PROJECT}" "${ZIAC_CONTROL_PLANE_URL}" "${ZIAC_BILLING_EXPORT_TABLE}"
