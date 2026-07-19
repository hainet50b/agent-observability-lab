# Agent Observability Lab — Developer Spec

Internal spec for people (and agents) implementing the lab. User-facing surface lives in `README.md`; coding style in `CONVENTIONS.md`.

## Repository shape

```
agent-observability-lab/
├─ PRD.md / SPEC/ / CONVENTIONS.md / README.md   # repo-wide spec layer (owned by human + conversational LLM)
├─ components/                                   # reusable building blocks composed by stacks
│  ├─ backends/
│  │  ├─ services/<service>/                     # shared service fragment: compose def + config + a concern-namespaced asset library (<concern>/) + the one importer that loads chosen concerns (elasticsearch / kibana / apm-server)
│  │  └─ <backend>/                              # a backend = `include:` of the service fragments it needs + façade scripts (setup-elasticsearch / setup-kibana) selecting which concerns to apply; owns no asset files of its own
│  ├─ agents/<agent>/                            # agent-runtime config (templates + render primitives) behind concern façades (setup-telemetry / setup-audit); no Kibana assets
│  └─ agents/shared/                             # agent-agnostic libraries the agents' scripts source: agent-audit/ (hook core + sealing), config-place/ (marker-aware placement), managed-config/ (managed-scope placement)
└─ stacks/
   └─ <combo>/                                   # one composition (Backends × Agents): docker-compose `include:` + Quick Tour README + any combination-specific glue
```

A stack composes one or more Backends and one or more Agents by `include:`ing the relevant component compose files; the stack directory carries only the combination's `README.md` and any glue that is specific to *that* combination. The typical stack is 1×1, but multi-Agent (several agents on one Backend) is a first-class composition. The agent talks **directly** to the Backend over the network.

## The four stacks

Two telemetry stacks (agent → OTLP → APM) and two audit stacks (agent hooks → ES). Ports are localhost-bound (demo posture).

| Stack | Agent | Concern | Backend | Data-plane key | Backend ports |
|---|---|---|---|---|---|
| `claude-elastic` | Claude | telemetry | `elastic` | `telemetry.apm_server.endpoint` `:8200` | ES `9200`, Kibana `5601`, APM `8200` |
| `codex-elastic` | Codex | telemetry | `elastic` | `telemetry.apm_server.endpoint` `:8200` | ES `9200`, Kibana `5601`, APM `8200` |
| `claude-elastic-audit` | Claude | audit | `elastic-audit` | `agent_audit.elasticsearch.url` `:9200` | ES `9200`, Kibana `5601` (no APM) |
| `codex-elastic-audit` | Codex | audit | `elastic-audit` | `agent_audit.elasticsearch.url` `:9200` | ES `9200`, Kibana `5601` (no APM) |

