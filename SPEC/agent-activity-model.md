# Agent activity model — the shape behind the Kibana saved searches

The per-agent saved searches
(`backends/elastic/kibana/<source>/saved-searches.ndjson`) are **not** a
1:1 catalogue of telemetry events. They are designed **top-down** from an
agent-agnostic activity model, and each view is then filled with whatever
telemetry that agent happens to emit. A new agent is onboarded by **mapping its
telemetry onto this model** — not by enumerating its event types. This doc is
that model; the per-agent field detail lives in the telemetry references
([`claude-telemetry.md`](claude-telemetry.md),
[`codex-telemetry.md`](codex-telemetry.md)) and the exact columns live in
the NDJSON itself.

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

Not every agent realizes every kind: both shipped agents (**Claude**,
**Codex**) are deliberately consolidated down to **per-activity + Hooks** —
the Conversations / Turns rollups, Turn Timelines, and error views were
dropped (rollups belong to the deferred Overview dashboard; timelines to the
APM trace UI via the `trace.id` click-through; failures stay triageable via
the success columns or a one-off `message` filter on the events data view).
The model kinds stay available for a new agent; shipping them is a per-agent
curation decision, not an obligation. One rollup outside the conversation spine
did ship for both agents: **User Activity** — an ES|QL aggregate over User
Prompts, one row per `labels.user_email` (prompt volume, active days, avg per
day, last used). It is an adoption lens keyed by identity, not a revival of the
Conversations / Turns rollups. Both rollups are also embedded side-by-side in
the cross-agent **Agents — Adoption Overview** dashboard
(`kibana/shared/dashboard.ndjson`), which references both agents' data views
and saved searches.
Each telemetry stack's espalier group includes it, and the dependency closure
pulls in exactly what it references — both agents' data views and the two
user-activity searches (the sibling's other saved searches no longer ride
along), so
the dashboard's references resolve even though only one agent feeds data; the
sibling's half simply shows no results. The audit stacks don't import it (they
carry no telemetry data views at all).

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

- **Codex** emits a **dual log family** — `log_only` (carries content) and
  `trace_safe` (carries the safe envelope) — plus traces, so an activity *can*
  fan out to multiple facet lenses. The shipped set uses at most **two** per
  activity: LLM Requests × {Traces / Response Time, Log Only / Tokens},
  Tool Calls × {Log Only, Trace Safe / I/O Sizes}; User Prompts is a single
  `log_only` view.
- **Claude Code** emits a **single event stream** (no `log_only` / `trace_safe`
  split) plus traces, with content gated behind `OTEL_LOG_*` flags. So for Claude
  the **Content and Metadata facets collapse into one event view** — the event
  already carries the envelope, and content columns populate only when the gate
  is on. Each activity is therefore ~**one event view + optionally one trace
  view**, not three.

## Conventions

- **Naming:** `<Agent> — <Entity> (<facet / purpose>)`. A superseded view is
  **deleted** from the NDJSON bundle (the bundle is the curated set, not a
  history — git holds the history).
- **Object kind:** aggregates are ES|QL saved Discover sessions; raw views are
  data-view + filter-pill objects with an empty query bar.
- **Trailer / spine:** every raw view ends with `trace.id` (click-through).
- **Identity ("who") leads every event/logs-based view** — `labels.user_email`
  as the first column after `@timestamp`, the audit "who" axis. **Traces-based
  views omit it**: Codex trace spans carry no identity field (`labels.user_email`
  is absent from the traces data view), so it cannot be a column there — the gap
  is inherent to what the agent emits on spans, not a choice.
- **Description:** one concise line per search, no boilerplate.
