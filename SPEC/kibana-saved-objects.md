# Kibana saved objects — design (claude-code-elastic)

How the `claude-code-elastic` Kibana objects (data views, saved searches, the
Overview dashboard) are shaped and why. The signals these views sit on top of —
every metric, event, and span field — are in
[`claude-code-telemetry.md`](claude-code-telemetry.md). The objects ship as
importable NDJSON split across the components: the backend's cross-agent data
view in `components/backends/elastic/kibana/agents-data-views.ndjson`, and the
Claude Code agent's data views, saved searches, and dashboard in
`components/agents/claude-code/kibana/`.

## Saved-search columns

The shipped saved searches all live on the **Claude Code — Events** data view —
which is **physically scoped to the agent's own data stream**
(`logs-apm.app.claude_code*`), so **no `service.name` filter pill is needed** (the
`*-apm.app.<service>-default` dataset is keyed by `service.name`, and the
smoke-test probe / any other producer land in their own `*.app.<service>-default`
streams). They sort `@timestamp` desc and constrain on `message` as a **single
filter pill** — except **Event Overview**, which has **no filter pill at all** and
leaves `message` as a visible column, so every event type shows (the
cross-event-type timeline). Most end with `labels.prompt_id` (the key
that ties together every event from one prompt) — except **MCP Server
Connections** and **Hook Registered** (both fire at startup, no `prompt_id`) and
**Auth Events** (account/session-level, so the `prompt_id` it carries is omitted
as meaningless). Each event search also **appends `trace.id` as its final
column** — populated only while tracing is on, it is the cross-signal bridge to
the trace spans (`events.trace.id == span.trace.id`) and renders as a
**click-through to the APM UI trace view** via a URL field formatter on the data
view (startup events like MCP Server Connections may have no `trace.id`).
**Every search leads with `labels.user_email`** — the "who", present on every
event type. It is part of the audit/observability shape of these views and is
*not* dropped for being a constant value in this single-user lab (a column is
judged by its real multi-user/multi-org meaning). **Exception: Tool Output** —
`tool.output` documents carry no `labels.user_*` / `prompt_id` envelope at all,
so that search cannot lead with it. Columns were chosen against live data:

