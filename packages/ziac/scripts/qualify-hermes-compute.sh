#!/usr/bin/env bash
set -euo pipefail

schema="ziac.gcp.hermes-compute-qualification.v2"
package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ziac_bin="${ZIAC_BIN:-ziac}"
stack="${ZIAC_HERMES_STACK:-hermes}"
stage="${ZIAC_HERMES_STAGE:-qualification}"
instance="${ZIAC_HERMES_INSTANCE:-hermes}"
firewall="${ZIAC_HERMES_FIREWALL:-hermes-iap-ssh}"
desktop_firewall="${ZIAC_HERMES_DESKTOP_FIREWALL:-hermes-desktop-edge}"
address="${ZIAC_HERMES_ADDRESS:-hermes-ip}"
network="${ZIAC_HERMES_NETWORK:-hermes}"
disk="${ZIAC_HERMES_DISK:-hermes-boot}"
secret="${ZIAC_HERMES_SECRET:-hermes-env}"
timeout_seconds="${ZIAC_HERMES_TIMEOUT_SECONDS:-900}"

required=(
  ZIAC_HERMES_WORKSPACE
  ZIAC_LIVE_PROJECT
  ZIAC_HERMES_REGION
  ZIAC_HERMES_ZONE
  ZIAC_HERMES_IMAGE
  HERMES_DOMAIN
  HERMES_DNS_ZONE
  HERMES_OAUTH_CLIENT_ID
  HERMES_ENV_FILE
  ZIAC_HERMES_DESTRUCTIVE_CONFIRMATION
)
missing=()
for variable in "${required[@]}"; do
  if [[ -z "${!variable:-}" ]]; then missing+=("${variable}"); fi
done
for command in "${ziac_bin}" curl gcloud jq nc shasum; do
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
if [[ "${ZIAC_HERMES_DESTRUCTIVE_CONFIRMATION}" != "QUALIFY_DISPOSABLE_HERMES_COMPUTE" ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"destructive_confirmation_mismatch"}\n' "${schema}"
  exit 2
fi
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '{"schema":"%s","status":"skipped","authenticated":false,"reason":"application_default_credentials_unavailable"}\n' "${schema}"
  exit 77
fi

workspace="$(cd "${ZIAC_HERMES_WORKSPACE}" && pwd)"
startup_script="${package_dir}/scripts/hermes-compute-startup.sh"
expected_startup_digest="29fa57ca4fb139f51055b423692a792203688e4578d3626efa80b307740e54e9"
actual_startup_digest="$(shasum -a 256 "${startup_script}" | awk '{print $1}')"
if [[ "${actual_startup_digest}" != "${expected_startup_digest}" ]]; then
  printf '{"schema":"%s","status":"failed","authenticated":false,"reason":"startup_script_digest_mismatch"}\n' "${schema}"
  exit 2
fi

export ZIAC_GCP_PROJECT="${ZIAC_LIVE_PROJECT}"
export ZIAC_HERMES_LIFECYCLE="ephemeral"
export ZIAC_HERMES_DOMAIN="${HERMES_DOMAIN}"
export ZIAC_HERMES_DNS_ZONE="${HERMES_DNS_ZONE}"
export ZIAC_HERMES_OAUTH_CLIENT_ID="${HERMES_OAUTH_CLIENT_ID}"
export ZIAC_HERMES_STARTUP_SCRIPT
ZIAC_HERMES_STARTUP_SCRIPT="$(<"${startup_script}")"

phase="service_enablement"
cleanup_enabled=0
tunnel_pid=""
cleanup() {
  if [[ -n "${tunnel_pid}" ]]; then
    kill "${tunnel_pid}" 2>/dev/null || true
    wait "${tunnel_pid}" 2>/dev/null || true
    tunnel_pid=""
  fi
  if (( cleanup_enabled == 1 )); then
    (cd "${workspace}" && "${ziac_bin}" destroy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --confirm --json >/dev/null 2>&1) || true
  fi
}
on_error() {
  exit_code=$?
  cleanup
  printf '{"schema":"%s","status":"failed","authenticated":true,"phase":"%s"}\n' "${schema}" "${phase}"
  exit "${exit_code}"
}
trap on_error ERR
trap cleanup INT TERM

gcloud services enable \
  compute.googleapis.com \
  dns.googleapis.com \
  iam.googleapis.com \
  iap.googleapis.com \
  oslogin.googleapis.com \
  secretmanager.googleapis.com \
  --project="${ZIAC_LIVE_PROJECT}" --quiet

cd "${workspace}"
unset ZIAC_STATE_BUCKET
mkdir -p .ziac/qualification

phase="plan_apply"
plan_path=".ziac/qualification/${stage}.plan.json"
plan_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --out "${plan_path}" --json)"
plan_digest="$(printf '%s' "${plan_receipt}" | jq -r '.plan_digest // empty')"
test -n "${plan_digest}"
cleanup_enabled=1
"${ziac_bin}" deploy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --plan "${plan_path}" --approve "${plan_digest}" --json >/dev/null

