# Rapid Development

Ziac has two development loops with one project contract.

## Local hot reload

```sh
ziac dev --project ziac.project.json --stack global-api --stage dev --watch
```

The generated project's fixed build and process argv are supervised behind one
stable local URL. A generation receives traffic only after its declared health
check succeeds. Failed builds and failed readiness preserve the last healthy
generation.

## Cloud revision rollout

First save an immutable plan for the current user program:

```sh
ziac plan \
  --project ziac.project.json \
  --stack global-api \
  --stage dev \
  --provider gcp \
  --allow-live \
  --out .ziac/plans/dev-watch.json
```

After the source build has produced an Artifact Registry digest, roll that image
through every Cloud Run service selected by the compiled graph:

```sh
ziac deploy \
  --project ziac.project.json \
  --stack global-api \
  --stage dev \
  --provider gcp \
  --allow-live \
  --watch \
  --plan .ziac/plans/dev-watch.json \
  --image europe-west1-docker.pkg.dev/PROJECT/apps/api@sha256:DIGEST
```

The CLI does not accept a tagged image or a caller-invented approval. It parses
and integrity-checks the saved plan, checks its stack, stage and desired graph,
derives the exact capability digest, then performs the rollout through Cloud Run
v2. The candidate revision is created with traffic pinned to the prior healthy
revision. Traffic moves only after the LRO and service readiness contract agree.

Each image, revision, readiness and traffic phase is emitted as JSONL and saved
under `.ziac/logs/<stack>/<stage>/events.jsonl`, where the dashboard and agent
tools can inspect the same causal chain.

Production stages and destructive plans are deliberately excluded from watch
mode. Use the normal saved-plan deployment path for those changes.
