# GCP Developer Researcher

Every `ziac init` project includes a read-only GCP documentation skill and a
harness-native `gcp-developer-researcher` agent for Codex, Claude Code, and
Gemini CLI. It is intended for current or uncertain questions about Google
Cloud APIs, IAM, quotas, regions, pricing inputs, lifecycle status, Cloud Run,
networking, billing, and provider constraints.

The generated MCP configuration connects to Google's official Developer
Knowledge endpoint:

```text
https://developerknowledge.googleapis.com/mcp
```

Create an API key for the Developer Knowledge API, keep it outside source, and
export it before starting the agent harness:

```sh
export DEVELOPERKNOWLEDGE_API_KEY='...'
```

`.env.example` names the variable but never contains a value. The generated
config exposes only `search_documents` and `get_documents`; it does not grant
cloud mutation authority. Google's Developer Knowledge API and remote MCP
server are Public Preview, so the researcher reports unavailability honestly
and falls back to official Google documentation rather than inventing an
answer.

The researcher scopes each question, ranks exact API/reference pages above
product guides, release notes, and concept pages, then fetches only the best
parent documents. Its response always separates the official finding from the
recommended Ziac implication, constraints, sources, confidence, and any
explicit inference.

Implementation agents are instructed to delegate time-sensitive GCP claims to
this specialist before changing provider behavior. Users may also invoke it
directly by name. The generated files are:

```text
.agents/skills/gcp-developer-research/SKILL.md
.claude/skills/gcp-developer-research/SKILL.md
.gemini/skills/gcp-developer-research/SKILL.md
.codex/agents/gcp-developer-researcher.toml
.claude/agents/gcp-developer-researcher.md
.gemini/agents/gcp-developer-researcher.md
```

At a monorepo root, Ziac installs Google-only MCP configuration without
pretending that the root owns a `ziac.project.json`. Child projects retain
their independent Ziac MCP servers and deployment boundaries.
