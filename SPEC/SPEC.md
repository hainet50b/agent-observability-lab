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

- **`components/backends/<backend>/`** owns backend services (`docker-compose.yml`), backend-side config (`elasticsearch.yml`, `apm-server.yml`, ingest pipelines — including agent-specific ones such as `logs-drop` / `trace-routing`, since they execute in Elasticsearch), **all Kibana / UI assets** — both cross-agent and the per-source ones scoped to a single agent/path — and the import mechanism that loads them. Per-source assets are namespaced under the backend (e.g. `kibana/<source>/`).
- **`components/paths/<path>/`** owns transport-layer services (e.g. a local OpenTelemetry Collector) and their default config. Non-trivial wiring (multi-Backend fan-out, alternative pipelines) is expressed as a per-stack configuration override rather than by parameterizing the path component, so each composition stays explainable from its own files. (Its Kibana assets, being Kibana-consumed, live under the backend like an agent's — see the placement rule below.)
- **`components/agents/<agent>/`** owns only what the **agent runtime** consumes: the agent's telemetry-config templates (the `[otel]` / MCP / hooks `config.toml` blocks, `managed-settings.json` excerpt), its hook scripts, and the hook-delivery config they read (`agent-audit.conf`) — plus the render scripts that materialize them into the agent home. It owns **no** Kibana assets.

**Placement rule.** An artifact lives with **the runtime that consumes it**, not with whatever it describes. The agent process and its hooks read the `config.toml` templates / `agent-audit.conf` → `agents/`. Elasticsearch and Kibana consume the ingest pipelines and the Kibana saved objects — even when those are scoped to one agent's fields → `backends/` (per-source assets namespaced). "It's about agent X" is not the criterion: a `service.name`-gated ingest pipeline and a single-agent saved search are agent-specific in content yet are backend artifacts, because ES / Kibana are what run them.

Backends can be specialized variants. **`elastic`** carries the full OTLP ingest path — Elasticsearch + Kibana + **APM Server** — for agent *telemetry* (metrics / logs / traces). **`elastic-audit`** is the same store **without APM Server**, for the *audit* concern, whose hooks write straight to Elasticsearch and never traverse the OTLP / APM path. Telemetry and audit are composed as **separate stacks** (e.g. `codex-cli-elastic` vs `codex-cli-elastic-audit`) — not for physical isolation (the lab is single-node) but to keep each stack's **load-bearing set legible**: the audit stack's compose visibly carries no APM Server, and its agent home (`.codex` / `.claude`) holds only the audit config. The two are **alternatives, not co-run**; each owns its own agent home and volumes. A future `claude-code-elastic-audit` reuses the `elastic-audit` backend wholesale, adding only Claude Code's audit hooks.

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
- [`agent-audit.md`](agent-audit.md) — direct agent-audit data streams and hook delivery: canonical user-prompt schema, mapping/lifecycle defaults, fail-open delivery, and hook-specific configuration.
- [`claude-code-telemetry.md`](claude-code-telemetry.md) — what Claude Code emits into the `claude-code-elastic` stack: every metric / event / span field, the string-vs-numeric and PII caveats, the trace data model, and the trace-isolation routing.
- [`codex-cli-telemetry.md`](codex-cli-telemetry.md) — what OpenAI Codex CLI emits into the `codex-cli-elastic` stack: the real `service.name` (`codex_cli_rs`), the dual `log_only`/`trace_safe` log families (identity+content vs `event_name`, joined on `call_id`/`span.id`), the metric/event catalogs, the WebSocket-vs-SSE transport split, and the pending trace-isolation routing.
- [`codex-cli-managed-config.md`](codex-cli-managed-config.md) — Codex CLI's admin-managed configuration: the three layers (`managed_config.toml` defaults, `requirements.toml` enforcement, cloud requirements), exact paths/precedence per platform, the unified hook schema across `hooks.json` / inline `config.toml` / `requirements.toml` (`managed_dir`, `allow_managed_hooks_only`), why `[otel]` is defaulted-not-enforced and why Windows managed defaults are a weak boundary, and the lab's two-stack (`codex-cli-requirements` / `codex-cli-managed-config`) validation design.
- [`kibana-saved-objects.md`](kibana-saved-objects.md) — the design of the stack's Kibana data views, saved searches, and dashboard: the curated columns and the reasoning, why saved searches rather than data views, and how to regenerate the NDJSON.
