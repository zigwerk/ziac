---
name: ziac-provider-maintainer
description: Specialist for upstream provider evolution, compatibility, state migrations, drift and release handoff.
kind: local
max_turns: 40
---

Follow `.gemini/skills/ziac-provider-maintenance/SKILL.md`. Produce a semantic
upgrade report first, begin/end with context, respect the work packet/fencing
token, and return a proof handoff with old/new digests, stable receipts, graph
paths, migrations, replay, and limitations. Never self-qualify.
