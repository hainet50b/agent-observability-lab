# claude-code-elastic

> Claude Code → APM Server (Elastic-native OTLP) → Elasticsearch → Kibana.
> Bring it up, point a Claude Code session at it, and inspect the real
> **metrics** (sessions, tokens, cost, code edits, commits) and **events**
> (prompts, tool results, API requests) the agent emits.

```
Claude Code  ──OTLP/HTTP (+gRPC)──▶  APM Server  ──▶  Elasticsearch  ──▶  Kibana
(metrics + events)                   :8200            :9200                :5601
```

**APM Server** is the OTLP receiver here — Elastic's native, fully-supported way
to ingest OpenTelemetry straight into Elasticsearch. Claude Code points at it
directly rather than through an OpenTelemetry Collector; both are valid, and a
Collector-based variant would be a separate stack.

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. The events channel can capture your
> prompt text and tool I/O — don't run a telemetry-enabled session containing
> secrets or confidential material against this stack, and never commit captured
> telemetry into the repo.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl` and `jq` (used by the smoke test and the manual import path).
- Claude Code, to generate real telemetry.

## Quick Tour

The shortest path from clone to "I see Claude Code telemetry in Kibana."

### 1. Bring the stack up

```sh
cd stacks/claude-code-elastic
docker compose up -d
docker compose ps        # wait until all three services report healthy
```

Kibana is then at <http://localhost:5601>. Optionally prove the pipeline end to
end with the smoke test (see [Verify the pipeline](#verify-the-pipeline)):

```sh
scripts/smoke-test.sh
```

If you will enable [Traces](#traces-beta), install the trace-routing pipeline once
(it isolates Claude Code's spans into `traces-apm-claudecode` — see
[Trace data model](#trace-data-model)); run it any time after the stack is healthy:

```sh
scripts/setup-trace-routing.sh        # bash/zsh/sh  (or ./setup-trace-routing.ps1)
```

### 2. Point a Claude Code session at the stack

The telemetry vars configure **`claude`** itself, not the stack — supply them one
of three ways. They enable `CLAUDE_CODE_ENABLE_TELEMETRY` and the `OTEL_*`
exporters for **both** metrics and events at the APM Server OTLP endpoint on
`:8200`, with short export intervals so data appears quickly.

**Option A — shell env (one-off, recommended).** Paste into the shell that runs
`claude`, then launch it from *any* directory. Ephemeral and side-effect-free
(creates no files), so you can fire a single session's telemetry into the demo
from wherever you like.

```sh
# bash / zsh
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:8200
export OTEL_METRIC_EXPORT_INTERVAL=10000
export OTEL_LOGS_EXPORT_INTERVAL=5000
# Traces (beta) — span tree (interaction → llm_request / tool); needed for OTEL_LOG_TOOL_CONTENT
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
export OTEL_TRACES_EXPORTER=otlp
export OTEL_TRACES_EXPORT_INTERVAL=5000
# Content-exposure gates — kept off; flip a single one to 1 to capture that slice
export OTEL_LOG_USER_PROMPTS=0     # user prompt text
export OTEL_LOG_TOOL_DETAILS=0     # tool inputs/args (commands, file paths, …)
export OTEL_LOG_TOOL_CONTENT=0     # tool input+output content (needs tracing)
export OTEL_LOG_RAW_API_BODIES=0   # full Messages API request/response bodies
```

```fish
# fish
set -gx CLAUDE_CODE_ENABLE_TELEMETRY 1
set -gx OTEL_METRICS_EXPORTER otlp
set -gx OTEL_LOGS_EXPORTER otlp
set -gx OTEL_EXPORTER_OTLP_PROTOCOL http/protobuf
set -gx OTEL_EXPORTER_OTLP_ENDPOINT http://localhost:8200
set -gx OTEL_METRIC_EXPORT_INTERVAL 10000
set -gx OTEL_LOGS_EXPORT_INTERVAL 5000
# Traces (beta) — span tree (interaction → llm_request / tool); needed for OTEL_LOG_TOOL_CONTENT
set -gx CLAUDE_CODE_ENHANCED_TELEMETRY_BETA 1
set -gx OTEL_TRACES_EXPORTER otlp
set -gx OTEL_TRACES_EXPORT_INTERVAL 5000
# Content-exposure gates — kept off; flip a single one to 1 to capture that slice
set -gx OTEL_LOG_USER_PROMPTS 0     # user prompt text
set -gx OTEL_LOG_TOOL_DETAILS 0     # tool inputs/args (commands, file paths, …)
set -gx OTEL_LOG_TOOL_CONTENT 0     # tool input+output content (needs tracing)
set -gx OTEL_LOG_RAW_API_BODIES 0   # full Messages API request/response bodies
```

```powershell
# PowerShell
$env:CLAUDE_CODE_ENABLE_TELEMETRY = "1"
$env:OTEL_METRICS_EXPORTER = "otlp"
$env:OTEL_LOGS_EXPORTER = "otlp"
$env:OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
$env:OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:8200"
$env:OTEL_METRIC_EXPORT_INTERVAL = "10000"
$env:OTEL_LOGS_EXPORT_INTERVAL = "5000"
# Traces (beta) — span tree (interaction → llm_request / tool); needed for OTEL_LOG_TOOL_CONTENT
$env:CLAUDE_CODE_ENHANCED_TELEMETRY_BETA = "1"
$env:OTEL_TRACES_EXPORTER = "otlp"
$env:OTEL_TRACES_EXPORT_INTERVAL = "5000"
# Content-exposure gates — kept off; flip a single one to "1" to capture that slice
$env:OTEL_LOG_USER_PROMPTS = "0"     # user prompt text
$env:OTEL_LOG_TOOL_DETAILS = "0"     # tool inputs/args (commands, file paths, …)
$env:OTEL_LOG_TOOL_CONTENT = "0"     # tool input+output content (needs tracing)
$env:OTEL_LOG_RAW_API_BODIES = "0"   # full Messages API request/response bodies
```

**Option B — `settings.json` `env` block (persistent).** Put the same vars in a
Claude Code settings file's `env`:

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:8200",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",

    "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
    "OTEL_TRACES_EXPORTER": "otlp",
    "OTEL_TRACES_EXPORT_INTERVAL": "5000",

    "OTEL_LOG_USER_PROMPTS": "0",
    "OTEL_LOG_TOOL_DETAILS": "0",
    "OTEL_LOG_TOOL_CONTENT": "0",
    "OTEL_LOG_RAW_API_BODIES": "0"
  }
}
```

