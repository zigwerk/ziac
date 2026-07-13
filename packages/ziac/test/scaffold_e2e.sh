#!/usr/bin/env bash
set -euo pipefail

ziac_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mcp_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
dashboard_host_bin="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/ziac-scaffold-e2e.XXXXXX")"
trap 'rm -rf "${workspace}"' EXIT

test -f "$(dirname "${ziac_bin}")/../share/ziac/build.zig.zon"
test -f "$(dirname "${ziac_bin}")/../share/ziac/Dockerfile.self-host"
test -f "$(dirname "${ziac_bin}")/../share/ziac/cloudbuild.self-host.yaml"
test -x "$(dirname "${ziac_bin}")/../share/ziac/scripts/qualify-ziac-cloud.sh"
test -f "$(dirname "${ziac_bin}")/../share/ziac/docs/agent-development-kit.md"
test -f "$(dirname "${ziac_bin}")/../share/ziac/docs/gcp-developer-research.md"
test -f "$(dirname "${ziac_bin}")/../share/ziac/dashboard/dist/index.html"
test -f "$(dirname "${ziac_bin}")/../share/zigeffect/src/zigeffect.zig"
mkdir -p "${workspace}/global-api"
cd "${workspace}/global-api"
git init -q
"${ziac_bin}" init
grep -Fq 'share/ziac' build.zig.zon
test -f .git/HEAD
test -f .agents/skills/ziac/SKILL.md
test -f .claude/skills/ziac/SKILL.md
test -f .gemini/skills/ziac/SKILL.md
test -f .agents/skills/gcp-developer-research/SKILL.md
test -f .claude/skills/gcp-developer-research/SKILL.md
test -f .gemini/skills/gcp-developer-research/SKILL.md
test -f .codex/agents/gcp-developer-researcher.toml
test -f .claude/agents/gcp-developer-researcher.md
test -f .gemini/agents/gcp-developer-researcher.md
test -f .env.example
grep -Fq 'name: ziac' .agents/skills/ziac/SKILL.md
grep -Fq 'build.zig.zon' .agents/skills/ziac/SKILL.md
grep -Fq 'docs/agent-development-kit.md' .agents/skills/ziac/SKILL.md
grep -Fq 'docs/gcp-specialization.md' .agents/skills/gcp-developer-research/SKILL.md
cmp .agents/skills/ziac/SKILL.md .claude/skills/ziac/SKILL.md
cmp .agents/skills/ziac/SKILL.md .gemini/skills/ziac/SKILL.md
cmp .agents/skills/gcp-developer-research/SKILL.md .claude/skills/gcp-developer-research/SKILL.md
cmp .agents/skills/gcp-developer-research/SKILL.md .gemini/skills/gcp-developer-research/SKILL.md
grep -Fq 'https://developerknowledge.googleapis.com/mcp' .mcp.json
grep -Fq 'DEVELOPERKNOWLEDGE_API_KEY' .codex/config.toml
grep -Fq 'search_documents' .gemini/settings.json
grep -Fq 'permissionMode: plan' .claude/agents/gcp-developer-researcher.md
test "$(cat .env.example)" = 'DEVELOPERKNOWLEDGE_API_KEY='
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
"${dashboard_host_bin}" --server-only "${workspace}/dashboard.json" >"${workspace}/dashboard-host.out" 2>"${workspace}/dashboard-host.err" &
dashboard_pid=$!
dashboard_ready=false
for _ in $(seq 1 100); do
  if grep -Fq 'Ziac dashboard:' "${workspace}/dashboard-host.err"; then
    dashboard_ready=true
    break
  fi
  if ! kill -0 "${dashboard_pid}" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
kill "${dashboard_pid}" 2>/dev/null || true
wait "${dashboard_pid}" 2>/dev/null || true
test "${dashboard_ready}" = true
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"ziac-e2e","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ziac_verify","arguments":{"acceptance_check":"check-global-api"}}}' |
  "${mcp_bin}" --project ziac.project.json --stack global-api --stage dev > "${workspace}/mcp.jsonl"
grep -Fq '"protocolVersion":"2025-11-25"' "${workspace}/mcp.jsonl"
grep -Fq '"name":"ziac_verify"' "${workspace}/mcp.jsonl"
grep -Fq 'ziac.verification-receipt.v1' "${workspace}/mcp.jsonl"

