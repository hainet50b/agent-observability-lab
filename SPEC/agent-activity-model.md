# Agent activity model — the shape behind the Kibana saved searches

The per-agent saved searches
(`components/backends/services/kibana/<source>/saved-searches.ndjson`) are **not** a
1:1 catalogue of telemetry events. They are designed **top-down** from an
agent-agnostic activity model, and each view is then filled with whatever
telemetry that agent happens to emit. A new agent is onboarded by **mapping its
telemetry onto this model** — not by enumerating its event types. This doc is
that model; the per-agent field detail lives in the telemetry references
([`claude-code-telemetry.md`](claude-code-telemetry.md),
[`codex-cli-telemetry.md`](codex-cli-telemetry.md)) and the exact columns live in
the NDJSON and the PRD tasks that ship each search.

## The model

**Hierarchy** — an agent's work nests:

```
Conversation ⊃ Turn ⊃ { User Prompt · LLM Request · Tool Call }
```

- **Conversation / Session** — the whole interaction.
- **Turn** — one user-input → completion cycle (in trace terms, one root trace).
- Within a turn the agent receives a **User Prompt**, issues one or more **LLM
  Requests**, and executes **Tool Calls**.

**View kinds** built on that hierarchy:

- **Aggregates** (ES|QL rollups) — one row per Conversation / per Turn:
  sub-activity counts (prompts, LLM requests, tool calls), token sums, errors,
  duration (+ TTFT at the turn level). Keyed by `conversation_id` / trace.
- **Timeline** — one row per sub-activity span within a turn, in `@timestamp`
  order (the execution trace of a single turn).
- **Per-activity views** at the three **facets** below.
- **Error views** — failure-filtered complements of LLM Request / Tool Call.
- **Hooks** — the agent's extensibility runtime (registration / execution).

**The three facets** — each in-turn activity is looked at through up to three
lenses:

| Facet | Question it answers | Source |
| --- | --- | --- |
| **Execution** | how long, what outcome, what shape | trace spans |
| **Content** | the actual payload — prompt text, tokens, tool args/output (sensitive, gated) | logs |
| **Metadata** | the safe envelope — success, duration, endpoint, sizes — *without* content | logs |

**Spine** — `conversation_id` + `trace.id` thread every view together (activity →
turn → conversation), and `trace.id` is a click-through to the APM trace UI.

## Per-agent realization

The facets are abstract; each agent fills them from the telemetry it actually
has. **This is why two agents' saved-search sets differ in shape even though they
model the same activities.**

- **Codex CLI** emits a **dual log family** — `log_only` (carries content) and
  `trace_safe` (carries the safe envelope) — plus traces. So each activity fans
  out to **up to three facet lenses** (e.g. LLM Requests × {Traces / Duration,
  Log Only / Tokens, Trace Safe / Communication}).
- **Claude Code** emits a **single event stream** (no `log_only` / `trace_safe`
  split) plus traces, with content gated behind `OTEL_LOG_*` flags. So for Claude
  the **Content and Metadata facets collapse into one event view** — the event
  already carries the envelope, and content columns populate only when the gate
  is on. Each activity is therefore ~**one event view + optionally one trace
  view**, not three.

## Conventions

- **Naming:** `<Agent> — <Entity> (<facet / purpose>)`; mark a superseded view
  `(Deprecated)` rather than deleting it.
- **Object kind:** aggregates are ES|QL saved Discover sessions; raw views are
  data-view + filter-pill objects with an empty query bar.
- **Trailer / spine:** every raw view ends with `trace.id` (click-through).
- **Identity ("who") is not a column in these views** — it belongs to the audit
  concern ([`agent-audit.md`](agent-audit.md)), not the telemetry views. Both
  agents lead with `@timestamp`. (Claude Code's earlier convention of leading
  every view with `labels.user_email` is retired in the Codex-aligned rebuild;
  the kept searches drop it as each is reworked.)
- **Description:** one concise line per search, no boilerplate.