| Saved search (`message:`) | Distinguishing columns (besides the universal `user_email` lead and the `prompt_id` trailer) | Left out |
| --- | --- | --- |
| **Event Overview** (no `message` filter — all event types) | `message`, `session.id` | per-event-type detail fields (drill into a per-`message` search for those); expand a row in Discover for the full document. `message` is the "what" column here, not a filter |
| **API Requests** (`api_request`) | `model`, `query_source`, `speed`, `effort`; `numeric_labels` `duration_ms`, `cost_usd`, `{input,output,cache_read,cache_creation}_tokens` | `request_id` (opaque) |
| **Tool Results** (`tool_result`) | `tool_name`, `decision_type`, `decision_source`, `success`, `duration_ms`, `tool_{input,result}_size_bytes`, `tool_input`, `tool_parameters` (gate-aware — empty unless `OTEL_LOG_TOOL_DETAILS=1`) | `tool_use_id`; note `decision_*` is interactive-only |
| **Tool Decisions** (`tool_decision`) | `tool_name`, `decision`, `source`, `tool_parameters` (*what* was accepted/rejected — empty unless `OTEL_LOG_TOOL_DETAILS=1`) | `tool_use_id` (the canonical permit decision, present in headless runs too) |
| **User Prompts** (`user_prompt`) | `prompt`, `prompt_length` (content first, size second) | — (`prompt` is `<REDACTED>` unless `OTEL_LOG_USER_PROMPTS=1`; kept regardless — column choice isn't a PII control) |
| **Hook Registered** (`hook_registered`) | `hook_event`, `hook_type`, `hook_source`, `plugin_name` | `prompt_id` (n/a — fires at startup); `hook_name` (not on this event — lives on the execution events); `plugin_id_hash` (opaque); `managed_only` (not present here). `hook_source` is the granular origin (only this event carries it) — kept though it is all `pluginHook` in this single-user lab |
| **Hook Executions** (`hook_execution_complete`) | `hook_event`, `hook_name`, `num_hooks`, `num_success`, `num_blocking`, `total_duration_ms` | `hook_source` / `managed_only` (redundant 2-value pair); `num_*` are string labels |
| **Subagent Completions** (`subagent_completed`) | `agent_type`, `agent_source`, `model`, `is_async`; `numeric_labels` `duration_ms`, `total_tokens`, `total_tool_uses` | `is_built_in` (≡ `agent_source`) |
| **Permission Mode Changes** (`permission_mode_changed`) | `from_mode`, `to_mode`, `trigger` | — (permission-posture audit: mode cycling via `shift_tab` etc.) |
| **MCP Server Connections** (`mcp_server_connection`) | `server_name` (right after the lead — the primary scan column; empty unless `OTEL_LOG_TOOL_DETAILS=1`), `status`, `transport_type`, `server_scope`, `is_plugin`, `duration_ms` | `prompt_id` (n/a — fires at startup) |
| **Auth Events** (`auth`) | `action`, `success`, `auth_method` | `prompt_id` (present but omitted — account/session-level, not prompt-level); the other identity/PII labels (`user_id`, `user_account_*`, `organization_id`); failure-only `error_category` / `status_code`. Logout-biased — cold-start login isn't captured (see the Events section of [`claude-code-telemetry.md`](claude-code-telemetry.md)) |
| **Tool Output** (`tool.output` — bare name, no `claude_code.` prefix) | `output` (Bash), `content` (Read), `diff` + `file_path` (Edit), `span.id`, `trace.id` | the `user_email` lead and `prompt_id` trailer — **impossible**, these docs carry no envelope (see the Content-exposure gates in [`claude-code-telemetry.md`](claude-code-telemetry.md)). Empty unless `OTEL_LOG_TOOL_CONTENT=1` *and* tracing are on — the standing audit lens for that gate |
| **API Bodies** (`message` is one of `api_request_body` / `api_response_body` — a `phrases` pill) | `message` (req vs resp), `model`, `query_source`, `body_length`, `body_truncated` | `request_id`; `labels.body` itself (a ~1 KB head fragment after the truncation chain — row-expand material, not a column). Low practical utility, kept as the lab's lens on `OTEL_LOG_RAW_API_BODIES` |

The two **traces** saved searches — **Claude Code — Interactions** (one row per
interactive turn, `span_type: interaction`) and **Claude Code — Traces** (one row
per trace, `processor.event: transaction`) — sit on the per-agent traces data view
rather than the Events view; their columns and the interactive-vs-headless
granularity caveat are in the [Trace data model](claude-code-telemetry.md#trace-data-model).

**Claude Code — Tool I/O (joined)** is a third flavour: the repo's first
**ES|QL saved Discover session** (a query, not a data-view-plus-pills object).
It unions the events and traces streams and reconstructs **one row per tool
call** with a two-hop STATS join — `span.id` merges `tool.output` with its
`claude_code.tool` span (`tool_name`, `tool_use_id`), then `tool_use_id` merges
in `tool_result` (`tool_input`, `user_email`, `prompt_id` — restoring the
attribution raw `tool.output` lacks). Columns: `ts`, `user_email`, `tool`,
`input`, `content`, `prompt_id`, `trace_id`. The working query lives in the PRD
task that ships it.

## Why saved searches and not more data views

A Kibana data view is only an index-pattern + time field — it can't store a query
or columns — so per-`message` curated views are saved searches on the Events data
view, not extra data views.

## Not yet covered

- No saved search for `hook_plugin_metrics` (plugin-specific, 20+ numeric fields —
  a dedicated view later) or `feedback_survey` (noise).
- A starter **Overview dashboard** (Lens) ships in
  `components/agents/claude-code/kibana/dashboard.ndjson`; richer dashboards
  (cost/token trends, model breakdown, tool success, latency distribution) can
  follow — mind the string-vs-numeric caveat in
  [`claude-code-telemetry.md`](claude-code-telemetry.md#how-to-read-the-data).

## Regenerating the Kibana saved objects

The data views and saved searches are hand-authored NDJSON; the dashboard was
built in Kibana and exported. To re-export a saved object after editing it in
the UI — no UI export step required — use the Saved Objects **export API**:

```sh
curl -s -X POST "http://localhost:5601/api/saved_objects/_export" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{"objects":[{"type":"dashboard","id":"claude-code-overview"}],"includeReferencesDeep":false}' \
  > ../../components/agents/claude-code/kibana/dashboard.ndjson
```

`includeReferencesDeep: false` keeps the data views as *references* rather than
bundling them, matching how these files are split (import data views first, then
the dependants). UI equivalent: Stack Management → Saved Objects → select →
**Export**, "Include related objects" off. A freshly-built object exports with a
random id — give it a stable id (no `cce-` prefix, like the others) before committing.
