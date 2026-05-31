# Agent Observability Lab — Developer Spec

Internal spec for people (and agents) implementing the lab. User-facing surface lives in `README.md`; coding style in `CONVENTIONS.md`.

## Repository shape

```
agent-observability-lab/
├─ PRD.md / SPEC/ / CONVENTIONS.md / README.md   # repo-wide spec layer (owned by human + conversational LLM)
├─ prompt.md / ralph.sh / ralph.ps1              # Ralph Loop driver
└─ stacks/
   └─ <name>/                                    # one self-contained, `docker compose`-runnable stack per directory
```

Each stack under `stacks/<name>/` is independent: its own `docker-compose.yml`, `config/`, `scripts/`, `.env.example`, and `README.md`. A stack must run without reference to any other stack. New agent/backend combinations are added as sibling directories, never by entangling an existing stack.

## Stack: `claude-code-elastic`

### Goal

Demonstrate, end to end, what telemetry **Claude Code** emits and how the **Elastic Stack** ingests, stores, and visualizes it — both numeric **metrics** and structured **events**.

### Architecture

```
Claude Code  ──OTLP/HTTP (+gRPC)──▶  APM Server  ──▶  Elasticsearch  ──▶  Kibana
(metrics + events)                   (Elastic-native    (single-node,        (Discover /
                                      OTLP receiver)     security disabled)    APM UI / Dashboard)
```

- **APM Server** is the Elastic-native OTLP receiver. It accepts OTLP over HTTP and gRPC and writes directly to Elasticsearch — no upstream/contrib OpenTelemetry Collector is used in this stack (that comparison, if wanted, becomes a separate stack).
- **Elasticsearch** runs as a single node with security **disabled** — this is a local demo, not production (see Invariants).
- **Kibana** is the inspection surface: Discover for raw documents, the APM UI for the agent as an APM service, and an importable data view / dashboard.

### Signals Claude Code emits

Claude Code emits OpenTelemetry when `CLAUDE_CODE_ENABLE_TELEMETRY=1` is set, on two independent channels selected by exporter env vars:

- **Metrics** (`OTEL_METRICS_EXPORTER=otlp`) — counters/gauges such as session count, token usage (by type), estimated cost, lines of code added/removed, commit and pull-request counts, and active-time. Exported on the OTLP metrics pipeline.
- **Events / logs** (`OTEL_LOGS_EXPORTER=otlp`) — structured event records such as user prompts, tool-result events, and API-request events, each carrying attributes (model, token counts, decision/outcome, durations). Exported on the OTLP logs pipeline.

The exact metric names, event names, and attribute keys are part of what this lab exists to discover and document — the verification step records what actually lands in Elasticsearch rather than trusting this list verbatim. Both channels point at the same OTLP endpoint (the APM Server). Export cadence is controlled by the standard `OTEL_METRIC_EXPORT_INTERVAL` / `OTEL_LOGS_EXPORT_INTERVAL` knobs; the demo lowers them so data appears quickly.

### Configuration surface

- `stacks/claude-code-elastic/docker-compose.yml` — the three services with healthchecks and a shared network.
- `stacks/claude-code-elastic/config/` — service config files (e.g. APM Server config).
- `stacks/claude-code-elastic/.env.example` — Claude Code telemetry env vars (`CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_*`) pointed at the APM Server OTLP endpoint; copied to a real `.env` / shell export set by the user.
- `stacks/claude-code-elastic/scripts/` — smoke/verification scripts.

## Invariants

- **Demo posture, not production.** Security is disabled and ports bind to localhost; this stack must never be exposed publicly or pointed at sensitive infrastructure.
- **Events can contain prompt and tool content.** The events channel may carry user prompt text and tool I/O. Treat anything sent to this stack as potentially sensitive: do not run a telemetry-enabled Claude Code session containing secrets or confidential material against it, and never commit captured telemetry into the repo.
- **One version, pinned.** Elasticsearch, Kibana, and APM Server share a single pinned Elastic Stack version — currently **9.4.2**; bumping it is a deliberate, documented change.
- **Stacks stay self-contained.** No cross-stack file references or shared running services.
