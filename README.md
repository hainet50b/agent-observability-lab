# Agent Observability Lab

A runnable lab for seeing exactly what telemetry an AI coding agent emits, and how an observability backend ingests it.

## Features

- **Self-contained stacks.** Each experiment lives under `stacks/<name>/` and runs on its own with `docker compose up` — no shared state between stacks.
- **Real signals, not vendor docs.** Each stack pipes an AI coding agent's telemetry into a real backend, so you inspect the actual **metrics** (sessions, tokens, cost, …) and **events** (prompts, tool results, API requests) it emits — the exact fields, not an abstract list.
- **Local-first and disposable.** Single-node, security-disabled demo posture — clone, bring it up, look at the data, tear it down.

## Two concerns

Each stack exercises one of two concerns, and the backend it composes follows from that:

- **Telemetry** — the agent's OpenTelemetry **metrics / events / traces** over OTLP, ingested by an Elastic backend that includes **APM Server**. This is the analytics view: sessions, tokens, cost, code edits, prompts, tool results, API requests.
- **Audit** — a record of **what a session did** (each prompt, each tool call), written **directly to Elasticsearch** by fail-open agent hooks. No APM Server, no OTLP — a separate `*-elastic-audit` backend (Elasticsearch + Kibana only).

Telemetry and audit are **alternatives, not co-run**: each owns its own agent home and Docker volumes, and all stacks share the same `aol-*` container names and host ports — so run **one stack at a time**.

## Stacks

Every stack is self-contained — pick one below and follow its README: bring it up with `docker compose up -d`, run its `setup.sh`, point the agent at it, and inspect what lands in the backend.

| Stack | Agent | Concern | Transport | Backend |
| --- | --- | --- | --- | --- |
| [`claude-code-elastic`](stacks/claude-code-elastic/) | Claude Code | telemetry | direct OTLP → APM Server | Elasticsearch + Kibana + APM Server |
| [`claude-code-otelcol-elastic`](stacks/claude-code-otelcol-elastic/) | Claude Code | telemetry | via local OpenTelemetry Collector | Elasticsearch + Kibana + APM Server |
| [`codex-cli-elastic`](stacks/codex-cli-elastic/) | Codex CLI | telemetry | direct OTLP → APM Server | Elasticsearch + Kibana + APM Server |
| [`claude-code-elastic-audit`](stacks/claude-code-elastic-audit/) | Claude Code | audit | direct hook → Elasticsearch | Elasticsearch + Kibana |
| [`codex-cli-elastic-audit`](stacks/codex-cli-elastic-audit/) | Codex CLI | audit | direct hook → Elasticsearch | Elasticsearch + Kibana |
