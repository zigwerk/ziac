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
test -f "$(dirname "${ziac_bin}")/../share/ziac/docs/gcp-provider-coverage.md"
test -f "$(dirname "${ziac_bin}")/../share/ziac/docs/gcp-organization-foundation.md"
test -f "$(dirname "${ziac_bin}")/../share/ziac/agent-kit/skills/ziac-provider-development/SKILL.md"
test -f "$(dirname "${ziac_bin}")/../share/ziac/agent-kit/skills/ziac-provider-maintenance/SKILL.md"
test -f "$(dirname "${ziac_bin}")/../share/ziac/agent-kit/skills/ziac-provider-qualification/SKILL.md"
test -f "$(dirname "${ziac_bin}")/../share/ziac/agent-kit/agents/codex/ziac-provider-creator.toml"
test -f "$(dirname "${ziac_bin}")/../share/ziac/docs/gcp-connectivity.md"
test -x "$(dirname "${ziac_bin}")/../share/ziac/scripts/qualify-connectivity.sh"
test -f "$(dirname "${ziac_bin}")/../share/ziac/docs/gcp-container-platform.md"
test -x "$(dirname "${ziac_bin}")/../share/ziac/scripts/qualify-container-platform.sh"
test -f "$(dirname "${ziac_bin}")/../share/ziac/docs/gcp-monitoring.md"
test -x "$(dirname "${ziac_bin}")/../share/ziac/scripts/qualify-monitoring.sh"
test -x "$(dirname "${ziac_bin}")/../share/ziac/scripts/qualify-data-engineering.sh"
test -f "$(dirname "${ziac_bin}")/../share/ziac/docs/gcp-event-integration.md"
test -x "$(dirname "${ziac_bin}")/../share/ziac/scripts/qualify-event-integration.sh"
test -f "$(dirname "${ziac_bin}")/../share/ziac/dashboard/dist/index.html"
test -f "$(dirname "${ziac_bin}")/../share/zigeffect/src/zigeffect.zig"
test -f "$(dirname "${ziac_bin}")/../share/ziac-gcpx/build.zig.zon"
test -f "$(dirname "${ziac_bin}")/../share/ziac-templates/index.json"
test -x "$(dirname "${ziac_bin}")/ziac-provider-gcp"
test -x "$(dirname "${ziac_bin}")/ziac-provider-cockroach"
"${ziac_bin}" registry list --json > "${workspace}/registry.json"
grep -Fq '"schema":"ziac.registry-search.v1"' "${workspace}/registry.json"
grep -Fq '"count":7' "${workspace}/registry.json"
grep -Fq 'ziac-gcpx/asset-bucket' "${workspace}/registry.json"
grep -Fq 'ziac/global-zig-api' "${workspace}/registry.json"
grep -Fq 'ziac-provider/gcp' "${workspace}/registry.json"
grep -Fq 'ziac-provider/cockroach' "${workspace}/registry.json"
"${ziac_bin}" registry search gcp --kind provider --json > "${workspace}/registry-gcp-provider.json"
grep -Fq '"count":1' "${workspace}/registry-gcp-provider.json"
grep -Fq 'ziac-provider/gcp' "${workspace}/registry-gcp-provider.json"
"${ziac_bin}" registry search hermes --kind template --json > "${workspace}/registry-hermes.json"
grep -Fq '"count":1' "${workspace}/registry-hermes.json"
grep -Fq 'ziac/hermes-desktop' "${workspace}/registry-hermes.json"
"${ziac_bin}" package verify "$(dirname "${ziac_bin}")/../share/ziac-templates/templates/hermes-desktop" > "${workspace}/package-verification.json"
grep -Fq '"status":"valid"' "${workspace}/package-verification.json"
grep -Fq '0eea7a4e3e153658f6006fc635ee7bcf6c615f9a3a0d074d228a6f563afda5bb' "${workspace}/package-verification.json"
mkdir -p "${workspace}/global-api"
cd "${workspace}/global-api"
git init -q
"${ziac_bin}" init
grep -Fq 'share/ziac' build.zig.zon
test -f zigeffect.project.json
test -f .zigeffect/compatibility.json
grep -Fq '"template_version":13' .zigeffect/compatibility.json
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
for skill in ziac-provider-development ziac-provider-maintenance ziac-provider-qualification; do
  test -f ".agents/skills/${skill}/SKILL.md"
  test -f ".claude/skills/${skill}/SKILL.md"
  test -f ".gemini/skills/${skill}/SKILL.md"
  cmp ".agents/skills/${skill}/SKILL.md" ".claude/skills/${skill}/SKILL.md"
  cmp ".agents/skills/${skill}/SKILL.md" ".gemini/skills/${skill}/SKILL.md"
done
for agent in ziac-provider-creator ziac-provider-maintainer ziac-provider-qualifier; do
  test -f ".codex/agents/${agent}.toml"
  test -f ".claude/agents/${agent}.md"
  test -f ".gemini/agents/${agent}.md"
