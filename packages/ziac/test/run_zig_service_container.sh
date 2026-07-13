#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
context="$root/examples/zig-service-app"
dockerfile="$root/test/fixtures/zig-service/Dockerfile.ziac"
containers=()
images=()

cleanup() {
  for container in "${containers[@]:-}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  for image in "${images[@]:-}"; do
    docker image rm "$image" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

native_arch="$(docker info --format '{{.Architecture}}')"
case "$native_arch" in
  aarch64) native_arch=arm64 ;;
  x86_64) native_arch=amd64 ;;
esac

probe_platform() {
  local platform="$1"
  local arch="${platform##*/}"
  local image="ziac-sample-api:e2e-${arch}-$$"
  images+=("$image")

  docker buildx build \
    --load \
    --platform "$platform" \
    --tag "$image" \
    --file "$dockerfile" \
    "$context"

  test "$(docker image inspect "$image" --format '{{.Config.User}}')" = "nonroot:nonroot"
  test "$(docker image inspect "$image" --format '{{.Architecture}}')" = "$arch"

  local container
  container="$(docker run -d --platform "$platform" -p 127.0.0.1::8080 "$image")"
  containers+=("$container")
  local port
  port="$(docker port "$container" 8080/tcp | sed 's/.*://')"
  local response=""
  for _ in $(seq 1 50); do
    if response="$(curl --max-time 2 -fsS "http://127.0.0.1:$port/health/startup")"; then
      break
    fi
    sleep 0.2
  done

  test "$response" = '{"status":"ok"}'
  test "$(curl --max-time 2 -fsS "http://127.0.0.1:$port/health/live")" = '{"status":"ok"}'
  test "$(curl --max-time 2 -fsS "http://127.0.0.1:$port/")" = '{"status":"ok"}'
  test "$(curl --max-time 2 -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/missing")" = "404"

  docker rm -f "$container" >/dev/null
  containers=("${containers[@]:0:${#containers[@]}-1}")
  printf 'ZigService container passed: platform=%s user=nonroot:nonroot\n' "$platform"
}

if [[ "${1:-}" == "--all" ]]; then
  probe_platform linux/amd64
  probe_platform linux/arm64
else
  probe_platform "linux/$native_arch"
fi
