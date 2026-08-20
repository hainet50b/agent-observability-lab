# AGENTS.md

Agent Observability Lab — a hands-on lab wiring coding agents (Claude Code,
Codex) to observability backends: telemetry over OTLP/APM and tool-call audit
over hooks → Elasticsearch.

## Source of truth

The implementation is the source of truth. Documents record intent and
context but can lag behind the code; when a document and the tree disagree,
trust the tree and fix the document. Do not act on a documented claim you
have not verified against the current code.

## Orientation

- `agent-config/` — mechanism: the Rust CLI that renders, places, tears
  down, and bundles agent config — one declarative bundle definition per
  agent under `src/agents/`; the content it embeds lives in `agents/`
- `agents/` — policy, agent side: everything delivered to an agent's machine
  (per-agent config templates + runtime hooks, `shared/` = the shared hook
  core)
- `backends/` — backend side: one self-contained directory per backend
  family. `elastic/` holds the service fragments (compose + config + the
  ES/Kibana assets they consume), the espalier project (`espalier.toml`),
  the `provision.{sh,ps1}` wrappers, the connection file
  (`agent-config.toml`) agents wire up from, and the operational checks
  (`smoke-test.sh`, `verify-*`); its `docker-compose.yml` (project name
  `aol-elastic`) is the runnable composition
- `workbench/` — gitignored; per-experiment directories users create by
  copying the connection file and running `agent-config place` (see
  `README.md`)
- `README.md` — user-facing entry point
- `SPEC/` — reference notes that are hard to re-derive from code (telemetry
  field mappings, threat model, config-deployment invariants). Consult when
  relevant; verify before relying on details.
- `CONVENTIONS.md` — code style and the lint / format / test commands

## Working here

- Docs follow implementation: when a change makes a README or SPEC section
  stale, update it in the same change — or say explicitly that it is stale.
