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

- `components/` — reusable building blocks: `backends/` (service fragments +
  backend compositions), `agents/` (per-agent templates + runtime hooks),
  `agents/shared/` (the shared hook core)
- `agent-config/` — the Rust CLI that renders, places, tears down, and bundles
  agent config — one declarative bundle definition per agent under
  `src/agents/`; its templates live in `components/agents/`
- `stacks/` — one composition each (Backends × Agents), with a Quick Tour README
- `README.md` — user-facing entry point
- `SPEC/` — reference notes that are hard to re-derive from code (telemetry
  field mappings, threat model, config-deployment invariants). Consult when
  relevant; verify before relying on details.
- `CONVENTIONS.md` — code style and the lint / format / test commands

## Working here

- Docs follow implementation: when a change makes a README or SPEC section
  stale, update it in the same change — or say explicitly that it is stale.