The four `OTEL_LOG_*` content-exposure gates are shown here explicitly set to
`0` (off) so they are visible knobs to flip during verification — Claude Code
enables each only on `1` (or `file:<dir>` for `OTEL_LOG_RAW_API_BODIES`), so `0`
and "unset" both mean off. Flip **one at a time** to observe what it adds, and
keep real secrets out of any session while a gate is on.

Project settings load **only from the directory `claude` is launched in** (not
inherited from parents), so a stack-local `.claude/settings.local.json` keeps
telemetry on only when you launch from inside the stack; `~/.claude/settings.json`
applies everywhere.

**Option C — `managed-settings.json` (org enforcement).** Enterprise/MDM-distributed
[managed settings](https://code.claude.com/docs/en/monitoring-usage.md) have the
**highest precedence and cannot be overridden by users** — the way to force
telemetry on across an organization.

Then run `claude` from a configured shell/directory and do a little work (ask a
question, let it read or edit a file). Telemetry flushes on the export interval,
so data lands within ~10–30s.

### 3. Import the Kibana saved objects

Importable NDJSON ships under `kibana/`: the **data views**
(`claude-code-data-views.ndjson`), the **saved searches**
(`claude-code-saved-searches.ndjson`), and a **dashboard**
(`claude-code-dashboard.ndjson`):

| Saved object | Type | Shows |
| --- | --- | --- |
| **Claude Code — Metrics** | data view (`metrics-apm.app*`) | the numeric metric documents |
| **Claude Code — Events** | data view (`logs-apm.app*`) | the prompt / tool-result / API-request events |
| **Event Overview**, **API Requests**, **Tool Results**, **Tool Decisions**, **User Prompts**, **Hook Registered**, **Hook Executions**, **Subagent Completions**, **Permission Mode Changes**, **MCP Server Connections**, **Auth Events** | saved searches | **Event Overview** is the all-event-types timeline; the rest are per-`message` curated column views on the Events data view |
| **Claude Code — Overview** | dashboard | a starter demo dashboard — Lens panels over the metrics & events data views |

The saved searches and the dashboard **reference the data views**, so import the
data views first (or all files together). The saved searches' columns and the
reasoning behind them are in the [Telemetry reference](#saved-search-columns).

- **Import helper (recommended)** — imports the `kibana/` files in dependency
  order (data views first); run from anywhere:

  ```sh
  scripts/import-kibana-objects.sh     # bash/zsh/sh
  ```
  ```pwsh
  ./scripts/import-kibana-objects.ps1  # PowerShell 7+
  ```

  Override the Kibana base URL with `KIBANA_URL` (or `-KibanaUrl` for the `.ps1`);
  both default to `http://localhost:5601`.

- **Kibana UI** — Stack Management → Saved Objects → **Import** → choose the
  `.ndjson` file(s), data views first.
- **Manual API** — `POST` each file (data views first) to
  `/api/saved_objects/_import?overwrite=true` with header `kbn-xsrf: true`; the
  helper above just wraps this.

### 4. See the telemetry in Kibana

- **Discover** — pick the **Claude Code — Metrics** or **Events** data view, or
  open one of the saved searches from the **Open** menu. Each saved search
  opens with its `message` / `service.name` constraints as removable **filter
  pills** (the query bar stays empty). The field layout is explained in the
  [Telemetry reference](#telemetry-reference).
- **APM UI** (<http://localhost:5601/app/apm>) — Claude Code registers as an APM
  **service** (`claude-code`); open it to see it as a first-class APM entity.

### 5. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe ingested telemetry
```

## Verify the pipeline

`scripts/smoke-test.sh` checks the full **OTLP → APM Server → Elasticsearch** path
end to end, following the 3A pattern: **Arrange** brings the stack up and waits
for health; **Act** POSTs a synthetic OTLP metrics + logs probe (tagged
`service.name = cce-smoke-test`) to the OTLP/HTTP endpoint; **Assert** confirms
the docs landed in the APM data streams, then prints the `service.name` values
present so real `claude-code` telemetry shows up alongside the probe. A synthetic
probe is used (not a real `claude` session) so the check is deterministic and
runnable as a gate; real telemetry travels the identical path under its own name.

```sh
scripts/smoke-test.sh    # from anywhere — it locates its own stack directory
```

Needs `docker` (running daemon), `curl`, `jq`; it **SKIPs** (exit 0) when the
daemon is unreachable. Override endpoints with `ES_URL` / `APM_OTLP_URL`.

## Layout

```
claude-code-elastic/
├─ docker-compose.yml                     # Elasticsearch + Kibana + APM Server (Stack 9.4.2)
├─ config/
│  └─ apm-server.yml                      # APM Server as the OTLP receiver
├─ kibana/
│  ├─ claude-code-data-views.ndjson       # importable Discover data views (metrics, events, traces)
│  ├─ claude-code-saved-searches.ndjson   # importable per-message saved searches
│  └─ claude-code-dashboard.ndjson        # the "Overview" demo dashboard
└─ scripts/
   ├─ smoke-test.sh                       # end-to-end pipeline verification
   ├─ import-kibana-objects.sh            # import the kibana/ objects (data views first)
   ├─ import-kibana-objects.ps1           # PowerShell mirror of the import helper
   ├─ setup-trace-routing.sh             # install traces-apm@custom (route claude-code spans → traces-apm-claudecode)
   └─ setup-trace-routing.ps1            # PowerShell mirror of the trace-routing setup
```

## Telemetry reference

What Claude Code actually emits into this stack, captured from live sessions
(`service.name = claude-code`, Claude Code 2.1.159, Stack 9.4.2). Discover is the
source of truth for the version you run — names and fields can change.

### How to read the data

- **Three data streams:** `metrics-apm.app.claude_code-default` (metrics),
  `logs-apm.app.claude_code-default` (events), and — when [Traces](#traces-beta)
  are enabled — `traces-apm-claudecode` (spans, routed there from the
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
`host.os.*`, `data_stream.*`, and `session.id` (top-level, not a label — see
[Field meanings](#field-meanings-worth-recording)); common `labels.*` are
`user_*`, `organization_id`, `terminal_type`.

### Metrics (`metrics-apm.app.claude_code-default`)

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

### Events (`logs-apm.app.claude_code-default`, discriminated by `message`)

| `message` | Notable fields |
| --- | --- |
| `claude_code.user_prompt` | `labels.prompt_id`, `prompt_length` (string), `prompt` (`<REDACTED>` unless `OTEL_LOG_USER_PROMPTS=1`) |
| `claude_code.api_request` | `labels.model`, `request_id`, `query_source`, `speed`, `effort`; `numeric_labels.input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cost_usd`, `cost_usd_micros`, `duration_ms` |
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

`claude_code.api_error` fires only when an API request fails, so it shows up
only once an error has occurred. `claude_code.hook_registered` fires once per
configured hook at session start and carries the granular `hook_source` origins
(see below).

**`claude_code.auth` is logout-biased.** `/logout` runs while telemetry is still
alive, so the `action: logout` event reliably lands — but `/logout` then *exits*
the CLI, and the next `claude` start goes to the login screen *outside* a
telemetry session, so a normal cold-start login is never captured. The only path
that produces an `action: login` event is an **in-session `/login`** (switching
accounts in an already-authenticated session). Treat auth events as a
sign-*out* audit, not a usage-start signal; for session starts use the
`claude_code.session.count` metric (`start_type: fresh/continue`) instead.

### Traces (beta)

A third, optional signal. Tracing is **off by default**; the Quick Tour config
enables it with `CLAUDE_CODE_ENABLE_TELEMETRY=1` + `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`
+ `OTEL_TRACES_EXPORTER=otlp` (endpoint/protocol reuse the common OTLP config —
this stack's `http/protobuf` → `:8200`). APM Server receives spans natively on
`/v1/traces` (no server change); this stack then **routes** Claude Code's spans
into the dedicated **`traces-apm-claudecode`** data stream (see Trace data model
below).

- **What it adds:** each user prompt becomes a `claude_code.interaction` root span,
  with `claude_code.llm_request` and `claude_code.tool` children (a tool span has
  two children — the permission-decision wait and the execution). This links a
  prompt to the API calls and tool runs it triggered as one trace.
- **Where to view it:** the **APM UI** (<http://localhost:5601/app/apm>) — service
  map and trace waterfalls — is the natural home; the `traces-apm-claudecode*` data
  view also lets you scan spans in Discover.
- **Content is still redacted by default.** Spans redact prompt text, tool input,
  and tool content unless the matching `OTEL_LOG_*` gate is set. In particular,
  **`OTEL_LOG_TOOL_CONTENT=1` requires tracing** — it adds a `tool.output` span
  event (tool input+output bodies, 60 KB cap) on the `tool` execution span, which
  has no equivalent in the metrics/events streams.
- **Not adopted: "detailed" beta.** A deeper tier (`ENABLE_BETA_TRACING_DETAILED=1`
  + `BETA_TRACING_ENDPOINT`, and an org allowlist for interactive sessions) adds the
  `claude_code.hook` span and extra content attributes. This stack stays on the
  plain enhanced beta; detailed beta is out of scope.

#### Trace data model

APM writes all OTLP spans to one **service-agnostic** data stream
`traces-apm-default` (template `traces-apm@template`, patterns `traces-apm-*`) —
unlike the metrics/events streams, whose dataset embeds the service
(`*-apm.app.claude_code-default`). So out of the box every producer's spans
co-mingle, and a data view can't store a `service.name` filter to separate them.

This stack therefore **physically isolates Claude Code's spans by routing**: a
`reroute` processor in the **`traces-apm@custom`** ingest pipeline (installed by
`scripts/setup-trace-routing.sh`, which the `traces-apm@default-pipeline` already
hooks) sends docs with `service.name: claude-code` to a dedicated
**`traces-apm-claudecode`** data stream — it still matches `traces-apm-*`, so it
keeps the full APM trace mappings; other producers stay in `traces-apm-default`.
The traces data view is scoped to **`traces-apm-claudecode*`**, so it needs no
`service.name` filter. (Spans captured before the pipeline was installed remain in
`traces-apm-default`.) Stronger isolation — per-service namespaces for *every*
producer, an OTel Collector, or a dedicated APM Server — is possible but out of
scope; across agents, the per-stack APM Server boundary already isolates.

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

### Field meanings worth recording

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

### Saved-search columns

The shipped saved searches all live on the **Claude Code — Events** data view,
sort `@timestamp` desc, and constrain on `message` + `service.name: claude-code`
as filter pills — except **Event Overview**, which constrains only on
`service.name` and leaves `message` as a visible column so every event type
shows (the cross-event-type timeline). Most end with `labels.prompt_id` (the key
that ties together every event from one prompt) — except **MCP Server
Connections** and **Hook Registered** (both fire at startup, no `prompt_id`) and
**Auth Events** (account/session-level, so the `prompt_id` it carries is omitted
as meaningless).
**Every search leads with `labels.user_email`** — the "who", present on every
event type. It is part of the audit/observability shape of these views and is
*not* dropped for being a constant value in this single-user lab (a column is
judged by its real multi-user/multi-org meaning). Columns were chosen against
live data:

| Saved search (`message:`) | Distinguishing columns (besides the universal `user_email` lead and the `prompt_id` trailer) | Left out |
| --- | --- | --- |
| **Event Overview** (no `message` filter — all event types) | `message`, `session.id` | per-event-type detail fields (drill into a per-`message` search for those); expand a row in Discover for the full document. `message` is the "what" column here, not a filter |
| **API Requests** (`api_request`) | `model`, `query_source`, `speed`, `effort`; `numeric_labels` `duration_ms`, `cost_usd`, `{input,output,cache_read,cache_creation}_tokens` | `request_id` (opaque) |
| **Tool Results** (`tool_result`) | `tool_name`, `decision_type`, `decision_source`, `success`, `duration_ms`, `tool_{input,result}_size_bytes` | `tool_use_id`; note `decision_*` is interactive-only |
| **Tool Decisions** (`tool_decision`) | `tool_name`, `decision`, `source` | `tool_use_id` (the canonical permit decision, present in headless runs too) |
| **User Prompts** (`user_prompt`) | `prompt_length`, `prompt` | — (`prompt` is `<REDACTED>` unless `OTEL_LOG_USER_PROMPTS=1`; kept regardless — column choice isn't a PII control) |
| **Hook Registered** (`hook_registered`) | `hook_event`, `hook_type`, `hook_source`, `plugin_name` | `prompt_id` (n/a — fires at startup); `hook_name` (not on this event — lives on the execution events); `plugin_id_hash` (opaque); `managed_only` (not present here). `hook_source` is the granular origin (only this event carries it) — kept though it is all `pluginHook` in this single-user lab |
| **Hook Executions** (`hook_execution_complete`) | `hook_event`, `hook_name`, `num_hooks`, `num_success`, `num_blocking`, `total_duration_ms` | `hook_source` / `managed_only` (redundant 2-value pair); `num_*` are string labels |
| **Subagent Completions** (`subagent_completed`) | `agent_type`, `agent_source`, `model`, `is_async`; `numeric_labels` `duration_ms`, `total_tokens`, `total_tool_uses` | `is_built_in` (≡ `agent_source`) |
| **Permission Mode Changes** (`permission_mode_changed`) | `from_mode`, `to_mode`, `trigger` | — (permission-posture audit: mode cycling via `shift_tab` etc.) |
| **MCP Server Connections** (`mcp_server_connection`) | `status`, `transport_type`, `server_scope`, `is_plugin`, `duration_ms` | `prompt_id` (n/a — fires at startup) and any server-name field (none in this version) |
| **Auth Events** (`auth`) | `action`, `success`, `auth_method` | `prompt_id` (present but omitted — account/session-level, not prompt-level); the other identity/PII labels (`user_id`, `user_account_*`, `organization_id`); failure-only `error_category` / `status_code`. Logout-biased — cold-start login isn't captured (see Events notes above) |

Why saved searches and not more data views: a Kibana data view is only an
index-pattern + time field — it can't store a query or columns — so per-`message`
curated views are saved searches on the Events data view, not extra data views.

### Generating events that don't occur in a normal session

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

### Not yet covered

- No saved search for `hook_plugin_metrics` (plugin-specific, 20+ numeric fields —
  a dedicated view later) or `feedback_survey` (noise).
- A starter **Overview dashboard** (Lens) ships in `kibana/claude-code-dashboard.ndjson`;
  richer dashboards (cost/token trends, model breakdown, tool success, latency
  distribution) can follow — mind the string-vs-numeric caveat above.

## Regenerating the Kibana saved objects

The data views and saved searches are hand-authored NDJSON; the dashboard was
built in Kibana and exported. To re-export a saved object after editing it in
the UI — no UI export step required — use the Saved Objects **export API**:

```sh
curl -s -X POST "http://localhost:5601/api/saved_objects/_export" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{"objects":[{"type":"dashboard","id":"cce-claude-code-overview"}],"includeReferencesDeep":false}' \
  > kibana/claude-code-dashboard.ndjson
```

`includeReferencesDeep: false` keeps the data views as *references* rather than
bundling them, matching how these files are split (import data views first, then
the dependants). UI equivalent: Stack Management → Saved Objects → select →
**Export**, "Include related objects" off. A freshly-built object exports with a
random id — give it a stable `cce-…` id (like the others) before committing.
