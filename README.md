# Agent Observability Lab

A runnable lab for seeing exactly what telemetry an AI coding agent emits, and how an observability backend ingests it.

## Features

- **Self-contained stacks.** Each experiment lives under `stacks/<name>/` and runs on its own with `docker compose up` — no shared state between stacks.
- **Real signals, not vendor docs.** Each stack pipes an AI coding agent's telemetry into a real backend, so you inspect the actual **metrics** (sessions, tokens, cost, …) and **events** (prompts, tool results, API requests) it emits — the exact fields, not an abstract list.
- **Local-first and disposable.** Single-node, security-disabled demo posture — clone, bring it up, look at the data, tear it down.

## Two concerns

Each stack exercises one of two concerns, and the backend it composes follows from that:

- **Telemetry** — the agent's OpenTelemetry **metrics / events / traces** over OTLP, ingested by an Elastic backend that includes **APM Server**. The analytics view: sessions, tokens, cost, code edits, prompts, tool results, API requests.
- **Audit** — a record of **what a session did** (each prompt, each tool call), written **directly to Elasticsearch** by fail-open agent hooks. No APM Server, no OTLP — the same Elastic backend composed without the APM Server fragment (Elasticsearch + Kibana only). See [`SPEC/agent-audit.md`](SPEC/agent-audit.md).

Telemetry and audit are **alternatives, not co-run**: each owns its own agent home and Docker volumes, and all stacks share the same `aol-*` container names and host ports — so run **one stack at a time**.

## Stacks

Four stacks — two telemetry, two audit. Pick one, follow its README: `docker compose up -d`, run its `scripts/setup.sh`, point the agent at it, inspect the backend.

| Stack | Agent | Concern | Backend | Data-plane key (`agent-config.toml`) | Ports |
| --- | --- | --- | --- | --- | --- |
| [`claude-elastic`](stacks/claude-elastic/) | Claude | telemetry | Elasticsearch + Kibana + APM Server | `telemetry.apm_server.endpoint` (direct OTLP) | 9200 / 5601 / 8200 |
| [`codex-elastic`](stacks/codex-elastic/) | Codex | telemetry | Elasticsearch + Kibana + APM Server | `telemetry.apm_server.endpoint` (direct OTLP) | 9200 / 5601 / 8200 |
| [`claude-elastic-audit`](stacks/claude-elastic-audit/) | Claude | audit | Elasticsearch + Kibana | `agent_audit.*` (direct hook → ES) | 9200 / 5601 |
| [`codex-elastic-audit`](stacks/codex-elastic-audit/) | Codex | audit | Elasticsearch + Kibana | `agent_audit.*` (direct hook → ES) | 9200 / 5601 |

All four reuse the same fixed `aol-*` container names and host ports — run only one at a time. How config is deployed across the `local` / `project` / `managed` scopes is shared: see [`SPEC/config-deployment.md`](SPEC/config-deployment.md).