state_file=".ziac/state/${stack}/${stage}/resources.json"
test -f "${state_file}"
resource_count="$(jq '.resources | length' "${state_file}")"
test "${resource_count}" -eq 12
test "$(jq '[.resources[] | select(.protect == true or .retain_on_delete == true)] | length' "${state_file}")" -eq 0

ssh_command() {
  gcloud compute ssh "${instance}" \
    --project="${ZIAC_LIVE_PROJECT}" \
    --zone="${ZIAC_HERMES_ZONE}" \
    --tunnel-through-iap --quiet --command="$1"
}

wait_for_container() {
  local deadline=$((SECONDS + timeout_seconds))
  until ssh_command "sudo docker inspect --format='{{.State.Running}}' hermes 2>/dev/null" | grep -Fx true >/dev/null; do
    if (( SECONDS >= deadline )); then return 1; fi
    sleep 10
  done
}

wait_for_edge() {
  local deadline=$((SECONDS + timeout_seconds))
  until ssh_command "sudo docker inspect --format='{{.State.Running}}' hermes-edge 2>/dev/null" | grep -Fx true >/dev/null; do
    if (( SECONDS >= deadline )); then return 1; fi
    sleep 10
  done
}

wait_for_desktop() {
  local deadline=$((SECONDS + timeout_seconds))
  until curl --fail --silent --show-error --max-time 15 "https://${HERMES_DOMAIN}/api/status" >/tmp/ziac-hermes-status.json; do
    if (( SECONDS >= deadline )); then return 1; fi
    sleep 10
  done
}

phase="runtime_readiness"
gcloud compute instances describe "${instance}" --project="${ZIAC_LIVE_PROJECT}" --zone="${ZIAC_HERMES_ZONE}" --format='value(status)' | grep -Fx RUNNING >/dev/null
wait_for_container
wait_for_edge
ssh_command "test \"\$(sudo docker inspect --format='{{.Config.Image}}' hermes)\" = '${ZIAC_HERMES_IMAGE}'"
ssh_command "test \"\$(sudo docker inspect --format='{{.Config.Image}}' hermes-edge)\" = 'caddy:2.11.4-alpine'"
ssh_command "test \"\$(sudo docker port hermes 8642/tcp)\" = '127.0.0.1:8642'"
ssh_command "test \"\$(sudo docker port hermes 9119/tcp)\" = '127.0.0.1:9119'"

firewall_json="$(gcloud compute firewall-rules describe "${firewall}" --project="${ZIAC_LIVE_PROJECT}" --format=json)"
test "$(printf '%s' "${firewall_json}" | jq -r '.sourceRanges | join(",")')" = "35.235.240.0/20"
test "$(printf '%s' "${firewall_json}" | jq -r '[.allowed[].ports[]] | join(",")')" = "22"

desktop_firewall_json="$(gcloud compute firewall-rules describe "${desktop_firewall}" --project="${ZIAC_LIVE_PROJECT}" --format=json)"
test "$(printf '%s' "${desktop_firewall_json}" | jq -r '.sourceRanges | join(",")')" = "0.0.0.0/0"
test "$(printf '%s' "${desktop_firewall_json}" | jq -r '[.allowed[].ports[]] | sort | join(",")')" = "443,80"
test "$(printf '%s' "${desktop_firewall_json}" | jq -r '[.allowed[].ports[]] | any(. == "8642" or . == "9119")')" = "false"

reserved_ip="$(gcloud compute addresses describe "${address}" --project="${ZIAC_LIVE_PROJECT}" --region="${ZIAC_HERMES_REGION}" --format='value(address)')"
instance_ip="$(gcloud compute instances describe "${instance}" --project="${ZIAC_LIVE_PROJECT}" --zone="${ZIAC_HERMES_ZONE}" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
test -n "${reserved_ip}"
test "${instance_ip}" = "${reserved_ip}"

