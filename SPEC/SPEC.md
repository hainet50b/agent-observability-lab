# Agent Observability Lab — Design Notes

Reference notes for people (and agents) working on the lab: the design
decisions, invariants, and field-level references that are hard to re-derive
from the code. The tree is the source of truth — these notes describe the
implementation, they do not govern it. Verify details against the code before
relying on them; when code and notes disagree, it is the notes that are out of
date. User-facing surface lives in `README.md`; coding style in
`CONVENTIONS.md`.

## Design decisions and invariants

- **Demo posture, not production.** The backend runs locally with security relaxed and ports bound to localhost; never expose it publicly or point it at sensitive infrastructure.
- **Telemetry can carry sensitive content.** Agent telemetry may include prompt text and tool I/O — treat anything sent to the backend as sensitive: don't run a telemetry-enabled session containing secrets, and never commit captured telemetry into the repo.
- **Sealed audit content fails closed.** When an audit stream's `content=encrypted`, the hook CMS-seals the body at the edge to a configured public recipient so Elasticsearch holds only ciphertext + metadata; if the bundled cert is missing or its CN doesn't match the configured `seal.key_id`, the hook records metadata-only rather than emit plaintext or seal to an unintended recipient. Opt-in, off by default. See [`agent-audit.md`](agent-audit.md) "Sealing".
- **Mechanism and policy live apart; each side of the wire is self-contained.** `agent-config/` is mechanism — the delivery tool, implementation only. `agents/` is agent-side policy: everything delivered to an agent's machine (templates + hooks). `backends/<family>/` is one self-contained backend family: its service fragments (`elasticsearch/`, `kibana/`, `apm-server/` — compose + config + the assets that service consumes), its espalier project, its provision wrappers, and a runnable `docker-compose.yml` (fixed project name `aol-elastic`, so network/volume names don't depend on the invocation directory). Combinations (Agents × Concerns) are not directories: a gitignored `workbench/<name>/` holds a copy of the family's connection file (`agent-config.toml`), the `agent-config` CLI deploys the agents' native config beside it (`--agent` / `--concern` select the combination), and the agent is launched from there.
- **Concerns co-run by design.** Telemetry and audit land in one Elasticsearch so a session's audit trail can be lined up against its telemetry, and both agents feed the same cross-agent views. Concern separation is data-level — per-concern data streams, per-agent trace streams — not infrastructure-level; a workbench narrows its concerns via the connection-file copy and `--concern`, never by running a different backend.
- **An artifact lives with the runtime that consumes it, never with what it describes.** Elasticsearch-consumed assets (ingest pipelines, index/data-stream templates) in `backends/elastic/elasticsearch/`, Kibana-consumed assets (saved-object bundles) in `backends/elastic/kibana/`, agent-runtime-consumed config in `agents/` — so a `service.name`-gated pipeline or a single-agent saved search, agent-specific in *content*, still lives in the service directory that runs it. Provisioning is combination-agnostic: the espalier project (`backends/elastic/espalier.toml`) declares a single all-assets group (`elastic`) applied idempotently, with cross-cutting dependencies resolved by reference analysis — unused assets sitting idle in Elasticsearch is the accepted cost of not multiplying selections.
- **Agents never construct OTLP paths.** Telemetry templates take the **full per-signal OTLP endpoints** from the caller — no `/v1/<signal>` path construction in the agent.
- **APM `@custom` pipelines are agent-agnostic routers.** The fixed Elastic extension points (`logs-apm.app@custom`, `traces-apm@custom`) only dispatch by `service.name` to per-`service.name` sub-pipelines (`…@custom-<service.name>`, `ignore_missing_pipeline`). One agent spans several surfaces, each emitting its own `service.name` — those sub-pipelines are thin **forwarders** to a single shared per-agent pipeline (`…@custom-codex` / `…@custom-claude`) that holds the drop / redaction logic, so every surface is handled identically without duplicating it (the diamond: `router → @custom-<service.name> → @custom-<agent>`); the per-surface **reroute** (traces → `agents_<service>` namespace) stays in the forwarder, since the destination is surface-specific. Provisioning installs every agent's sub-pipelines; docs from services with no sub-pipeline pass through untouched.
- **Service fragments are shared verbatim, not parameterized.** Compose `include:` cannot pass variables into an included fragment, so a shared `elasticsearch.yml` / `kibana.yml` holds only while every consuming backend wants **byte-identical** config. A consumer needing divergent service config must express it as a compose override layered on top, never by forking the fragment.
- **README is the user-facing surface, and it never links into `SPEC/`.** The repo-root `README.md` is the operational tour; the deep references are indexed here, in [Reference documents](#reference-documents).

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
  authority. A mapping change reaches an already-provisioned stream only on
  rollover — see [`agent-audit.md`](agent-audit.md) "Mapping and lifecycle".
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
- [`claude-telemetry.md`](claude-telemetry.md) — what Claude Code emits into the elastic backend: every metric / event / span field, the string-vs-numeric and PII caveats, the trace data model, and the trace-isolation routing.
- [`codex-telemetry.md`](codex-telemetry.md) — what OpenAI Codex emits into the elastic backend: the per-surface `service.name`s (`codex_cli_rs`, `codex-app-server`, `codex-mcp-server`), the dual `log_only`/`trace_safe` log families (identity+content vs `event_name`, joined on `call_id`/`span.id`), the metric/event catalogs, the WebSocket-vs-SSE transport split, and the trace-isolation routing.
- [`config-deployment.md`](config-deployment.md) — how agent config is put in place: the self-contained **config bundle** (telemetry + mcp + hook registration + audit conf + the hook scripts/lib), **materialized** per deployment so source edits never cross-affect a live deployment; the three scopes (`local` = beside the config copy / `project` = `--target <dir>` / `managed` = system paths); the marker/executor ownership model; and why managed materialize is staged (config-only vs managed hooks).
- [`claude-managed-config.md`](claude-managed-config.md) — Claude Code's admin-managed configuration: one authoritative tier (vs Codex's defaults/requirements split) delivered over mutually exclusive channels, the `managed-settings.d/` drop-in directory and its per-key merge semantics, platform paths and precedence, what it enforces (notably telemetry — forceable here, unlike Codex's `[otel]`), and the shared deploy-only/human-gated/never-overwrite placement model as it applies to a fragment rather than a singleton.
- [`codex-managed-config.md`](codex-managed-config.md) — Codex's admin-managed configuration: the three layers (`managed_config.toml` defaults, `requirements.toml` enforcement, cloud requirements), exact paths/precedence per platform, the unified hook schema across `hooks.json` / inline `config.toml` / `requirements.toml` (`managed_dir`, `allow_managed_hooks_only`), and why `[otel]` is defaulted-not-enforced and Windows managed defaults are a weak boundary. The deploy-only placement model it shares with Claude is owned by [`config-deployment.md`](config-deployment.md).