mkdir -p "${workspace}/ziac-cloud/platform" "${workspace}/ziac-cloud/services/payments/infra"
cd "${workspace}/ziac-cloud"
git init -q
(
  cd platform
  "${ziac_bin}" init platform --dir .
)
(
  cd services/payments/infra
  "${ziac_bin}" init payments --dir .
)
test -f .agents/skills/ziac/SKILL.md
test -f .claude/skills/ziac/SKILL.md
test -f .gemini/skills/ziac/SKILL.md
test -f .agents/skills/gcp-developer-research/SKILL.md
test -f .claude/agents/gcp-developer-researcher.md
test -f .gemini/agents/gcp-developer-researcher.md
test -f .codex/agents/gcp-developer-researcher.toml
grep -Fq 'google-developer-knowledge' .mcp.json
if grep -Fq 'ziac.project.json' .mcp.json; then
  echo 'workspace root MCP configuration points at a child project' >&2
  exit 1
fi
grep -Fq 'merged canvas' .agents/skills/ziac/SKILL.md
grep -Fq '"dashboard": { "stack": "global-api", "stage": "dev" }' platform/ziac.project.json
"${ziac_bin}" dashboard --artifact-only --out "${workspace}/workspace-dashboard.json" > "${workspace}/workspace-dashboard-receipt.json"
grep -Fq '"schema":"ziac.workspace-dashboard-artifact.v1"' "${workspace}/workspace-dashboard-receipt.json"
grep -Fq '"projects":2' "${workspace}/workspace-dashboard-receipt.json"
grep -Fq '"schema":"ziac.workspace-visual.v1"' "${workspace}/workspace-dashboard.json"
grep -Fq '"project":"payments"' "${workspace}/workspace-dashboard.json"
grep -Fq '"project":"platform"' "${workspace}/workspace-dashboard.json"

mkdir -p "${workspace}/self-host"
cd "${workspace}/self-host"
git init -q
"${ziac_bin}" init --preset ziac-cloud --yes
test -f platform/bootstrap/ziac.project.json
test -f platform/data/ziac.project.json
test -f platform/control-plane/ziac.project.json
test -f platform/billing/ziac.project.json
test -f .agents/skills/gcp-developer-research/SKILL.md
test -f .claude/agents/gcp-developer-researcher.md
test -f .gemini/agents/gcp-developer-researcher.md
grep -Fq 'google-developer-knowledge' .mcp.json
grep -Fq 'buildBootstrap' platform/bootstrap/ziac.stack.zig
grep -Fq 'buildData' platform/data/ziac.stack.zig
grep -Fq 'buildControlPlane' platform/control-plane/ziac.stack.zig
grep -Fq 'buildBilling' platform/billing/ziac.stack.zig
grep -Fq 'all four projects' README.md
(
  cd platform/bootstrap
  "${ziac_bin}" check --stack bootstrap --stage prod --json > "${workspace}/self-host-bootstrap-check.json"
)
(
  cd platform/data
  "${ziac_bin}" check --stack data --stage prod --json > "${workspace}/self-host-data-check.json"
)
(
  cd platform/control-plane
  "${ziac_bin}" check --stack control-plane --stage prod --json > "${workspace}/self-host-control-check.json"
)
(
  cd platform/billing
  "${ziac_bin}" check --stack billing --stage prod --json > "${workspace}/self-host-billing-check.json"
)
grep -Fq '"status":"valid"' "${workspace}/self-host-bootstrap-check.json"
grep -Fq '"status":"valid"' "${workspace}/self-host-data-check.json"
grep -Fq '"status":"valid"' "${workspace}/self-host-control-check.json"
grep -Fq '"status":"valid"' "${workspace}/self-host-billing-check.json"
"${ziac_bin}" dashboard --artifact-only --out "${workspace}/self-host-dashboard.json" > "${workspace}/self-host-dashboard-receipt.json"
grep -Fq '"projects":4' "${workspace}/self-host-dashboard-receipt.json"
grep -Fq '"schema":"ziac.workspace-visual.v1"' "${workspace}/self-host-dashboard.json"
