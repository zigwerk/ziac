#!/usr/bin/env bash
set -euo pipefail

umask 077
exec > >(tee -a /var/log/ziac-hermes-bootstrap.log) 2>&1

metadata_url="http://metadata.google.internal/computeMetadata/v1"
metadata_header="Metadata-Flavor: Google"
data_dir="/opt/data"
environment_file="${data_dir}/.env"
container_name="hermes"
edge_container_name="hermes-edge"
edge_dir="/opt/hermes-edge"

metadata() {
  curl --fail --silent --show-error --retry 8 --retry-all-errors \
    --connect-timeout 5 --max-time 30 \
    --header "${metadata_header}" "${metadata_url}/$1"
}

retry_packages() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if apt-get update &&
      DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        ca-certificates curl docker.io python3; then
      return 0
    fi
    sleep $((attempt * 5))
  done
  return 1
}

require_pinned_image() {
  local image="$1"
  if [[ "${image}" == *@sha256:* ]]; then
    [[ "${image##*@sha256:}" =~ ^[0-9a-fA-F]{64}$ ]]
    return
  fi
  local final_component="${image##*/}"
  [[ "${final_component}" == *:* && "${final_component##*:}" != "latest" && -n "${final_component##*:}" ]]
}

require_domain() {
  local domain="$1"
  [[ "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

printf 'ziac-hermes: installing bounded guest dependencies\n'
retry_packages
systemctl enable --now docker

hermes_image="$(metadata instance/attributes/hermes-image)"
proxy_image="$(metadata instance/attributes/hermes-proxy-image)"
hermes_domain="$(metadata instance/attributes/hermes-domain)"
oauth_client_id="$(metadata instance/attributes/hermes-oauth-client-id)"
environment_secret="$(metadata instance/attributes/hermes-env-secret)"
require_pinned_image "${hermes_image}"
require_pinned_image "${proxy_image}"
require_domain "${hermes_domain}"
[[ "${oauth_client_id}" == agent:* && "${oauth_client_id}" != "agent:" ]]
[[ "${environment_secret}" == projects/*/secrets/*/versions/* ]]

token_json="$(metadata instance/service-accounts/default/token)"
access_token="$(TOKEN_JSON="${token_json}" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["TOKEN_JSON"])["access_token"])
PY
)"
unset token_json

install -d -m 0700 "${data_dir}"
secret_response="$(curl --fail --silent --show-error --retry 5 --retry-all-errors \
  --connect-timeout 5 --max-time 30 \
  --header "Authorization: Bearer ${access_token}" \
  "https://secretmanager.googleapis.com/v1/${environment_secret}:access")"
unset access_token

SECRET_RESPONSE="${secret_response}" ENVIRONMENT_FILE="${environment_file}" python3 - <<'PY'
import base64
import json
import os

payload = json.loads(os.environ["SECRET_RESPONSE"])["payload"]["data"]
with open(os.environ["ENVIRONMENT_FILE"], "wb") as environment:
    environment.write(base64.b64decode(payload, validate=True))
PY
unset secret_response
chmod 0600 "${environment_file}"

printf 'ziac-hermes: pulling reviewed image %s\n' "${hermes_image}"
docker pull "${hermes_image}"
printf 'ziac-hermes: pulling reviewed TLS edge %s\n' "${proxy_image}"
docker pull "${proxy_image}"

install -d -m 0700 "${edge_dir}/data" "${edge_dir}/config"
cat >"${edge_dir}/Caddyfile" <<EOF
${hermes_domain} {
  encode zstd gzip
  reverse_proxy 127.0.0.1:9119
}
EOF
chmod 0600 "${edge_dir}/Caddyfile"

docker rm --force "${container_name}" >/dev/null 2>&1 || true
docker run --detach \
  --name "${container_name}" \
  --restart unless-stopped \
  --env-file "${environment_file}" \
  --env HERMES_DASHBOARD=1 \
  --env HERMES_DASHBOARD_HOST=0.0.0.0 \
  --env HERMES_DASHBOARD_PORT=9119 \
  --env "HERMES_DASHBOARD_PUBLIC_URL=https://${hermes_domain}" \
  --env "HERMES_DASHBOARD_OAUTH_CLIENT_ID=${oauth_client_id}" \
  --mount "type=bind,source=${data_dir},target=/opt/data" \
  --publish 127.0.0.1:8642:8642 \
  --publish 127.0.0.1:9119:9119 \
  --label managed-by=ziac \
  --label compatibility=m84c \
  "${hermes_image}" gateway run >/dev/null

docker rm --force "${edge_container_name}" >/dev/null 2>&1 || true
docker run --detach \
  --name "${edge_container_name}" \
  --restart unless-stopped \
  --network host \
  --mount "type=bind,source=${edge_dir}/Caddyfile,target=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,source=${edge_dir}/data,target=/data" \
  --mount "type=bind,source=${edge_dir}/config,target=/config" \
  --label managed-by=ziac \
  --label compatibility=m84c \
  "${proxy_image}" >/dev/null

deadline=$((SECONDS + 60))
until [[ "$(docker inspect --format '{{.State.Running}}' "${container_name}" 2>/dev/null || true)" == "true" ]]; do
  if (( SECONDS >= deadline )); then
    docker logs --tail 40 "${container_name}" 2>&1 | sed -E 's/(TOKEN|KEY|SECRET|PASSWORD)=.*/\1=[REDACTED]/Ig' || true
    exit 1
  fi
  sleep 2
done

until [[ "$(docker inspect --format '{{.State.Running}}' "${edge_container_name}" 2>/dev/null || true)" == "true" ]]; do
  if (( SECONDS >= deadline )); then
    docker logs --tail 40 "${edge_container_name}" 2>&1 || true
    exit 1
  fi
  sleep 2
done

printf 'ziac-hermes: desktop backend ready behind https://%s; raw ports remain on localhost\n' "${hermes_domain}"