`elastic` = `elasticsearch` + `kibana` + `apm-server` (the full OTLP ingest path); `elastic-audit` = `elasticsearch` + `kibana` only (audit hooks write straight to ES, never the OTLP/APM path). Telemetry and audit are **separate stacks**, alternatives — not co-run — each with its own agent home and volumes. The deep references per concern are indexed in [Reference documents](#reference-documents).

Component responsibilities:

- **`components/backends/services/<service>/`** is a shared, agent- and backend-agnostic **service fragment**: its Compose service definition (`docker-compose.yml`, no `name:`), its config file, the **asset library that service consumes, namespaced by concern** (`<concern>/`, one ES object / Kibana bundle per file, typed by filename suffix — e.g. `*.pipeline.json`, `*.template.json`, `data-views.ndjson`), and the **single importer** that loads chosen concerns into the running service (`import-elasticsearch-assets` / `import-kibana-assets`, taking concern names). Both service components share this concern-first shape. Composed into backends via `include:`.
- **`components/backends/<backend>/`** is a **composition, not an asset owner**: a `docker compose include:` over the service fragments it needs, plus **façade scripts** (`setup-elasticsearch` / `setup-kibana`) that select which concerns to apply to each service. It owns no service definitions, config, or asset files of its own.
- **`components/agents/<agent>/`** owns only what the **agent runtime** consumes: telemetry-config templates (the `[otel]` / MCP / hooks blocks, `managed-settings.json` excerpt), hook scripts, the hook-delivery config they read (`agent-audit.conf`), and the **render primitives** that materialize them into the agent home — fronted by **concern façades** (`setup-telemetry` / `setup-audit`). Telemetry templates take the **full per-signal OTLP endpoints** from the caller — no `/v1/<signal>` path construction in the agent. It owns **no** Kibana assets.
- **`components/agents/shared/`** holds the agent-agnostic libraries those per-agent scripts source, one dir per concern: `agent-audit/lib/` (the hook core + sealing, copied into each deployed bundle), `config-place/lib/` (the marker-aware placement primitive every render script uses), `managed-config/lib/` (the interactive managed-scope placement core). Nothing here is deployed on its own — an agent's façade decides what to render and copy.

**Placement rule.** An artifact lives in the **service component of the runtime that consumes it** — Elasticsearch-consumed assets (ingest pipelines, index/data-stream templates) in `backends/services/elasticsearch/`, Kibana-consumed assets (saved-object bundles) in `backends/services/kibana/`, agent-runtime-consumed config (`config.toml` templates, `agent-audit.conf`) in `agents/` — never with whatever the artifact *describes*. A backend holds **no asset files**; it only composes a *selection* of them. Selection has two drivers: assets **intrinsic to a backend's identity** (telemetry pipelines for `elastic`; audit templates and the cross-agent agent-audit Kibana views for `elastic-audit`) are applied by the backend's composition scripts, while **per-agent assets** (which agent's pipelines / Kibana views) are selected by the **stack** and passed to the backend's `setup-elasticsearch` / `setup-kibana` façades. "It's about agent X" is never the placement criterion: a `service.name`-gated ingest pipeline and a single-agent saved search are agent-specific in *content* yet live in the elasticsearch / kibana service component, because those services are what run them.

Backends are specialized variants, distinguished by **which service fragments they `include:` and which library assets they compose** (see the table above): `elastic` composes the telemetry ingest pipelines; `elastic-audit` composes the audit index/data-stream templates plus the agent-audit Kibana views. Separate stacks is **not** for physical isolation (the lab is single-node) but to keep each stack's **load-bearing set legible** — the audit stack's compose visibly carries no APM Server, and its agent home (`.codex` / `.claude`) holds only the audit config. `claude-elastic-audit` reuses the `elastic-audit` backend wholesale, adding only Claude Code's audit hooks; its deploy carries `settings.local.json` (the `hooks` registration — Claude registers hooks in settings, not a separate config file) at the `.claude` home root, `agent-audit.conf` inside `.claude/hooks/` beside the hook scripts, and `.mcp.json` (the Elasticsearch MCP) at the target root, with no telemetry `env`.

Each stack's own `README.md` is the **operational Quick Tour** — bring it up, point a session at it, import the Kibana objects, view, tear down — see `stacks/claude-elastic/README.md`. The developer-facing **deep references** (per-signal field reference, Kibana-view design, threat model) live beside this spec under `SPEC/` and are indexed in [Reference documents](#reference-documents) below; the user-facing `README.md` files deliberately do **not** link into `SPEC/` (they stay self-contained).

## Invariants

- **Demo posture, not production.** Stacks run locally with security relaxed and ports bound to localhost; never expose one publicly or point it at sensitive infrastructure.
- **Telemetry can carry sensitive content.** Agent telemetry may include prompt text and tool I/O — treat anything sent to a stack as sensitive: don't run a telemetry-enabled session containing secrets, and never commit captured telemetry into the repo.
- **Sealed audit content fails closed.** When an audit stream's `content=encrypted`, the hook CMS-seals the body at the edge to a configured public recipient so Elasticsearch holds only ciphertext + metadata; if the bundled cert is missing or its CN doesn't match the configured `seal.key_id`, the hook records metadata-only rather than emit plaintext or seal to an unintended recipient. Opt-in, off by default. See [`agent-audit.md`](agent-audit.md) "Sealing".
- **Components are composable; stacks are compositions — and so are backends.** Reusable building blocks live under `components/{backends,paths,agents}/<name>/`; the lowest layer is the `backends/services/<service>/` fragments. A **backend** is itself a composition — `include:` of service fragments + composition scripts — not a place where services are redefined. Each stack under `stacks/<combo>/` is one composition expressed as a `docker compose include:` over backends / paths / agents, plus the combination's `README.md` and any combination-specific glue — no services are defined inline in `stacks/<combo>/`.
- **Stacks drive components only through façades.** A stack calls each component's façade — backend `setup-elasticsearch` / `setup-kibana`, agent `setup-telemetry` / `setup-audit` — never its internal render / import primitives. The façade owns which primitives run, in what order, and which concerns to select; adding or reordering a component's internal steps never touches a stack. (Backends keep ES and Kibana as **two** façades, not one: a composition routes different concern sets to each — e.g. a path contributes Kibana assets but no ES pipelines.)
- **APM `@custom` pipelines are agent-agnostic routers.** The fixed Elastic extension points (`logs-apm.app@custom`, `traces-apm@custom`) only dispatch by `service.name` to per-`service.name` sub-pipelines (`…@custom-<service.name>`, `ignore_missing_pipeline`). One agent spans several surfaces, each emitting its own `service.name` (Codex: `codex_cli_rs` CLI, `codex-app-server` Desktop, `codex-mcp-server`; Claude: `claude-code` CLI, `claude-code-desktop` Desktop) — those sub-pipelines are thin **forwarders** to a single shared per-agent pipeline (`…@custom-codex` / `…@custom-claude`) that holds the drop / redaction logic, so every surface is handled identically without duplicating it (the diamond: `router → @custom-<service.name> → @custom-<agent>`); the per-surface **reroute** (traces → `agents_<service>` namespace) stays in the forwarder, since the destination is surface-specific. A stack installs only the sub-pipelines for the agents it composes — docs from absent agents pass through untouched (per-stack minimal).
- **Service fragments are shared verbatim, not parameterized.** Compose `include:` cannot pass variables into an included fragment, so a shared `elasticsearch.yml` / `kibana.yml` holds only while every consuming backend wants **byte-identical** config. A backend needing divergent service config must express it as a per-stack/per-backend compose override layered on top, never by forking the fragment.
- **Stacks share definitions, never runtime state.** Component volumes stay Compose-project-scoped — never give a volume a fixed `name:` or mark it `external:` to share data across stacks. Comparing multiple agents in one backend is done by composing those agents into **one** stack.

## Lifecycle (ILM)

Every data stream the lab owns or routes is retained by an **ILM policy**, not data-stream lifecycle (DSL). ILM is chosen over DSL because production deployments want warm/cold/**frozen** phases and **searchable snapshots**, which DSL cannot express; the lab itself runs only a trivial **hot → delete at 3 days** policy on each, but keeps the ILM seam so those phases drop in without re-plumbing.

Retention is split per concern so each can age independently — the lab gives each its own policy even though all four currently share the hot→delete@3d shape:

| Policy | Scope | Component template | Attached to |
|---|---|---|---|
| `logs-agent_audit.user_prompt-policy` | audit user-prompt stream | `logs-agent_audit.user_prompt@lifecycle` | `logs-agent_audit.user_prompt` template |
| `logs-agent_audit.tool_call-policy` | audit tool-call stream | `logs-agent_audit.tool_call@lifecycle` | `logs-agent_audit.tool_call` template |
| `telemetry.claude-policy` | Claude Code telemetry (logs+metrics+traces) | `telemetry.claude@lifecycle` | the 3 per-agent claude templates |
| `telemetry.codex-policy` | Codex telemetry (logs+metrics+traces) | `telemetry.codex@lifecycle` | the 3 per-agent codex templates |

Telemetry is split **per agent**, not per signal — one policy covers an agent's logs/metrics/traces. A per-signal split is deferred: it would only add policies, not restructure anything.

Each policy ships as a pair of Elasticsearch text assets **co-located in the concern that consumes it** (audit assets under `elasticsearch/agent-audit/`, telemetry assets under `elasticsearch/claude/` and `elasticsearch/codex/`): a `*.ilm.json` (→ `_ilm/policy/<name>`) and a `*.component.json` (→ `_component_template/<name>`) that sets only `index.lifecycle.name`. The importer applies them **before** index templates within a concern (ilm → component template → pipelines → index templates), so referenced objects always exist first. There is **no** separate shared lifecycle concern and **no** backend façade change — each concern is self-contained and applied by whoever already applies it.

Index templates attach their policy by **composition**, two ways depending on who owns the template:

- **Audit streams (owned).** Each `logs-agent_audit.*` index template is a **thin composition** — `composed_of: [<stream>@mappings, <stream>@lifecycle]`, with no inline mappings and no `data_retention` block. The stream's strict mappings move to a per-stream `@mappings` component template, and ILM is the single retention authority. (Because mappings are no longer inline, the importer re-syncs the **resolved** composed mapping onto the live stream via `_simulate_index`.) So *every* index template in the lab is a composition, never an inline blob.
- **Telemetry streams (APM-owned).** APM ships one shared index template per signal (`logs-apm.app-*`, `metrics-apm.app-*`, `traces-apm-*`), so the `@custom` hook can only attach lifecycle to **every** service, not per-agent. Instead each agent gets **dedicated, higher-priority index templates** matching its per-agent patterns (`logs-apm.app.<service>-*`, `metrics-apm.app.<service>-*`, `traces-apm-agents_<service>*`) that re-compose APM's own managed component templates (inheriting its mappings verbatim) **plus** that agent's lifecycle component template last. Other services keep APM's default lifecycle untouched.

## Audit-coverage scope

Telemetry-as-audit in this lab targets the **non-adversarial / network-reliability** threat model only; the adversarial / audit-evasion model is explicitly out of scope and belongs to endpoint-security tooling outside the lab. The full rationale, the (A)/(B) distinction, and the hook-audit's bypass / failure surface are in [`threat-model.md`](threat-model.md).

## Reference documents

Developer-facing references that sit beside this spec. The user-facing `README.md` files do **not** link into these — they are found here, via `SPEC/`:

- [`agent-activity-model.md`](agent-activity-model.md) — the agent-agnostic activity model the Kibana saved searches are designed from (Conversation ⊃ Turn ⊃ {prompt, LLM request, tool call}; the Execution / Content / Metadata facets; the `conversation_id` + `trace.id` spine) and how each agent's telemetry realizes it (Codex's dual-family facet fan-out vs Claude's collapsed event view). The top-down design contract for onboarding a new agent's views.
- [`threat-model.md`](threat-model.md) — audit-coverage threat model: the (A) non-adversarial / (B) adversarial split, why telemetry can only serve (A), and the hook-audit's bypass / failure surface.
- [`agent-audit.md`](agent-audit.md) — direct agent-audit data streams and hook delivery: canonical user-prompt schema, mapping/lifecycle defaults, fail-open delivery, and hook-specific configuration.
- [`claude-telemetry.md`](claude-telemetry.md) — what Claude Code emits into the `claude-elastic` stack: every metric / event / span field, the string-vs-numeric and PII caveats, the trace data model, and the trace-isolation routing.
- [`codex-telemetry.md`](codex-telemetry.md) — what OpenAI Codex emits into the `codex-elastic` stack: the per-surface `service.name`s (`codex_cli_rs`, `codex-app-server`, `codex-mcp-server`), the dual `log_only`/`trace_safe` log families (identity+content vs `event_name`, joined on `call_id`/`span.id`), the metric/event catalogs, the WebSocket-vs-SSE transport split, and the trace-isolation routing.
- [`config-deployment.md`](config-deployment.md) — how agent config is put in place: the self-contained **config bundle** (telemetry + mcp + hook registration + audit conf + the hook scripts/lib), **materialized** per deployment so component edits never cross-affect a live stack; the three scopes (`local` = stack dir / `project` = `--target <dir>` / `managed` = system paths); the `setup-backend` / `setup-config` split that `setup.sh` composes; and why managed materialize is staged (config-only vs managed hooks).
- [`claude-managed-config.md`](claude-managed-config.md) — Claude Code's admin-managed configuration: the single authoritative `managed-settings.json` (vs Codex's defaults/requirements split), its platform paths and precedence, what it enforces (notably telemetry — forceable here, unlike Codex's `[otel]`), and the shared deploy-only/human-gated/never-overwrite placement model.
- [`codex-managed-config.md`](codex-managed-config.md) — Codex's admin-managed configuration: the three layers (`managed_config.toml` defaults, `requirements.toml` enforcement, cloud requirements), exact paths/precedence per platform, the unified hook schema across `hooks.json` / inline `config.toml` / `requirements.toml` (`managed_dir`, `allow_managed_hooks_only`), and why `[otel]` is defaulted-not-enforced and Windows managed defaults are a weak boundary. The deploy-only placement model it shares with Claude is owned by [`config-deployment.md`](config-deployment.md).
