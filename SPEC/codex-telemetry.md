# Codex CLI telemetry reference (codex-elastic)

What OpenAI Codex CLI actually emits into the `codex-elastic` stack, captured
from a live session (`service.name = codex_cli_rs`, Codex **0.137.0**,
`agent.name = opentelemetry/rust` 0.31.0, Stack 9.4.2, ChatGPT auth). Discover is
the source of truth for the version you run — names and fields change fast (Codex
is high-churn). This is the agent-knowledge companion to the stack's Quick Tour
(`stacks/codex-elastic/README.md`); the Kibana views built on these signals
ship as importable NDJSON in `components/backends/services/kibana/codex/`
(Kibana-consumed assets live in the kibana service component — see `SPEC.md`
"Placement rule").

> ⚠️ **Single-session caveat.** This reference is grounded in one interactive
> session that used the **WebSocket** model transport. The event/metric *mix*
> shifts with config: an SSE-transport session surfaces `codex.sse_event` instead
> of the `codex.websocket_*` family; approval prompts surface `codex.tool_decision`;
> etc. (see [Conditional events](#conditional-events-not-yet-observed)). The field
> *shapes* below are stable; the counts are one session's.

**Optional OTLP auth.** The local demo APM Server runs with security disabled, so
no credential is needed and the rendered `[otel]` config carries none by default. A
stack can still ship one for a secured endpoint: set `telemetry.apm_server.api_key` in the
gitignored `setup.local.conf` (copy from `setup.local.conf.example`) and
`setup-config` renders `headers = { Authorization = "ApiKey <key>" }` into each
`[otel.*.otlp-http]` exporter block. Absent or empty → `headers = {}`, byte-identical
to a no-key run. Symmetric with the audit `agent_audit.elasticsearch.api_key`; see
[`config-deployment.md`](config-deployment.md).

## How to read the data

- **Service name is `codex_cli_rs`, not `codex`.** Codex emits the Rust
  implementation's name, so APM derives the datasets `*-apm.app.codex_cli_rs-default`.
  The lab's human-facing names stay `codex` / `codex-elastic`; everything
  physical (datasets, the trace namespace `agents_codex_cli_rs`) carries the
  `codex_cli_rs` token.
- **Three data streams:** `metrics-apm.app.codex_cli_rs-default` (metrics),
  `logs-apm.app.codex_cli_rs-default` (events), and traces. Traces are **isolated by routing** — the `traces-apm@custom-codex_cli_rs` sub-pipeline reroutes Codex spans (`service.name: codex_cli_rs`) off the service-agnostic `traces-apm-default` to a dedicated `agents_codex_cli_rs` data stream (see [Trace data model](#trace-data-model)). APM also
  auto-creates an empty `metrics-apm.service_summary.1m-default` marker.
- **Where the value/type lives:** a metric's value is in a field *named after the
  metric* (e.g. `codex.turn.token_usage`); an event's type is in
  **`labels.event_name`** (e.g. `codex.tool_result`) — but **only on the
  `trace_safe` family** (below).
- **Attribute split:** string attributes → `labels.*`, numeric → `numeric_labels.*`
  (OTLP key `.` → `_`). ⚠️ **String-vs-numeric inconsistency**, as on Claude Code:
  `duration_ms`, `http_response_status_code`, `attempt`, `success`, `prompt_length`
  arrive as **string** `labels` (not aggregatable without a Lens runtime-field
  cast), while `arguments_length` / `output_length` / `text_input_count` /
  `code_line_number` are true `numeric_labels`.
- ⚠️ **PII / identity lives on one family only.** `labels.user_email`,
  `labels.user_account_id`, and the raw content (`labels.arguments` =
  command, `labels.output` = stdout, the prompt text when `log_user_prompt=true`)
  appear **only on the `log_only` family** — never on the `event_name`-bearing
  `trace_safe` family. The exposure is ES/Kibana access and the
  don't-commit-telemetry invariant, not a view's column list.
- ✅ **Host identity is present** (unlike Claude Code). The `log_only` docs carry
  `host.name` / `host.hostname` (e.g. `SP25L3N-X00005`) and `service.node.name`, so
  a document is attributable to a **device** as well as a person and a
  conversation. No downstream `resourcedetection` is needed for `host.name` here.

**Common envelope** (most docs): `@timestamp`, `service.name` (`codex_cli_rs`),
`service.version` (`0.137.0`), `agent.name` (`opentelemetry/rust`),
`data_stream.*`, and `labels.*` `app_version`, `auth_mode` (`Chatgpt`), `env`
(the `otel.environment` tag, `dev`), `model` (`gpt-5.5`), `slug`, `originator`
(`codex-tui`), `terminal_type`, `conversation_id`. The `log_only` family adds
`user_email`, `user_account_id`, `host.*`.

## The two log families (the defining characteristic)

**Every Codex event is emitted twice** into `logs-apm.app.codex_cli_rs-default`,
as two documents with complementary, **non-overlapping** content. They are
discriminated by `service.framework.name`:

| | `codex_otel.log_only` | `codex_cli_rs` (trace_safe) |
| --- | --- | --- |
| Discriminator | `service.framework.name: codex_otel.log_only`; `event.severity: 9` | `service.framework.name: codex_cli_rs`; `event.kind: event`; `labels.target: codex_otel.trace_safe` |
| `labels.event_name` (`codex.*`) | **absent** | **present** (the event-type field) |
| Identity | `user_email`, `user_account_id`, `host.*` | **absent** |
| Content | `arguments` (command), `output` (stdout), prompt text (gated) | **absent** — only lengths (`numeric_labels.output_length`, `arguments_length`, `output_line_count`) |
| Code provenance | absent | `code_file_path`, `code_module_name`, `numeric_labels.code_line_number`, `message: "event <file>:<line>"` |
| Span/trace correlation | partial | `span.id` / `trace.id` |

In one session: **1724** `log_only` docs, **949** `trace_safe` docs (+1 stray
`codex_otel::events::session_telemetry`). The two **mutually exclusive axes** are
the whole story: `event_name` is on trace_safe only; `user_email` + content is on
log_only only (verified: of 949 trace_safe docs, 0 have `user_email`; of 1724
log_only docs, 1723 do).

**Joining the twins:** they share **`labels.call_id`** (tool events),
**`span.id`**, and **`labels.event_timestamp`**. A join is needed only to combine
fields that are split across the two families in one row — `event_name`
(trace_safe) with raw content/identity (log_only), or the trace_safe size counts
with the log_only body. Many structured fields (`tool_name`, `success`,
`duration_ms`, `call_id`) appear on **both** twins, so a per-purpose view often
needs only one family: a tool-I/O audit (who + command + output + success +
duration) is fully served by the **`log_only` tool twin alone** (filter
`service.framework.name: codex_otel.log_only` + `labels.tool_name` exists, no
join).

**Why two families.** The names are Codex's own privacy classification (Rust
`tracing` *targets*): **`trace_safe`** = events scrubbed of content and identity,
deemed **safe to export** to an observability/trace backend; **`log_only`** =
full-fidelity records (command, output, prompt, `user_email`, `host`) intended to
stay in the **local** log. The design intent is to export the safe set and keep
the full set local. But Codex's **OTLP logs exporter emits both targets**, so the
`log_only` (content + identity) family reaches the backend too — the default-on
tool-payload exposure tracked in openai/codex
[#17909](https://github.com/openai/codex/issues/17909). The boundary holds on the
**traces** path (only trace_safe-shaped data becomes spans) but is defeated on the
**logs** path. So the principled redaction is to **drop the whole
`codex_otel.log_only` family** (at a Collector or the `logs-apm.app@custom` ingest
pipeline) — that keeps exactly Codex's own "safe to export" set; surgically
removing `labels.arguments` / `labels.output` is the finer-grained alternative.

## Metrics (`metrics-apm.app.codex_cli_rs-default`)

Values are APM-histogram (`{counts:[…], values:[…]}`) or counters (`1`); the
metric name *is* the field. Grouped:

| Area | Metric fields | Key labels |
| --- | --- | --- |
| Turn | `codex.turn.token_usage` (by `token_type`: input/output/total/reasoning_output/cached…), `codex.turn.e2e_duration_ms`, `codex.turn.ttft.duration_ms`, `codex.turn.ttfm.duration_ms`, `codex.turn.tool.call`, `codex.turn.memory`, `codex.turn.network_proxy` | `model`, `token_type`, `session_source`, `os` |
| Transport | `codex.websocket.event.duration_ms`, `codex.websocket.request.duration_ms` | |
| Tools / MCP | `codex.tool.call.duration_ms`, `codex.mcp.tools.list.duration_ms`, `codex.mcp.tools.cache_write.duration_ms` | |
| Hooks | `codex.hooks.run` | `hook_name`, `status`, `source` |
| Startup | `codex.startup.phase.duration_ms`, `codex.startup_prewarm.age_at_first_turn_ms`, `codex.sqlite.init.duration_ms` / `.count`, `codex.shell_snapshot.duration_ms`, `codex.db.backfill.duration_ms`, `codex.remote_models.load_cache.duration_ms`, `codex.cloud_config_bundle.load` / `.fetch_attempt` / `.fetch_final` | |
| Thread / skills | `codex.thread.skills.enabled_total`, `.kept_total`, `.truncated`, `.description_truncated_chars` | |
| Misc | `codex.plugins.startup_sync`, `codex.rollout_compression.materialize`, `codex.windows_sandbox.elevated_setup_success` | |

⚠️ **Metrics default to Statsig, not OTLP.** Codex ships `metrics_exporter`
defaulting to `statsig`; the lab template sets it to `otlp-http` explicitly,
else **no metrics reach the stack**. Also `codex exec` (headless) emits **no
metrics** and `codex mcp-server` emits no telemetry at all (openai/codex
[#12913](https://github.com/openai/codex/issues/12913)). No metric saved searches
are built (metric docs aren't Discover rows); the metrics view feeds dashboards.

## Events (`logs-apm.app.codex_cli_rs-default`, discriminated by `labels.event_name`)

Fields below are on the **trace_safe** doc; the **log_only twin** adds identity +
content as noted.

| `labels.event_name` | n | Notable trace_safe fields | log_only twin adds |
| --- | --- | --- | --- |
| `codex.conversation_starts` | 1 | `model`, `provider_name`, `approval_policy` (`on-request`), `sandbox_policy` (`read-only`), `reasoning_summary`, `conversation_id`; `numeric_labels.mcp_server_count` | `user_email`, `user_account_id`, `host.*`, `mcp_servers` (name list, e.g. `codex_apps`) — **one per `conversation_id`** (the session-config line) |
| `codex.user_prompt` | 1 | `prompt_length` (string); `numeric_labels.text_input_count` / `image_input_count` / `local_image_input_count`; `conversation_id` | `user_email`; `prompt` text **only when `log_user_prompt=true`** — **one per user turn** |
| `codex.api_request` | 1 | HTTP-REST call: `endpoint` (e.g. `/models`), `http.request.method`, `http_response_status_code`, `attempt`, `duration_ms`, `success`, `auth_mode` / `auth_env_*` / `auth_header_*` | identity envelope |
| `codex.tool_result` | 35 | `tool_name` (e.g. `shell_command`), `tool_origin` (`builtin`), `mcp_tool`, `call_id`, `success`, `duration_ms`; `numeric_labels.arguments_length` / `output_length` / `output_line_count` | `user_email`; `arguments` (command JSON), `output` (stdout) |
| `codex.websocket_connect` | 1 | WS handshake to the model endpoint: `endpoint` (`/responses`), `duration_ms`, `success`, `auth_header_attached`, `auth_connection_reused` | identity |
| `codex.websocket_request` | 12 | request frame sent on the open WS: `duration_ms` (**send time, not model latency**), `success`, `auth_connection_reused`, `model` | identity |
| `codex.websocket_event` | 894 | per-streamed-event wrapper; `labels.event_kind` (`response.output_text.delta`, `response.completed`, …) — **stream noise** | token counts on `response.completed` (`input/output/tool_token_count`, `numeric_labels.cached_token_count` / `reasoning_token_count`) |
| `codex.turn_ttft` | 1 | `duration_ms` = time-to-first-token for the turn | identity |
| `codex.startup_phase` | 3 | `startup_phase` (e.g. `thread_start_create_thread`), `startup_status` (`ready`), `duration_ms` | identity |

**Stream noise.** `codex.websocket_event` (894) plus the log_only-side
`event_kind: response.*.delta` records (2017 `response.output_text.delta` alone)
are streaming fragments — one per model SSE event. They dominate the stream
(~2900 of ~2674 distinct… i.e. most rows). Curated views filter a specific
`event_name` and so exclude them automatically; only the **Event Overview** must
explicitly drop `codex.websocket_event`.

**Transport note.** This session streamed the model over **WebSocket**
(`websocket_connect` → `websocket_request` frames → `websocket_event` stream),
so the only `codex.api_request` was the `/models` auth probe. A session using the
SSE/HTTP transport would instead emit `codex.sse_event` and route model calls
through `codex.api_request`.

## Traces (`traces-apm-agents_codex_cli_rs`)

Codex emits spans natively (APM receives them on `/v1/traces`, no server change).
This stack **routes** them off the service-agnostic `traces-apm-default` into the
dedicated `traces-apm-agents_codex_cli_rs` data stream: the agent-agnostic
`traces-apm@custom` router dispatches by `service.name` to the per-agent
`traces-apm@custom-codex_cli_rs` sub-pipeline (the real `service.name` is
`codex_cli_rs`, which the sub-pipeline filename matches), which reroutes to
namespace `agents_codex_cli_rs` (see [Trace data model](#trace-data-model)). In one
session ~3,479 spans, `span.type: app` (most are streaming-fragment spans dropped
before the reroute — see [Volume reduction](#volume-reduction-ingest-drops)).

`transaction.name` shows Codex's **internal span tree** rather than a single
"interaction" root: `thread/start`, `turn/start`, `model_client.stream_responses_websocket`,
`transport_worker`, plus the MCP app server (`codex_apps`) operations
`initialize` / `*/list` / `config/batchWrite` / `get_model_info`. There is **no
`claude_code.interaction`-style per-prompt root** observed; the tree is
transport- and component-oriented.

## Trace data model

Same APM constraint as Claude Code: all OTLP spans default to the service-agnostic
`traces-apm-default` (no per-service trace dataset), so isolation is by **routing**.
Isolation reroutes `service.name: codex_cli_rs` → namespace
**`agents_codex_cli_rs`** in the `traces-apm@custom-codex_cli_rs` sub-pipeline (data stream
`traces-apm-agents_codex_cli_rs`, still matching `traces-apm-*` so it inherits APM
trace mappings). The cross-agent glob **`traces-apm-agents_*`** then catches
claude_code, codex_cli_rs, … while excluding non-agent traces. The reasons to
isolate (PII once content gates are on, independent deletion/ILM/RBAC,
experimental/high-churn) are the same as for Claude Code; only traces are routed
(metrics/logs are already per-service).

## Volume reduction (ingest drops)

The dominant document producers are streaming fragments with no analytical value.
Two ingest drops remove them; measured on a representative session they cut
**~94% of trace spans** and **~91% of event/`log_only` docs** with no loss of
content (Codex's export carries none — see below). Two rules govern the design:

- **Leaf-only.** An ES ingest pipeline is stateless and per-document, so it cannot
  reparent children — only a span that is *never* a `parent.id` is safe to drop
  without orphaning descendants.
- **Per-agent sub-pipeline.** The `@custom` pipelines are agent-agnostic routers that
  dispatch by `service.name` to per-agent sub-pipelines, so both drops live in Codex's
  own `…@custom-codex_cli_rs` sub-pipelines and need **no** in-pipeline `service.name`
  gate — the router already confines them to Codex CLI, and a stack without Codex never
  installs them.

**Traces — `traces-apm@custom-codex_cli_rs`, dropped *before* the reroute** (so dropped spans
never reach routing):

| `span.name` | role | leaf? | share |
| --- | --- | --- | --- |
| `receiving` | per-SSE-chunk receive tick (`core/src/session/turn.rs`, ~8 µs) | **yes** (0 children) | ~47% of spans |
| `handle_responses` | per-SSE-event handler; parents `receiving` **and** the meaningful `handle_output_item_done → build_tool_call / handle_tool_call` tool subtree | **no** (intermediate) | ~47% of spans |

`receiving` is a true leaf — dropping it is free. `handle_responses` is
intermediate: dropping it **orphans** the tool-call subtree and degrades the APM
waterfall / flame graph. We drop it anyway by **explicit decision** — at
production scale (hundreds of users) individual trace waterfalls are rarely
opened (consumption is aggregate / dashboard), the volume is decisive (~0.86 TB /
90 d in a 300-user × 150-turn/day × 1-replica model), and orphans self-heal within
the data stream's retention. Condition:
`ctx.span?.name == 'receiving' || ctx.span?.name == 'handle_responses'`.

**Logs — `logs-apm.app@custom-codex_cli_rs`** (the agent-agnostic `logs-apm.app@custom`
router — which the managed `logs-apm.app@default-pipeline` calls via
`ignore_missing_pipeline` — dispatches to it on `service.name`). Drop the three **verified** streaming-delta
`event_kind`s — together ~91% of the stream:

```
   ctx.labels?.event_kind == 'response.output_text.delta'
|| ctx.labels?.event_kind == 'response.function_call_arguments.delta'
|| ctx.labels?.event_kind == 'response.custom_tool_call_input.delta'
```

`?.` is required: `event_kind` is **absent** on the most valuable events
(`codex.user_prompt`, `codex.tool_result`, `response.completed`, …) and
`null == '…'` is safely `false`, so they are kept.

Why an **explicit allowlist, not `endsWith('.delta')`**: these three are confirmed
against the OpenAI Responses API streaming spec as incremental fragments whose
complete value lands on a terminal `.done` event — but there is **no documented
universal guarantee** that *every* `.delta` event is a content-free pure increment,
and the API has other / future `.delta` kinds (refusal, reasoning-summary, …). A
wildcard would blindly drop unverified and future documents — the same
"verify, don't assume" rule that forbids dropping an unproven-leaf span. A new
`.delta` kind joins the list only after its content / reconstructability is
verified.

**No content is lost.** Codex's `codex_otel.log_only` / `trace_safe` export strips
conversation content from these events entirely — the delta docs (and even the
`.done` twins) carry only metadata + `duration_ms`. Per-turn token counts survive
on `response.completed`; latency survives in metrics
(`codex.turn.ttft.duration_ms`, `codex.turn.e2e_duration_ms`). **Metrics are not
dropped** — they are the smallest stream and the only source of internal-runtime
instruments (startup phases, MCP cache, sqlite, transport; see Metrics above).

## Content / privacy gates

- **`otel.log_user_prompt`** (default `false`) — when `true`, the prompt **text**
  appears on the `log_only` `codex.user_prompt` twin (`labels.prompt`); length
  (`prompt_length`, `text_input_count`) is emitted regardless. This is the only
  prompt-text gate; the lab template ships it `false`.
- **`tool_result` content is on by default** — the `log_only` twin carries the
  full `arguments` (command) and `output` (stdout) with no extra gate (unlike
  Claude Code's `OTEL_LOG_TOOL_DETAILS` / `OTEL_LOG_TOOL_CONTENT`). Treat the
  `log_only` stream as content-bearing whenever tools run.

## Conditional events (not yet observed)

Fire under conditions this session didn't hit — add saved searches when observed:

- **`codex.tool_decision`** — when an approval is actually prompted (this session
  auto-approved under `approval_policy: on-request`). Expected: tool name,
  decision (approved/denied), source.
- **`codex.rate_limits`** — rate-limit snapshots (seen as an `event_kind` value
  twice; confirm whether it also surfaces as an `event_name`).
- **`codex.sse_event`** — on the SSE transport instead of WebSocket.
- **API error events** — on failed calls (the Claude Code `api_error` analog);
  exact name unconfirmed.