phase="desktop_https_oauth"
wait_for_desktop
test "$(jq -r '.auth_required' /tmp/ziac-hermes-status.json)" = "true"
test "$(jq -r '.auth_providers | any(. == "nous")' /tmp/ziac-hermes-status.json)" = "true"
ws_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --http1.1 \
  --header 'Connection: Upgrade' --header 'Upgrade: websocket' \
  --header 'Sec-WebSocket-Version: 13' --header 'Sec-WebSocket-Key: emlhYy1xdWFsaWZpY2F0aW9u' \
  "https://${HERMES_DOMAIN}/api/ws")"
test "${ws_status}" != "101"

phase="iap_tunnel_probe"
local_port="${ZIAC_HERMES_LOCAL_PROBE_PORT:-18642}"
gcloud compute start-iap-tunnel "${instance}" 8642 \
  --project="${ZIAC_LIVE_PROJECT}" --zone="${ZIAC_HERMES_ZONE}" \
  --local-host-port="127.0.0.1:${local_port}" --quiet >/dev/null 2>&1 &
tunnel_pid=$!
for _ in {1..30}; do
  if nc -z 127.0.0.1 "${local_port}"; then break; fi
  sleep 1
done
nc -z 127.0.0.1 "${local_port}"
kill "${tunnel_pid}" 2>/dev/null || true
wait "${tunnel_pid}" 2>/dev/null || true
tunnel_pid=""

phase="restart_persistence"
gcloud compute instances stop "${instance}" --project="${ZIAC_LIVE_PROJECT}" --zone="${ZIAC_HERMES_ZONE}" --quiet
gcloud compute instances start "${instance}" --project="${ZIAC_LIVE_PROJECT}" --zone="${ZIAC_HERMES_ZONE}" --quiet
wait_for_container
wait_for_edge
wait_for_desktop

phase="noop_plan"
noop_receipt="$("${ziac_bin}" plan --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --json)"
test "$(printf '%s' "${noop_receipt}" | jq '.create + .update + .delete')" -eq 0
test "$(printf '%s' "${noop_receipt}" | jq '.noop')" -eq "${resource_count}"

phase="destructive_cleanup"
"${ziac_bin}" destroy --stack "${stack}" --stage "${stage}" --provider gcp --allow-live --live-test --confirm --json >/dev/null
cleanup_enabled=0

phase="empty_inventory"
deadline=$((SECONDS + 180))
while [[ -n "$(gcloud compute instances list --project="${ZIAC_LIVE_PROJECT}" --filter="name=${instance}" --format='value(name)')" ||
  -n "$(gcloud compute disks list --project="${ZIAC_LIVE_PROJECT}" --filter="name=${disk}" --format='value(name)')" ||
  -n "$(gcloud compute addresses list --project="${ZIAC_LIVE_PROJECT}" --filter="name=${address}" --format='value(name)')" ||
  -n "$(gcloud compute networks list --project="${ZIAC_LIVE_PROJECT}" --filter="name=${network}" --format='value(name)')" ]]; do
  if (( SECONDS >= deadline )); then exit 1; fi
  sleep 5
done
if gcloud secrets describe "${secret}" --project="${ZIAC_LIVE_PROJECT}" >/dev/null 2>&1; then exit 1; fi
if gcloud dns record-sets describe "${HERMES_DOMAIN}." --type=A --zone="${HERMES_DNS_ZONE}" --project="${ZIAC_LIVE_PROJECT}" >/dev/null 2>&1; then exit 1; fi

trap - ERR INT TERM
jq -cn \
  --arg schema "${schema}" \
  --arg project "${ZIAC_LIVE_PROJECT}" \
  --arg region "${ZIAC_HERMES_REGION}" \
  --arg zone "${ZIAC_HERMES_ZONE}" \
  --arg image "${ZIAC_HERMES_IMAGE}" \
  --arg desktop_url "https://${HERMES_DOMAIN}" \
  --arg graph_digest "${plan_digest}" \
  --argjson resources "${resource_count}" \
  '{schema:$schema,status:"passed",authenticated:true,project:$project,region:$region,zone:$zone,image:$image,desktop_url:$desktop_url,graph_digest:$graph_digest,resource_count:$resources,access:"desktop_https_oauth",restart_persistence:"passed",plan:"noop",cleanup:"empty"}'