done
test -f .env.example
grep -Fq 'name: ziac' .agents/skills/ziac/SKILL.md
grep -Fq 'build.zig.zon' .agents/skills/ziac/SKILL.md
grep -Fq 'docs/agent-development-kit.md' .agents/skills/ziac/SKILL.md
grep -Fq 'docs/gcp-provider-coverage.md' .agents/skills/ziac/SKILL.md
grep -Fq 'ziac provider resources --json' .agents/skills/ziac/SKILL.md
grep -Fq '## Ecosystem layers' .agents/skills/ziac/SKILL.md
grep -Fq 'ziac registry search' .agents/skills/ziac/SKILL.md
grep -Fq 'ziac package verify' .agents/skills/ziac/SKILL.md
grep -Fq 'ziac_context' .agents/skills/ziac/SKILL.md
grep -Fq 'zigeffect agent context' .agents/skills/ziac/SKILL.md
grep -Fq '.zigeffect/tests/process-receipts/' .agents/skills/ziac/SKILL.md
grep -Fq '.zigeffect/tests/raw-receipts/' .agents/skills/ziac/SKILL.md
grep -Fq '.zigeffect/handoffs/tests/' .agents/skills/ziac/SKILL.md
grep -Fq 'zigeffect graph path' .agents/skills/ziac/SKILL.md
grep -Fq 'work packet' .agents/skills/ziac/SKILL.md
grep -Fq 'Re-query' .agents/skills/ziac/SKILL.md
grep -Fq 'docs/gcp-specialization.md' .agents/skills/gcp-developer-research/SKILL.md
cmp .agents/skills/ziac/SKILL.md .claude/skills/ziac/SKILL.md
cmp .agents/skills/ziac/SKILL.md .gemini/skills/ziac/SKILL.md
cmp .agents/skills/gcp-developer-research/SKILL.md .claude/skills/gcp-developer-research/SKILL.md
cmp .agents/skills/gcp-developer-research/SKILL.md .gemini/skills/gcp-developer-research/SKILL.md
grep -Fq 'https://developerknowledge.googleapis.com/mcp' .mcp.json
grep -Fq 'DEVELOPERKNOWLEDGE_API_KEY' .codex/config.toml
grep -Fq 'search_documents' .gemini/settings.json
grep -Fq 'permissionMode: plan' .claude/agents/gcp-developer-researcher.md
grep -Fq 'ziac.provider.rpc.v1' .agents/skills/ziac-provider-development/SKILL.md
grep -Fq 'semantic upgrade report' .agents/skills/ziac-provider-maintenance/SKILL.md
grep -Fq 'immutable package digest' .agents/skills/ziac-provider-qualification/SKILL.md
grep -Fq 'agents.ziac_provider_creator' .codex/config.toml
"${ziac_bin}" provider resources --service storage --json > "${workspace}/provider-resources.json"
grep -Fq '"schema":"ziac.gcp.provider-coverage.v1"' "${workspace}/provider-resources.json"
grep -Fq 'gcp.storage.Bucket' "${workspace}/provider-resources.json"
if grep -Fq 'gcp.pubsub.Topic' "${workspace}/provider-resources.json"; then
  echo 'provider resource service filter included an unrelated service' >&2
  exit 1
fi
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

mkdir -p "${workspace}/templates/global-zig-api"
(
  cd "${workspace}/templates/global-zig-api"
  git init -q
  "${ziac_bin}" init global-template --template global-zig-api --dir . --yes
  test -f .agents/skills/ziac/SKILL.md
  test -f zigeffect.project.json
  test -f .zigeffect/compatibility.json
  zig build test --summary failures
  zig build ziac-program -- --stack global-api --stage dev > "${workspace}/template-global-program.json"
)
grep -Fq '"schema":"ziac.program.v1"' "${workspace}/template-global-program.json"
grep -Fq 'gcp.run.Service.global.api' "${workspace}/template-global-program.json"

mkdir -p "${workspace}/templates/hermes-desktop"
(
  cd "${workspace}/templates/hermes-desktop"
  git init -q
  "${ziac_bin}" init hermes-template --template hermes-desktop --dir . --yes
  test -f zigeffect.project.json
  test -f .zigeffect/compatibility.json
  zig build test --summary failures
  zig build ziac-program -- --stack hermes-desktop --stage dev > "${workspace}/template-hermes-program.json"
)
grep -Fq '"package":"ziac-gcpx"' "${workspace}/template-hermes-program.json"
grep -Fq '"name":"HermesDesktop"' "${workspace}/template-hermes-program.json"

mkdir -p "${workspace}/templates/event-driven-zig"
(
  cd "${workspace}/templates/event-driven-zig"
  git init -q
  "${ziac_bin}" init events-template --template event-driven-zig --dir . --yes
  test -f zigeffect.project.json
  test -f .zigeffect/compatibility.json
  zig build test --summary failures
  zig build ziac-program -- --stack event-worker --stage dev > "${workspace}/template-events-program.json"
)
grep -Fq '"package":"ziac-gcpx"' "${workspace}/template-events-program.json"
grep -Fq '"name":"AssetBucket"' "${workspace}/template-events-program.json"

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
test -f .agents/skills/ziac-provider-development/SKILL.md
test -f .claude/agents/ziac-provider-maintainer.md
test -f .gemini/agents/ziac-provider-qualifier.md
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
