# Agent Observability Lab — Design Notes

Reference notes for people (and agents) working on the lab: the design
decisions, invariants, and field-level references that are hard to re-derive
from the code. The tree is the source of truth — these notes describe the
implementation, they do not govern it. Verify details against the code before
relying on them; when code and notes disagree, it is the notes that are out of
date. User-facing surface lives in `README.md`; coding style in
`CONVENTIONS.md`.

## Design decisions and invariants

- **Demo posture, not production.** Stacks run locally with security relaxed and ports bound to localhost; never expose one publicly or point it at sensitive infrastructure.
- **Telemetry can carry sensitive content.** Agent telemetry may include prompt text and tool I/O — treat anything sent to a stack as sensitive: don't run a telemetry-enabled session containing secrets, and never commit captured telemetry into the repo.
- **Sealed audit content fails closed.** When an audit stream's `content=encrypted`, the hook CMS-seals the body at the edge to a configured public recipient so Elasticsearch holds only ciphertext + metadata; if the bundled cert is missing or its CN doesn't match the configured `seal.key_id`, the hook records metadata-only rather than emit plaintext or seal to an unintended recipient. Opt-in, off by default. See [`agent-audit.md`](agent-audit.md) "Sealing".
- **Components are composable; stacks are compositions — and so are backends.** Reusable building blocks live under `components/{backends,agents}/`; the lowest layer is the `backends/services/<service>/` fragments. A **backend** is itself a composition — `include:` of service fragments + composition scripts — not a place where services are redefined. Each stack under `stacks/<combo>/` is one composition (Backends × Agents) expressed as a `docker compose include:`, plus the combination's `README.md` and any combination-specific glue — no services are defined inline in `stacks/<combo>/`.
- **Telemetry and audit are separate stacks, alternatives — not co-run** — each with its own agent home and volumes. Separate stacks is **not** for physical isolation (the lab is single-node) but to keep each stack's **load-bearing set legible**: the audit stack's compose visibly carries no APM Server, and its agent home holds only the audit config.
- **Stacks drive components only through façades.** A stack calls each component's façade — backend `setup-elasticsearch` / `setup-kibana`, agent-side the `agent-config` CLI — never its internal render / place primitives. The façade owns which steps run, in what order, and which concerns to select; adding or reordering a component's internal steps never touches a stack. (Backends keep ES and Kibana as **two** façades, not one: a composition routes different concern sets to each.)
- **An artifact lives in the component of the runtime that consumes it, never with what it describes.** Elasticsearch-consumed assets (ingest pipelines, index/data-stream templates) in `backends/services/elasticsearch/`, Kibana-consumed assets (saved-object bundles) in `backends/services/kibana/`, agent-runtime-consumed config in `agents/` — so a `service.name`-gated pipeline or a single-agent saved search, agent-specific in *content*, still lives in the service component that runs it. A backend holds **no asset files**; it composes a *selection*: assets intrinsic to its identity are applied by its own composition scripts, while per-agent assets are selected by the **stack** and passed to the backend's façades.
- **Agents never construct OTLP paths.** Telemetry templates take the **full per-signal OTLP endpoints** from the caller — no `/v1/<signal>` path construction in the agent.
- **APM `@custom` pipelines are agent-agnostic routers.** The fixed Elastic extension points (`logs-apm.app@custom`, `traces-apm@custom`) only dispatch by `service.name` to per-`service.name` sub-pipelines (`…@custom-<service.name>`, `ignore_missing_pipeline`). One agent spans several surfaces, each emitting its own `service.name` — those sub-pipelines are thin **forwarders** to a single shared per-agent pipeline (`…@custom-codex` / `…@custom-claude`) that holds the drop / redaction logic, so every surface is handled identically without duplicating it (the diamond: `router → @custom-<service.name> → @custom-<agent>`); the per-surface **reroute** (traces → `agents_<service>` namespace) stays in the forwarder, since the destination is surface-specific. A stack installs only the sub-pipelines for the agents it composes — docs from absent agents pass through untouched (per-stack minimal).
- **Service fragments are shared verbatim, not parameterized.** Compose `include:` cannot pass variables into an included fragment, so a shared `elasticsearch.yml` / `kibana.yml` holds only while every consuming backend wants **byte-identical** config. A backend needing divergent service config must express it as a per-stack/per-backend compose override layered on top, never by forking the fragment.
- **Stacks share definitions, never runtime state.** Component volumes stay Compose-project-scoped — never give a volume a fixed `name:` or mark it `external:` to share data across stacks. Comparing multiple agents in one backend is done by composing those agents into **one** stack.
- **Stack READMEs stay self-contained.** Each stack's `README.md` is the operational Quick Tour and deliberately does **not** link into `SPEC/`; the deep references are indexed here, in [Reference documents](#reference-documents).

## Lifecycle (ILM)

