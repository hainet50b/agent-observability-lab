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
    "OTEL_LOGS_EXPORT_INTERVAL": "5000"
  }
}
```

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

Two **data views** (`kibana/claude-code-data-views.ndjson`) and six **saved
searches** (`kibana/claude-code-saved-searches.ndjson`) ship as importable NDJSON:

| Saved object | Type | Shows |
| --- | --- | --- |
| **Claude Code — Metrics** | data view (`metrics-apm.app*`) | the numeric metric documents |
| **Claude Code — Events** | data view (`logs-apm.app*`) | the prompt / tool-result / API-request events |
| **API Requests**, **Tool Results**, **Tool Decisions**, **User Prompts**, **Hook Executions**, **Subagent Completions** | saved searches | per-`message` curated column views on the Events data view |

The saved searches **reference the Events data view**, so import data views first
(or both files together). Their columns and the reasoning behind them are in the
[Telemetry reference](#saved-search-columns).

- **Import helper (recommended)** — imports both files in the right order; run
  from anywhere:

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
  open one of the six saved searches from the **Open** menu. Each saved search
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
│  ├─ claude-code-data-views.ndjson       # 2 importable Discover data views
│  └─ claude-code-saved-searches.ndjson   # 6 importable per-message saved searches
└─ scripts/
   ├─ smoke-test.sh                       # end-to-end pipeline verification
   ├─ import-kibana-objects.sh            # import the kibana/ objects (data views first)
   └─ import-kibana-objects.ps1           # PowerShell mirror of the import helper
```

## Telemetry reference

What Claude Code actually emits into this stack, captured from live sessions
(`service.name = claude-code`, Claude Code 2.1.159, Stack 9.4.2). Discover is the
source of truth for the version you run — names and fields can change.

### How to read the data

- **Two data streams:** `metrics-apm.app.claude_code-default` (metrics) and
  `logs-apm.app.claude_code-default` (events). APM Server also auto-creates an
  essentially empty `metrics-apm.service_summary.1m-default` marker — not a useful
  visualization target.
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
`host.os.*`, `data_stream.*`; common `labels.*` are `session_id`, `user_*`,
`organization_id`, `terminal_type`.

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
| `claude_code.hook_execution_start` | `labels.hook_name`, `hook_event`, `hook_source`, `managed_only`, `num_hooks` |
| `claude_code.hook_execution_complete` | + `num_blocking`, `num_success`, `num_cancelled`, `num_non_blocking_error`, `total_duration_ms` |
| `claude_code.hook_plugin_metrics` | `labels.plugin_id`, `hook_event`, `skipped`; many `numeric_labels.*` review metrics (`cost_usd`, `vulns_found`, `files_reviewed`, `tok_*`, …) — plugin-specific (security-guidance) |
| `claude_code.subagent_completed` | `labels.agent_type`, `agent_source`, `model`, `is_async`, `is_built_in`; `numeric_labels.duration_ms`, `total_tokens`, `total_tool_uses` |
| `claude_code.feedback_survey` | `labels.survey_type`, `event_type`, `response`, `appearance_id` — UI survey, low signal |

`claude_code.api_error` and `claude_code.hook_registered` are documented but
haven't landed here (`hook_registered` carries the granular `hook_source`
origins — see below).

### Field meanings worth recording

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
  `localSettings` / `flagSettings` / `pluginHook` / `policySettings`) appear only
  on the uncaptured `hook_registered` event — so to see the source breakdown you'd
  ingest that. ([monitoring-usage docs](https://code.claude.com/docs/en/monitoring-usage.md))
- **Subagent** (`subagent_completed`) — `agent_type` (which subagent, e.g.
  `claude-code-guide`), `agent_source` (`built-in` / project / user / plugin),
  `is_async` (background vs blocking), `model`; `is_built_in` is the redundant
  boolean form of `agent_source`. The `numeric_labels` (`duration_ms`,
  `total_tokens`, `total_tool_uses`) are true numbers.

### Saved-search columns

The six shipped saved searches all live on the **Claude Code — Events** data
view, sort `@timestamp` desc, constrain on `message` + `service.name: claude-code`
as filter pills, and end with `labels.prompt_id` (the key that ties together
every event from one prompt). Columns were chosen against live data:

| Saved search (`message:`) | Curated columns (besides `prompt_id`) | Left out |
| --- | --- | --- |
| **API Requests** (`api_request`) | `model`, `query_source`, `speed`, `effort`; `numeric_labels` `duration_ms`, `cost_usd`, `{input,output,cache_read,cache_creation}_tokens` | `request_id` (opaque) |
| **Tool Results** (`tool_result`) | `tool_name`, `decision_type`, `decision_source`, `success`, `duration_ms`, `tool_{input,result}_size_bytes` | `tool_use_id`; note `decision_*` is interactive-only |
| **Tool Decisions** (`tool_decision`) | `tool_name`, `decision`, `source` | `tool_use_id` (the canonical permit decision, present in headless runs too) |
| **User Prompts** (`user_prompt`) | `prompt_length`, `prompt` | — (`prompt` is `<REDACTED>` unless `OTEL_LOG_USER_PROMPTS=1`; kept regardless — column choice isn't a PII control) |
| **Hook Executions** (`hook_execution_complete`) | `hook_event`, `hook_name`, `num_hooks`, `num_success`, `num_blocking`, `total_duration_ms` | `hook_source` / `managed_only` (redundant 2-value pair); `num_*` are string labels |
| **Subagent Completions** (`subagent_completed`) | `agent_type`, `agent_source`, `model`, `is_async`; `numeric_labels` `duration_ms`, `total_tokens`, `total_tool_uses` | `is_built_in` (≡ `agent_source`) |

Why saved searches and not more data views: a Kibana data view is only an
index-pattern + time field — it can't store a query or columns — so per-`message`
curated views are saved searches on the Events data view, not extra data views.

### Not yet covered

- No saved search for `hook_plugin_metrics` (plugin-specific, 20+ numeric fields —
  a dedicated view later) or `feedback_survey` (noise).
- **Dashboards (Lens)** are the next visualization layer: cost/token trends, model
  breakdown, tool frequency & success, latency distribution, session list. Mind
  the string-vs-numeric caveat above.
