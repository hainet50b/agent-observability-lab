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
- **Kibana** is the inspection surface: Discover for raw documents (two importable data views — one for the metrics stream, one for the events stream), per-`message` **saved searches** layered on the events data view for curated columns, the APM UI for the agent as an APM service, and dashboards. A Kibana *data view* is only an index-pattern + time field — it cannot store a query or column selection, so message-filtered views are modeled as *saved searches* (saved-object type `search`), not as additional data views.
- **Saved-search convention:** express each saved search's constraints (`message`, `service.name`) as **filter pills** — `phrase` entries in `searchSourceJSON.filter[]`, each referencing the data view through a `references[]` entry — rather than as query-bar KQL text. Pills render as labelled, removable blocks in Discover, which read clearly for non-expert viewers; the query bar is left empty.

### Signals Claude Code emits

Claude Code emits OpenTelemetry when `CLAUDE_CODE_ENABLE_TELEMETRY=1` is set, on two independent channels selected by exporter env vars:

- **Metrics** (`OTEL_METRICS_EXPORTER=otlp`) — counters/gauges such as session count, token usage (by type), estimated cost, lines of code added/removed, commit and pull-request counts, and active-time. Exported on the OTLP metrics pipeline.
- **Events / logs** (`OTEL_LOGS_EXPORTER=otlp`) — structured event records such as user prompts, tool-result events, and API-request events, each carrying attributes (model, token counts, decision/outcome, durations). Exported on the OTLP logs pipeline.

The exact metric names, event names, and attribute keys are part of what this lab exists to discover and document — the verification step records what actually lands in Elasticsearch rather than trusting this list verbatim. Both channels point at the same OTLP endpoint (the APM Server). Export cadence is controlled by the standard `OTEL_METRIC_EXPORT_INTERVAL` / `OTEL_LOGS_EXPORT_INTERVAL` knobs; the demo lowers them so data appears quickly.

### Shape in Elasticsearch

How the signals land — structural facts that hold across versions even as the exact names evolve:

- **Two data streams:** `metrics-apm.app.claude_code-default` (metrics) and `logs-apm.app.claude_code-default` (events). APM Server additionally emits an essentially empty `metrics-apm.service_summary.1m` marker, which is not a useful visualization target.
- **Where the value/type lives:** a metric's value is stored in a field **named after the metric** (e.g. `claude_code.token.usage`); an event's **type is in the `message` field** (e.g. `claude_code.api_request`).
- **Attribute split:** OTLP string attributes surface under `labels.*` and numeric ones under `numeric_labels.*` (key `.` → `_`). ⚠️ This split is **not consistent across events** — some (e.g. `tool_result`, `hook_*`) carry numbers like `duration_ms` as **string** `labels`, which blocks numeric aggregation in Lens without a runtime-field cast.
- **Identity:** `service.name` is `claude-code` (the smoke probe uses `cce-smoke-test`); `session.id` is promoted to a top-level field; `labels.user_email` / `labels.user_id` and (when `OTEL_LOG_USER_PROMPTS=1`) `labels.prompt` are PII and must not be baked into shared saved objects.

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