Every data stream the lab owns or routes is retained by an **ILM policy**, not
data-stream lifecycle (DSL). ILM is chosen over DSL because production
deployments want warm/cold/**frozen** phases and **searchable snapshots**,
which DSL cannot express; the lab itself runs only a trivial **hot → delete at
3 days** policy, but keeps the ILM seam so those phases drop in without
re-plumbing. Policies are split per concern so each can age independently —
audit per stream, telemetry per **agent** (one policy covers an agent's
logs/metrics/traces; a per-signal split is deferred: it would only add
policies, not restructure anything).

Each policy ships as a pair of Elasticsearch text assets (`*.ilm.json` +
`*.component.json`) **co-located in the concern that consumes it**; the
importer applies ilm → component template → pipelines → index templates within
a concern, so referenced objects always exist first. Index templates attach
their policy by **composition** — every index template in the lab is a
composition, never an inline blob — two ways depending on who owns the
template:

- **Audit streams (owned).** Each `logs-agent_audit.*` index template is a
  thin `composed_of: [<stream>@mappings, <stream>@lifecycle]`, with no inline
  mappings and no `data_retention` block; ILM is the single retention
  authority. (Because mappings are no longer inline, the importer re-syncs the
  **resolved** composed mapping onto the live stream via `_simulate_index`.)
- **Telemetry streams (APM-owned).** APM ships one shared index template per
  signal, so its `@custom` hook can only attach lifecycle to **every** service.
  Instead each agent gets **dedicated, higher-priority index templates**
  matching its per-agent patterns that re-compose APM's own managed component
  templates (inheriting its mappings verbatim) **plus** that agent's lifecycle
  component template last. Other services keep APM's default lifecycle
  untouched.

## Audit-coverage scope

Telemetry-as-audit in this lab targets the **non-adversarial /
network-reliability** threat model only; the adversarial / audit-evasion model
is explicitly out of scope and belongs to endpoint-security tooling outside
the lab. The full rationale, the (A)/(B) distinction, and the hook-audit's
bypass / failure surface are in [`threat-model.md`](threat-model.md).

## Reference documents

Developer-facing references that sit beside these notes. The user-facing
`README.md` files do **not** link into these — they are found here, via
`SPEC/`:

- [`agent-activity-model.md`](agent-activity-model.md) — the agent-agnostic activity model the Kibana saved searches are designed from (Conversation ⊃ Turn ⊃ {prompt, LLM request, tool call}; the Execution / Content / Metadata facets; the `conversation_id` + `trace.id` spine) and how each agent's telemetry realizes it (Codex's dual-family facet fan-out vs Claude's collapsed event view). The top-down design contract for onboarding a new agent's views.
- [`threat-model.md`](threat-model.md) — audit-coverage threat model: the (A) non-adversarial / (B) adversarial split, why telemetry can only serve (A), and the hook-audit's bypass / failure surface.
- [`agent-audit.md`](agent-audit.md) — direct agent-audit data streams and hook delivery: canonical user-prompt schema, mapping/lifecycle defaults, fail-open delivery, and hook-specific configuration.
- [`claude-telemetry.md`](claude-telemetry.md) — what Claude Code emits into the `claude-elastic` stack: every metric / event / span field, the string-vs-numeric and PII caveats, the trace data model, and the trace-isolation routing.
- [`codex-telemetry.md`](codex-telemetry.md) — what OpenAI Codex emits into the `codex-elastic` stack: the per-surface `service.name`s (`codex_cli_rs`, `codex-app-server`, `codex-mcp-server`), the dual `log_only`/`trace_safe` log families (identity+content vs `event_name`, joined on `call_id`/`span.id`), the metric/event catalogs, the WebSocket-vs-SSE transport split, and the trace-isolation routing.
- [`config-deployment.md`](config-deployment.md) — how agent config is put in place: the self-contained **config bundle** (telemetry + mcp + hook registration + audit conf + the hook scripts/lib), **materialized** per deployment so component edits never cross-affect a live stack; the three scopes (`local` = stack dir / `project` = `--target <dir>` / `managed` = system paths); the `setup-backend` / `agent-config place` split that `setup.sh` composes; and why managed materialize is staged (config-only vs managed hooks).
- [`claude-managed-config.md`](claude-managed-config.md) — Claude Code's admin-managed configuration: one authoritative tier (vs Codex's defaults/requirements split) delivered over mutually exclusive channels, the `managed-settings.d/` drop-in directory and its per-key merge semantics, platform paths and precedence, what it enforces (notably telemetry — forceable here, unlike Codex's `[otel]`), and the shared deploy-only/human-gated/never-overwrite placement model as it applies to a fragment rather than a singleton.
- [`codex-managed-config.md`](codex-managed-config.md) — Codex's admin-managed configuration: the three layers (`managed_config.toml` defaults, `requirements.toml` enforcement, cloud requirements), exact paths/precedence per platform, the unified hook schema across `hooks.json` / inline `config.toml` / `requirements.toml` (`managed_dir`, `allow_managed_hooks_only`), and why `[otel]` is defaulted-not-enforced and Windows managed defaults are a weak boundary. The deploy-only placement model it shares with Claude is owned by [`config-deployment.md`](config-deployment.md).
