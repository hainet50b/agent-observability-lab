# Claude Code telemetry reference (claude-code-elastic)

What Claude Code actually emits into the `claude-code-elastic` stack, captured
from live sessions (`service.name = claude-code`, Claude Code 2.1.159, Stack
9.4.2). Discover is the source of truth for the version you run — names and
fields can change. This is the agent-knowledge companion to the stack's Quick
Tour (`stacks/claude-code-elastic/README.md`); the Kibana views built on these
signals ship as importable NDJSON in
`components/backends/services/kibana/claude-code/` — curated Discover **saved
searches** rather than extra data views (a data view holds only an index-pattern
+ time field, not a stored query or columns).

## How to read the data

- **Three data streams:** `metrics-apm.app.claude_code-default` (metrics),
  `logs-apm.app.claude_code-default` (events), and — when [Traces](#traces-beta)
  are enabled — `traces-apm-agents_claude_code` (spans, routed there from the
  service-agnostic `traces-apm-default`; see [Trace data model](#trace-data-model)).
  APM Server also auto-creates an essentially empty
  `metrics-apm.service_summary.1m-default` marker — not a useful visualization target.
- **Where the value/type lives:** a metric's value is in a field *named after the
  metric* (e.g. `claude_code.token.usage`); an event's type is in the `message`
  field (e.g. `claude_code.api_request`).
- **Attribute split:** string attributes → `labels.*`, numeric → `numeric_labels.*`
  (OTLP key `.` → `_`); `session.id` is promoted to a top-level field.
- ⚠️ **String-vs-numeric inconsistency.** `api_request` and `subagent_completed`
  put numbers in `numeric_labels` (aggregatable), but `tool_result` / `hook_*`
  carry `duration_ms` / `num_*` / `success` as **string** `labels` — `sum`/`avg`
  on those needs a Lens runtime-field cast.
- ⚠️ **PII.** `labels.user_email`, `labels.user_id`, and (with
  `OTEL_LOG_USER_PROMPTS=1`) `labels.prompt`. These live in the ingested documents
  regardless of any view — the exposure is ES/Kibana access and the
  don't-commit-telemetry invariant, not a saved search's column list.

**Common envelope** (every doc): `@timestamp`, `service.name`, `service.version`,
`agent.name` (`otlp`), `service.framework.name` (`com.anthropic.claude_code` on
the metrics stream, `com.anthropic.claude_code.events` on the events stream),
the host fields `host.architecture` / `host.os.platform` / `host.os.type` /
`host.os.version`, `data_stream.*`, and `session.id` (top-level, not a label — see
[Field meanings](#field-meanings-worth-recording)); common `labels.*` are
`user_*`, `organization_id`, `terminal_type`.

⚠️ **No host identity.** Claude Code's exporter sets the OS/architecture resource
attributes above but **not `host.name` / `host.hostname`** (nor
`service.node.name` / `service.instance.id`, nor any `cloud.*`). So a document can
be attributed to a **person** (`labels.user_email` — the "who") and to a
**session** (`session.id`), but **not to a device** — there is no "which machine"
axis in the native telemetry, only a coarse OS class. For fleet auditing where
device-level attribution matters (managed vs personal machine, which laptop), it
must be **added downstream**: a local OpenTelemetry Collector (the `otelcol-sidecar`
path) can stamp `host.name` / `host.id` onto every passing signal via a
`resourcedetection` processor. Caveat for this lab: the Collector runs in a
*container*, so a `system` detector reports the **container's** hostname, not the
laptop's — the dockerized stacks demonstrate the *mechanism*; a real fleet runs the
Collector as a host service (systemd / launchd) where it picks up the true host
name.

## Metrics (`metrics-apm.app.claude_code-default`)

| Metric field | Key labels | Notes |
| --- | --- | --- |
| `claude_code.session.count` | `start_type` (continue/fresh) | session starts |
| `claude_code.token.usage` | `type` (input/output/cacheRead/cacheCreation), `model`, `effort`, `query_source` | the cost driver; finest-grained |
| `claude_code.cost.usage` | `model`, `effort` | USD |
| `claude_code.active_time.total` | `type` (cli/user) | seconds |
| `claude_code.lines_of_code.count` | `type` (added/removed) | code edits |
| `claude_code.code_edit_tool.decision` | `decision`, `tool_name`, `language`, `source` | edit-tool permit decisions |
| `claude_code.commit.count` | (common labels only) | git commits |

`claude_code.pull_request.count` is documented but hasn't landed here (no PR has
been created against this stack). Dashboards should tolerate it arriving later.

## Events (`logs-apm.app.claude_code-default`, discriminated by `message`)

| `message` | Notable fields |
| --- | --- |
| `claude_code.user_prompt` | `labels.prompt_id`, `prompt_length` (string), `prompt` (`<REDACTED>` unless `OTEL_LOG_USER_PROMPTS=1`) |
| `claude_code.api_request` | `labels.model`, `request_id`, `query_source`, `speed`, `effort`; `numeric_labels.input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cost_usd`, `cost_usd_micros`, `duration_ms` |
| `claude_code.api_error` | the failure twin of `api_request`: the same context labels (`model`, `request_id`, `query_source`, `speed`, `effort`) plus `labels.error` (message string, e.g. `Overloaded` / `Internal server error`); `numeric_labels.status_code`, `attempt` (how many tries this request burned), `duration_ms` (total, retries included). One per failed request — intermediate retries don't emit it |
| `claude_code.api_retries_exhausted` | `labels.error`; `numeric_labels.status_code`, `total_attempts`, `total_retry_duration_ms`. Fires ~1 ms after a terminal `api_error` when retries ran out, and only then — the content duplicates that `api_error` (`total_attempts` = its `attempt`, `total_retry_duration_ms` ≈ its `duration_ms`); its value is as a distinct alert signal, not extra data |
| `claude_code.internal_error` | `labels.error_name` (just `Error` — no message, no stack); pairs with 500-class `api_error`s at the same instant. No standalone value |
| `claude_code.tool_decision` | `labels.tool_name`, `decision`, `source`, `tool_use_id` |
| `claude_code.tool_result` | `labels.tool_name`, `success` (string), `duration_ms` (string), `decision_type`, `decision_source`, `tool_use_id`, `tool_input_size_bytes`, `tool_result_size_bytes` |
| `claude_code.hook_registered` | `labels.hook_event`, `hook_type`, `hook_source` (granular origin: `userSettings`/`projectSettings`/`localSettings`/`flagSettings`/`pluginHook`/`policySettings`), `plugin_name` (when `hook_source: pluginHook`); fires once per hook at session start, no `prompt_id` |
| `claude_code.hook_execution_start` | `labels.hook_name`, `hook_event`, `hook_source`, `managed_only`, `num_hooks` |
| `claude_code.hook_execution_complete` | + `num_blocking`, `num_success`, `num_cancelled`, `num_non_blocking_error`, `total_duration_ms` |
| `claude_code.hook_plugin_metrics` | `labels.plugin_id`, `hook_event`, `skipped`; many `numeric_labels.*` review metrics (`cost_usd`, `vulns_found`, `files_reviewed`, `tok_*`, …) — plugin-specific (security-guidance) |
| `claude_code.subagent_completed` | `labels.agent_type`, `agent_source`, `model`, `is_async`, `is_built_in`; `numeric_labels.duration_ms`, `total_tokens`, `total_tool_uses` |
| `claude_code.permission_mode_changed` | `labels.from_mode`, `to_mode` (`default`/`acceptEdits`/`plan`/`auto`), `trigger` (e.g. `shift_tab`), `prompt_id` |
| `claude_code.mcp_server_connection` | `labels.status` (e.g. `connected`), `transport_type` (`stdio`/…), `server_scope`, `is_plugin`, `duration_ms` (string) — no server-name field, no `prompt_id` (fires at startup) |
| `claude_code.auth` | `labels.action` (`login`/`logout`), `success`, `auth_method` (`oauth`); failure-only `error_category`, `status_code`; has `prompt_id`. ⚠️ Also carries many PII labels (`user_email`, `user_id`, `organization_id`, …) |
| `claude_code.feedback_survey` | `labels.survey_type`, `event_type`, `response`, `appearance_id` — UI survey, low signal |

`claude_code.hook_registered` fires once per
configured hook at session start and carries the granular `hook_source` origins
(see below).

**`gen_ai.request.attempt` (bare name, no `claude_code.` prefix)** — one
document per HTTP attempt against the API, carrying only
`labels.client_request_id` (a fresh UUID per attempt) and
`numeric_labels.attempt`. Like `tool.output` it comes from the tracing
framework and has **no `user_*` / `prompt_id` envelope**; it **exists only
while tracing is on** (every document carries a `trace.id`, while `api_request`
shows plenty of untraced documents from tracing-off windows). Its `span.id`
points at the **`claude_code.llm_request` span** — unlike the `claude_code.*`
events of the same turn, which stamp the active `interaction` span — making it
the per-attempt timeline for that span. For *counting* retries it is redundant:
the terminal attempt count also lands on the `llm_request` span itself
(`numeric_labels.attempt`, with `event.outcome: failure`) and on `api_error`;
what only this event has is the timestamp of each attempt (the backoff curve)
and the per-attempt `client_request_id`. Quirks: each retry chain logs
`attempt: 1` twice (`[1, 1, 2, …, N]`), and when `OTEL_LOG_RAW_API_BODIES` is
on, every attempt pairs 1:1 with an `api_request_body` document at the same
timestamp — the request body is re-sent (and re-logged) per retry.

**`claude_code.auth` is logout-biased.** `/logout` runs while telemetry is still
alive, so the `action: logout` event reliably lands — but `/logout` then *exits*
the CLI, and the next `claude` start goes to the login screen *outside* a
telemetry session, so a normal cold-start login is never captured. The only path
that produces an `action: login` event is an **in-session `/login`** (switching
accounts in an already-authenticated session). Treat auth events as a
sign-*out* audit, not a usage-start signal; for session starts use the
`claude_code.session.count` metric (`start_type: fresh/continue`) instead.

## Traces (beta)

A third, optional signal. Tracing is **off by default**; the Quick Tour config
enables it with `CLAUDE_CODE_ENABLE_TELEMETRY=1` + `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`
+ `OTEL_TRACES_EXPORTER=otlp` (endpoint/protocol reuse the common OTLP config —
this stack's `http/protobuf` → `:8200`). APM Server receives spans natively on
`/v1/traces` (no server change); this stack then **routes** Claude Code's spans
into the dedicated **`traces-apm-agents_claude_code`** data stream (see Trace data model
below).

- **What it adds:** each user prompt becomes a `claude_code.interaction` root span,
  with `claude_code.llm_request` and `claude_code.tool` children (a tool span has
  two children — the permission-decision wait and the execution). This links a
  prompt to the API calls and tool runs it triggered as one trace.
- **Events auto-correlate to traces (and metrics never do).** With tracing active,
  Claude Code's **events** (OTel *log records*) emitted inside an active span pick up
  that span's **`trace.id` / `span.id`** — per the OpenTelemetry Logs data model
  (TraceId/SpanId *"can be set for logs that are part of a particular processing
  span"*, populated from the active context). It is an OTel-platform behaviour, **not**
  a Claude-Code-documented event field (the monitoring docs list only `prompt.id` /
  `workspace.host_paths` as event-only extras). So `events.trace.id == span.trace.id`
  is the events↔traces join, and only events emitted while a span was open carry it
  (turn tracing off → no `trace.id`). **Metrics never carry `trace.id`** — high-cardinality
  correlation IDs are intentionally excluded from metrics to avoid unbounded time-series
  (the Claude Code docs state the same for `prompt.id`); there is no metric↔trace join,
  correlate metrics to a run by shared dimensions like `session.id` instead.
- **Where to view it:** the **APM UI** (<http://localhost:5601/app/apm>) — service
  map and trace waterfalls — is the natural home; the **Claude Code — Traces**
  Discover data view (`traces-apm-agents_claude_code*`, this agent) also lets
  you scan spans. Two saved searches sit on it: **Claude Code — Interactions** (one row per
  *interactive turn* — the `interaction` root, with rich prompt/sequence/duration
  columns; interactive-only) and **Claude Code — Traces** (one row per *trace*,
  all session types, via `processor.event: transaction`). On these data views
  `trace.id` is a **click-through to the APM UI trace view** (URL field formatter →
  `/app/apm/link-to/trace/{{value}}`).
- **Content is still redacted by default.** Spans redact prompt text, tool input,
  and tool content unless the matching `OTEL_LOG_*` gate is set. In particular,
  **`OTEL_LOG_TOOL_CONTENT=1` requires tracing** — it adds a `tool.output` span
  event (tool input+output bodies, 60 KB cap) on the `tool` execution span, which
  has no equivalent in the metrics/events streams.
- **Not adopted: "detailed" beta.** A deeper tier (`ENABLE_BETA_TRACING_DETAILED=1`
  + `BETA_TRACING_ENDPOINT`, and an org allowlist for interactive sessions) adds the
  `claude_code.hook` span and extra content attributes. This stack stays on the
  plain enhanced beta; detailed beta is out of scope.

## Trace data model

APM writes all OTLP spans to one **service-agnostic** data stream
`traces-apm-default` (template `traces-apm@template`, patterns `traces-apm-*`) —
unlike the metrics/events streams, whose dataset embeds the service
(`*-apm.app.claude_code-default`). So out of the box every producer's spans
co-mingle, and a data view can't store a `service.name` filter to separate them.

This stack therefore **physically isolates the agent's spans by routing**: a
`reroute` processor in the per-agent **`traces-apm@custom-claude-code`** sub-pipeline
— which the agent-agnostic **`traces-apm@custom`** router (the managed
`traces-apm@default-pipeline`'s extension point) dispatches to on
`service.name: claude-code`, installed by the `elastic` backend's
`setup-elasticsearch` — sends those spans to a dedicated
**`traces-apm-agents_claude_code`** data stream — it still matches `traces-apm-*`,
so it keeps the full APM trace mappings; everything else (including any co-tenant
production app traces) stays in `traces-apm-default`. The traces data view is
scoped to **`traces-apm-agents_claude_code*`**, so it needs no `service.name`
filter; the `agents_` prefix also gives a cross-agent glob
**`traces-apm-agents_*`** (claude_code, codex, …) that excludes non-agent traces.
(Spans captured before the pipeline was installed remain in `traces-apm-default`.)

**Why isolate traces specifically — and only traces:**

- **PII.** With the content gates on (`OTEL_LOG_TOOL_CONTENT` / `OTEL_LOG_RAW_API_BODIES`,
  see Quick Tour), spans carry prompt / tool I/O / code content. That must **not**
  land in a shared `traces-apm-default` alongside production app traces with their
  retention and access — it needs its own data stream so deletion, ILM, and RBAC
  are independent.
- **Independent deletion / retention.** A dedicated data stream drops in one shot
  (`DELETE /_data_stream/traces-apm-agents_claude_code`) or ages out on its own ILM —
  no `delete_by_query` across a large shared production trace store.
- **Experimental & high-churn.** Agent tracing is early/beta and noisy (every
  `llm_request` and tool call) — keeping it out of the production trace store
  protects sampling budget, field cardinality, and query performance there.
- **Traces only.** `metrics` and `logs` are **left on the defaults** because APM
  already gives them per-service data streams (`metrics-apm.app.claude_code-default`,
  `logs-apm.app.claude_code-default`) — they are not co-mingled, so there is nothing
  to separate. The co-mingling problem is unique to traces (no per-service trace
  dataset). Per-agent namespaces for traces (`agents_<agent>`) are the only routing
  this stack does.

Two doc kinds, discriminated by `processor.event`: `transaction` (the
`claude_code.interaction` root, one per prompt turn) and `span` (every child).
They join on `trace.id` (one whole turn) and `parent.id` (the tree). Durations are
**microseconds** (`transaction.duration.us` / `span.duration.us`; also mirrored as
`numeric_labels.duration_ms`); outcome in `event.outcome`.

```
claude_code.interaction          transaction   ← root, one per prompt turn
├─ claude_code.llm_request       span  genai/anthropic
└─ claude_code.tool              span  app/internal
   ├─ claude_code.tool.blocked_on_user   span   (awaiting the permission decision)
   └─ claude_code.tool.execution         span   (the actual tool run)
```

| `span.name` | `processor.event` | type/subtype | Distinctive fields (besides the `user_*` / `organization_id` / `terminal_type` envelope) |
| --- | --- | --- | --- |
| `claude_code.interaction` | transaction | —/unknown | `labels.user_prompt` (`<REDACTED>` unless `OTEL_LOG_USER_PROMPTS=1`); `numeric_labels.user_prompt_length`, `interaction_duration_ms`, `interaction_sequence` |
| `claude_code.llm_request` | span | genai/anthropic | `labels.model`, `gen_ai_response_finish_reasons`, `stop_reason`, `request_id` / `gen_ai_response_id`, `client_request_id`, `llm_request_context`, `speed`; `numeric_labels.ttft_ms` (**not in the `api_request` event**), `duration_ms`, `attempt`, `{input,output,cache_read,cache_creation}_tokens`; `span.links` → the server-side trace |
| `claude_code.tool` | span | app/internal | `labels.tool_name`; `numeric_labels.duration_ms` — parent of the two below |
| `claude_code.tool.blocked_on_user` | span | app/internal | `labels.decision` (accept/reject), `source` (config/user_temporary); `numeric_labels.duration_ms` = time spent awaiting the permission decision |
| `claude_code.tool.execution` | span | app/internal | `labels.success`; `numeric_labels.duration_ms`. Gains `tool_input` / `file_path` with `OTEL_LOG_TOOL_DETAILS=1`, and a `tool.output` span event (input+output bodies, 60 KB) with `OTEL_LOG_TOOL_CONTENT=1` |

`llm_request` overlaps the `api_request` *event* (model, tokens, duration) but is
**not** a superset — the event additionally carries `cost_usd`, `query_source`,
`effort`, while the span uniquely adds `ttft_ms`, `stop_reason`, and the causal
trace position. They complement each other.

**Trace root depends on session type — so "one trace" means different things.**
The `claude_code.interaction` root span is emitted **only in interactive REPL
sessions** (which also emit `user_prompt` events). **Headless / `-p` sessions (e.g.
Ralph) emit no `interaction` span and no `user_prompt` event** — each `llm_request`
or `tool` runs parentless and APM promotes it to its own root `transaction` (one
trace per API call / tool execution). So a "trace" is a whole prompt **turn**
interactively, but a single **API call / tool execution** headlessly. Consequences:
the **Claude Code — Interactions** saved search (`span_type: interaction`) is
interactive-only; **Claude Code — Traces** (`processor.event: transaction`) covers
every session, with `transaction.name` exposing the root type. Verified live:
across two sessions, the interactive one rooted at `interaction` (with `user_prompt`
events), the Ralph one rooted at `llm_request`/`tool` (zero `user_prompt` events).

How the trace signal maps to the event saved searches (activity-level, not 1:1):
`interaction` ↔ **User Prompts**, `llm_request` ↔ **API Requests**, `tool*` ↔
**Tool Results** (+ `tool.blocked_on_user` ↔ **Tool Decisions**). One tool call is
one `tool_result` event but several spans (`tool` + `blocked_on_user` +
`execution`), so the span side is finer-grained.

## Field meanings worth recording

- **Why `session.id` is top-level but `user_email` / `prompt_id` are under
  `labels`** — Elastic's OTLP/APM intake promotes only attributes whose key
  matches a field already in its data model to a dedicated top-level field;
  everything else falls into the generic `labels.*` (strings) / `numeric_labels.*`
  (numbers) buckets, with dots in the key flattened to underscores. `session.id`
  is a modeled APM field (the session-tracking concept), so it lands top-level as
  a `keyword` (aggregatable) keeping its dotted name. Claude-Code-specific
  attributes aren't modeled, so they become labels — and `user.email` flattens to
  `labels.user_email` (note: it is *not* promoted to the ECS `user.email` field,
  which stays empty). So when scanning the Events data view, reach for
  `session.id` but `labels.prompt_id` / `labels.user_email`.
- **`query_source`** (api_request) — what triggered the call: `repl_main_thread`
  (the real interactive turn), `away_summary` (background summarization while
  away), `prompt_suggestion`. Separates "real" cost from background/auxiliary calls.
- **`decision_type` / `decision_source`** (tool_result) — *what* was decided
  (accept/reject) and *where* it came from (`config` = allowlisted,
  `user_temporary` = a one-off in-session approval). ⚠️ **Present only in
  interactive sessions** — a headless run (e.g. Ralph: zero `user_prompt` events,
  `start_type: fresh`, all decisions `source: config`) omits both, an
  all-or-nothing split *by session*. The decision is never lost: every
  `tool_result` has a matching `claude_code.tool_decision` event (1:1 by
  `tool_use_id`), so **`tool_decision` is the canonical, always-present record**;
  `tool_result`'s copies are an interactive-only convenience.
- **`request_id` / `tool_use_id`** — opaque high-cardinality join keys (request →
  API-side logs; `tool_use_id` joins `tool_decision` ⇄ `tool_result`). Useful for
  correlation, low value as scan columns.
- **Hooks** (`hook_execution_*`) — a *hook* is a shell command Claude Code runs at
  a lifecycle event (`hook_event`: `UserPromptSubmit`, `PostToolUse`, `Stop`, …;
  `hook_name` adds the tool matcher, e.g. `PostToolUse:Edit`). Hooks come from
  settings or plugins; here the enabled `security-guidance` plugin supplies them.
  `hook_execution_complete` carries the outcome counts and `total_duration_ms`.
- **`hook_source` / `managed_only`** — on *execution* events `hook_source` is only
  `merged` (normal) or `policySettings` (managed-only mode), 1:1 with
  `managed_only`. The granular origins (`userSettings` / `projectSettings` /
  `localSettings` / `flagSettings` / `pluginHook` / `policySettings`) live on the
  `hook_registered` event (one per hook at session start) — query that event for
  the source breakdown. ([monitoring-usage docs](https://code.claude.com/docs/en/monitoring-usage.md))
- **Subagent** (`subagent_completed`) — `agent_type` (which subagent, e.g.
  `claude-code-guide`), `agent_source` (`built-in` / project / user / plugin),
  `is_async` (background vs blocking), `model`; `is_built_in` is the redundant
  boolean form of `agent_source`. The `numeric_labels` (`duration_ms`,
  `total_tokens`, `total_tool_uses`) are true numbers.

## Content-exposure gates

The four `OTEL_LOG_*` gates ship as `0` in the telemetry config examples. What
each gate changes — by data stream, document, and field:

### `OTEL_LOG_USER_PROMPTS`

| Data stream | Documents | Field | `0` (default) | `1` |
| --- | --- | --- | --- | --- |
| `logs-apm.app.claude_code-default` | `message: claude_code.user_prompt` | `labels.prompt` | `<REDACTED>` | verbatim prompt text |
| `traces-apm-agents_claude_code` | `labels.span_type: interaction` (the `claude_code.interaction` root, `processor.event: transaction`) | `labels.user_prompt` | `<REDACTED>` | verbatim prompt text |

- One flag governs both data streams — the event field and the trace-span field
  flip together; nothing else changes.
- No retroactivity — documents ingested while the gate was off stay
  `<REDACTED>`; only new emissions carry text.
- No side effects — no other `message` type gains content; `labels.tool_input` /
  `labels.full_command` / `labels.file_path` remain entirely absent from the
  mapping (those belong to the `OTEL_LOG_TOOL_DETAILS` gate).
- `labels.prompt_length` (events) and `numeric_labels.user_prompt_length` (trace
  root) are emitted regardless of the gate and match the (hidden or visible)
  text length.

### `OTEL_LOG_TOOL_DETAILS`

| Data stream | Documents | Field | `0` (default) | `1` |
| --- | --- | --- | --- | --- |
| `logs-apm.app.claude_code-default` | `message: claude_code.tool_result` | `labels.tool_input` | absent | JSON-serialized tool arguments, every tool incl. MCP (e.g. Bash `command`, Read `file_path`; values >512 chars truncated, payload capped ~4 KB) |
| `logs-apm.app.claude_code-default` | `message: claude_code.tool_result` | `labels.tool_parameters` | absent | tool-specific JSON string — Bash: `bash_command` / `full_command` / `description`; MCP tools (`tool_name: mcp_tool`): `mcp_server_name` / `mcp_tool_name` |
| `logs-apm.app.claude_code-default` | `message: claude_code.tool_decision` | `labels.tool_parameters` | absent | same shape — shows *what* the accept/reject decision was about |
| `logs-apm.app.claude_code-default` | `message: claude_code.mcp_server_connection` | `labels.server_name` | absent | the configured MCP server name (e.g. `elasticsearch`) — this event otherwise has no server-name field at all |

- The command / path detail lives **inside the `tool_input` / `tool_parameters`
  JSON strings** — no flat `labels.full_command` / `labels.file_path` fields
  materialize on events.
- The capture is **shallow**: objects nested inside the arguments collapse to
  the literal string `"<nested>"` in `tool_input`. Observed on MCP tool inputs,
  whose arguments are typically nested (e.g. a search tool's `query_body`
  interior is not recorded); built-in tools' flat arguments (Bash `command`,
  Read `file_path`) appear in full.
- **Trace spans are unchanged** — span-side `tool_input` / `file_path` content
  attributes belong to *detailed* beta tracing, not this gate; on the plain
  enhanced beta the tool spans look identical either way.
- Per the upstream docs, the gate also switches `labels.error` on failed tools
  from an error category to the full error message, and stops collapsing
  custom/plugin/MCP `command_name` values on `user_prompt` to `custom` / `mcp`.

### `OTEL_LOG_TOOL_CONTENT`

| Data stream | Documents | Field | `0` (default) | `1` |
| --- | --- | --- | --- | --- |
| `logs-apm.app.claude_code-default` | `message: tool.output` — a new document type | `labels.output` (Bash: command stdout) / `labels.content` (Read: file contents) / `labels.diff` + `labels.file_path` (Edit: structured diff) | documents don't exist | verbatim tool output |

- The upstream docs describe this as a `tool.output` *span event* on
  `claude_code.tool.execution` (60 KB cap, requires tracing). **Physically it
  lands as a document in the events data stream**, not in the traces stream —
  the tool spans themselves are unchanged. (`gen_ai.request.attempt`,
  also documented as a span event, lands the same way: a bare-named `message`
  in the events stream.)
- **Coverage is partial** — Bash (`labels.output`), Read (`labels.content`),
  and Edit (`labels.diff`, a structured diff, plus `labels.file_path`) produce
  `tool.output` documents (Write untested); **MCP tools and ToolSearch produce
  none**, so data returned through MCP integrations is invisible to this gate.
  Edit's variant is the only one carrying `file_path` — the attribution that
  rides along is inconsistent across tools.
- **With tracing disabled the gate emits nothing** — set
  `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=0` and no `tool.output` documents
  appear at all, while `tool_result` (and its `OTEL_LOG_TOOL_DETAILS` fields)
  continues unaffected. The upstream "requires tracing" is real behaviour:
  content capture depends on the beta tracing feature.
- Each doc carries top-level `span.id` and `trace.id`. The `span.id` points at
  the **`claude_code.tool` span** (the parent — not `tool.execution`), which
  carries `labels.tool_name` and `labels.tool_use_id`: the only attribution of
  this content to a tool.
- **Reconstructing one call's input + output takes both gates and a two-hop
  join**: `tool.output.span.id` → the `claude_code.tool` span in the traces
  stream (`tool_name`, `tool_use_id`) → `tool_use_id` → the
  `claude_code.tool_result` event (`tool_input` from `OTEL_LOG_TOOL_DETAILS`).
  A direct `span.id` join between `tool.output` and `tool_result` does **not**
  work — `tool_result`'s `span.id` references a different span, shared across
  the turn's tool calls.
- The content attribute varies by tool — `output` for Bash, `content` for
  Read, `diff` for Edit — and only output-side content appears (input capture
  belongs to `OTEL_LOG_TOOL_DETAILS`' `tool_input`).
- These docs carry **no `labels.user_*` / `prompt_id` envelope** — identity is
  only top-level (`service.name`, `session.id`, host fields). They match no
  `message: claude_code.*` filter, so they surface only in **Event Overview**
  (no `message` pill) or a dedicated view.

### `OTEL_LOG_RAW_API_BODIES`

| Data stream | Documents | Field | `0` (default) | `1` |
| --- | --- | --- | --- | --- |
| `logs-apm.app.claude_code-default` | `message: claude_code.api_request_body` (one per API attempt) / `claude_code.api_response_body` (one per response) | `labels.body` (+ `labels.body_length`, `labels.body_truncated`) | documents don't exist | Messages API request/response JSON — see the truncation chain |

- Unlike `tool.output`, these documents carry the **full envelope** —
  `labels.user_*`, `prompt_id`, `model`, `query_source` (plus `request_id` on
  responses) — and `trace.id` / `span.id` when tracing is on.
- **Three truncation stages** apply before anything is stored: the original
  body (recorded in `labels.body_length`; ~2.9 MB for a long conversation) →
  Claude Code's inline cap of **60 KB** (`labels.body_truncated: true`) →
  **APM Server's label-value cap of 1,024 characters**. What is actually stored
  in `labels.body` is the **first ~1 KB of JSON** — even a 2.7 KB response body
  is cut at 1,024.
- The surviving fragment is the **head** of the JSON — the **oldest**
  conversation content (the first message). In a long session the recent turns
  never reach the stored value at all.
- Within that fragment, message text appears **unredacted regardless of the
  other three gates** — the documented "implies consent to everything
  `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` / `OTEL_LOG_TOOL_CONTENT`
  would reveal" is real behaviour. The one exception: extended thinking arrives
  as `"thinking":"<REDACTED>"` (its `signature` blob is kept).
- Net effect on this stack: inline mode (`=1`) stores ~1 KB of the oldest
  content per API call — of little audit value.
- **`file:<dir>` mode lifts the truncation chain entirely.** The same events
  keep flowing, but the inline `labels.body` is replaced by
  **`labels.body_ref`** (absolute path to an on-disk file),
  `labels.body_length` matches the file size byte-for-byte, and
  `body_truncated` disappears — the pointer/cold-file model, natively. The
  files are the **raw Messages API bodies, verbatim, no wrapper**: requests as
  `<uuid>.request.json` (~400 KB each in a long session — the full `system`
  prompt, every `messages` entry, all `tools` definitions), responses as
  `req_<request_id>.response.json` (the complete response incl. `usage`). The
  request-file UUID is its own opaque ID — it does **not** match
  `client_request_id`; `body_ref` is the only join key. MCP tool calls and
  results appear inside the bodies (the `tool.output` MCP gap does not exist
  here). Extended thinking stays `"thinking":"<REDACTED>"` **even on disk** —
  the redaction happens at capture, not truncation; that is the one gap to
  full fidelity. Untested: retry behavior (one file per attempt?), whether
  the directory is auto-created (this repo pre-creates the gitignored
  `var/api-bodies/`).

## Generating events that don't occur in a normal session

Some events only fire under specific conditions — handy when populating the demo:

- **`mcp_server_connection`** fires only when an MCP server *actually connects*.
  claude.ai connectors stuck at "needs authentication" never connect, so they
  emit nothing. To produce one, add a no-auth local stdio server, start a
  session (it connects), then remove it:

  ```sh
  claude mcp add everything -- npx -y @modelcontextprotocol/server-everything
  claude            # start a session — the server connects → one mcp_server_connection event
  claude mcp remove everything
  ```

- **`permission_mode_changed`** — cycle the permission mode with **Shift+Tab**
  (or `/permissions`) in a session: default → acceptEdits → plan → auto.
- **`auth` with `action: login`** — only an **in-session `/login`** produces it
  (account switch in an already-authenticated session). `/logout` exits the CLI,
  so the subsequent cold-start login lands no event; run `/login` *without*
  logging out first to capture one. (`action: logout` always lands.)
