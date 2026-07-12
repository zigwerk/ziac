#!/usr/bin/env bash
set -euo pipefail

ziac_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mcp_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "${script_dir}/.." && pwd)"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/ziac-scaffold-e2e.XXXXXX")"
trap 'rm -rf "${workspace}"' EXIT

"${ziac_bin}" init global-api --dir "${workspace}/global-api" --ziac-path "${package_dir}"
cd "${workspace}/global-api"
zig build test --summary failures
zig build ziac-program -- --stack global-api --stage dev > "${workspace}/program.json"
grep -Fq '"schema":"ziac.program.v1"' "${workspace}/program.json"
"${ziac_bin}" check --stack global-api --stage dev --json > "${workspace}/check.json"
grep -Fq '"status":"valid"' "${workspace}/check.json"
"${ziac_bin}" plan --stack global-api --stage dev --json > "${workspace}/plan.json"
grep -Fq '"stack":"global-api"' "${workspace}/plan.json"
grep -Eq '"create":[1-9][0-9]*' "${workspace}/plan.json"
"${ziac_bin}" deploy --stack global-api --stage dev --json > "${workspace}/deploy.json"
grep -Fq '"status":"success"' "${workspace}/deploy.json"
"${ziac_bin}" plan --stack global-api --stage dev --json > "${workspace}/noop.json"
grep -Fq '"create":0' "${workspace}/noop.json"
grep -Fq '"update":0' "${workspace}/noop.json"
grep -Fq '"delete":0' "${workspace}/noop.json"
grep -Eq '"noop":[1-9][0-9]*' "${workspace}/noop.json"
"${ziac_bin}" dashboard --stack global-api --stage dev --artifact-only --out "${workspace}/dashboard.json" > "${workspace}/dashboard-receipt.json"
grep -Fq '"status":"ready"' "${workspace}/dashboard-receipt.json"
grep -Fq '"schema":"ziac.visual.v1"' "${workspace}/dashboard.json"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"ziac-e2e","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ziac_verify","arguments":{"acceptance_check":"check-global-api"}}}' |
  "${mcp_bin}" --project ziac.project.json --stack global-api --stage dev > "${workspace}/mcp.jsonl"
grep -Fq '"protocolVersion":"2025-11-25"' "${workspace}/mcp.jsonl"
grep -Fq '"name":"ziac_verify"' "${workspace}/mcp.jsonl"
grep -Fq 'ziac.verification-receipt.v1' "${workspace}/mcp.jsonl"
