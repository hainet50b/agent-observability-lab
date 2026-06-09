# Agent Observability Lab — Developer Spec

Internal spec for people (and agents) implementing the lab. User-facing surface lives in `README.md`; coding style in `CONVENTIONS.md`.

## Repository shape

```
agent-observability-lab/
├─ PRD.md / SPEC/ / CONVENTIONS.md / README.md   # repo-wide spec layer (owned by human + conversational LLM)
├─ prompt.md / ralph.sh / ralph.ps1              # Ralph Loop driver
├─ components/                                   # reusable building blocks composed by stacks
│  ├─ backends/<backend>/                        # backend services, backend-side config, cross-agent Kibana/UI assets, bootstrap scripts
│  ├─ paths/<path>/                              # transport-layer addition between agent and backend (e.g. otelcol-sidecar)
│  └─ agents/<agent>/                            # agent-specific telemetry-config templates and per-agent Kibana/UI assets
└─ stacks/
   └─ <combo>/                                   # one composition (Backends × Path? × Agents): docker-compose `include:` + Quick Tour README + any combination-specific glue
```

A stack composes one or more Backends, optionally a Path, and one or more Agents by `include:`ing the relevant component compose files; the stack directory carries only the combination's `README.md` and any glue that is specific to *that* combination (e.g. a fan-out Collector config enumerating multiple Backends). The typical stack is 1×1×1, but multi-Backend fan-out (one Collector to several backends) and multi-Agent (several agents on one Backend) are first-class compositions. The **direct** path — agent talking straight to the Backend over the network — has no `paths/` component; a direct stack simply includes the Backend alone.

Component responsibilities:

- **`components/backends/<backend>/`** owns backend services (`docker-compose.yml`), backend-side config (`elasticsearch.yml`, `apm-server.yml`, ingest pipelines, …), cross-agent Kibana / UI assets (data views and dashboards that span agents), and the backend's bootstrap / import scripts.
- **`components/paths/<path>/`** owns transport-layer services (e.g. a local OpenTelemetry Collector) and their default config. Non-trivial wiring (multi-Backend fan-out, alternative pipelines) is expressed as a per-stack configuration override rather than by parameterizing the path component, so each composition stays explainable from its own files.
- **`components/agents/<agent>/`** owns the agent's telemetry-config template (the `OTEL_*` block, `managed-settings.json` excerpt) and per-agent Kibana / UI assets (data views, saved searches, dashboards scoped to that agent's data stream).

Each stack's own `README.md` is the **operational Quick Tour** — bring it up, point a session at it, import the Kibana objects, view, tear down — see `stacks/claude-code-elastic/README.md`. The developer-facing **deep references** (per-signal field reference, Kibana-view design, threat model) live beside this spec under `SPEC/` and are indexed in [Reference documents](#reference-documents) below; the user-facing `README.md` files deliberately do **not** link into `SPEC/` (they stay self-contained).

## Invariants

- **Demo posture, not production.** Stacks run locally with security relaxed and ports bound to localhost; never expose one publicly or point it at sensitive infrastructure.
- **Telemetry can carry sensitive content.** Agent telemetry may include prompt text and tool I/O — treat anything sent to a stack as sensitive: don't run a telemetry-enabled session containing secrets, and never commit captured telemetry into the repo.
- **Components are composable; stacks are compositions.** Reusable building blocks live under `components/{backends,paths,agents}/<name>/`. Each stack under `stacks/<combo>/` is one composition expressed as a `docker compose include:` over those components, plus the combination's `README.md` and any combination-specific glue — no services are defined inline in `stacks/<combo>/`.
- **Stacks share definitions, never runtime state.** Component volumes stay Compose-project-scoped — never give a volume a fixed `name:` or mark it `external:` to share data across stacks. Comparing multiple agents in one backend is done by composing those agents into **one** stack.

## Audit-coverage scope

Telemetry-as-audit in this lab targets the **non-adversarial / network-reliability** threat model only; the adversarial / audit-evasion model is explicitly out of scope and belongs to endpoint-security tooling outside the lab. This framing is what motivates the planned `*-otelcol-*` sidecar variants of every direct stack. The full rationale, the (A)/(B) distinction, the sidecar + `file_storage` solution, and the real cost of fleet rollout are in [`threat-model.md`](threat-model.md).

## Reference documents

Developer-facing references that sit beside this spec. The user-facing `README.md` files do **not** link into these — they are found here, via `SPEC/`:

- [`threat-model.md`](threat-model.md) — audit-coverage threat model: the (A) non-adversarial / (B) adversarial split, why telemetry only solves (A), and the local-sidecar (`file_storage`) solution the `*-otelcol-*` stacks demonstrate.
- [`claude-code-telemetry.md`](claude-code-telemetry.md) — what Claude Code emits into the `claude-code-elastic` stack: every metric / event / span field, the string-vs-numeric and PII caveats, the trace data model, and the trace-isolation routing.
- [`codex-cli-telemetry.md`](codex-cli-telemetry.md) — what OpenAI Codex CLI emits into the `codex-cli-elastic` stack: the real `service.name` (`codex_cli_rs`), the dual `log_only`/`trace_safe` log families (identity+content vs `event_name`, joined on `call_id`/`span.id`), the metric/event catalogs, the WebSocket-vs-SSE transport split, and the pending trace-isolation routing.
- [`kibana-saved-objects.md`](kibana-saved-objects.md) — the design of the stack's Kibana data views, saved searches, and dashboard: the curated columns and the reasoning, why saved searches rather than data views, and how to regenerate the NDJSON.
