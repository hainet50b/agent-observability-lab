# claude-code-elastic

> Claude Code → APM Server (Elastic-native OTLP) → Elasticsearch → Kibana.
> Bring it up, point a Claude Code session at it, and inspect the real
> **metrics** (sessions, tokens, cost, code edits, commits/PRs) and **events**
> (prompts, tool results, API requests) the agent emits.

```
Claude Code  ──OTLP/HTTP (+gRPC)──▶  APM Server  ──▶  Elasticsearch  ──▶  Kibana
(metrics + events)                   :8200            :9200                :5601
```

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. The events channel can capture your
> prompt text and tool I/O — do **not** run a telemetry-enabled session
> containing secrets or confidential material against this stack, and never
> commit captured telemetry into the repo.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl` and `jq` (used by the smoke test and the import one-liner below).
- Claude Code, to generate real telemetry in the Quick Tour.

## Quick Tour

The shortest path from clone to "I see Claude Code telemetry in Kibana."

### 1. Bring the stack up

```sh
cd stacks/claude-code-elastic
docker compose up -d
```

Wait until all three services are healthy (Elasticsearch and Kibana take a
minute on first boot):

```sh
docker compose ps
```

Kibana is then reachable at <http://localhost:5601>. Optionally prove the
OTLP → APM Server → Elasticsearch path end to end with the smoke test (it sends
a synthetic probe and asserts it lands — see [Verify the pipeline](#verify-the-pipeline-smoke-test)):

```sh
scripts/smoke-test.sh
```

### 2. Point a Claude Code session at the stack

The telemetry vars configure **`claude`** itself, not the stack — Claude Code
does **not** read `.env` files, so supply them one of three ways. They set
`CLAUDE_CODE_ENABLE_TELEMETRY=1` and the `OTEL_*` exporters for **both** metrics
and events at the APM Server OTLP endpoint on `:8200`, with short export
intervals so data appears quickly.

> ⚠️ The events channel can carry your prompt text and tool I/O. Don't enable
> telemetry on a session that handles secrets or confidential material against
> this local demo.

**Option A — shell env (one-off, recommended).** Paste this into the shell that
will run `claude`, then launch it from *any* directory against your own work.
It's **ephemeral and side-effect-free** — it creates no files, so you can fire a
single session's telemetry into the local demo from wherever you like.

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

**Option B — `settings.json` `env` block (persistent).** Put the same vars in a
Claude Code settings file's `env` so every session inherits them:

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

Project settings load **only from the directory `claude` is launched in** (they
are not inherited from parent directories), so a stack-local
`stacks/claude-code-elastic/.claude/settings.local.json` is self-contained —
telemetry on only when you launch `claude` from inside the stack. Put the same
block in `~/.claude/settings.json` to apply it everywhere. (A settings `env`
value overrides the shell env from Option A.)

**Option C — `managed-settings.json` (org enforcement).** Enterprise/MDM-distributed
[managed settings](https://code.claude.com/docs/en/monitoring-usage.md) have the
**highest precedence and cannot be overridden by users** — the way to force
telemetry on for all users across an organization.

Then run Claude Code from a configured shell/directory and do a little work — ask
a question, let it read or edit a file — so it emits a few sessions, prompts, and
API requests:

```sh
claude
```

Telemetry flushes on the export interval; give it ~10–30s after activity.

### 3. Import the Kibana saved objects

Two **data views** ship as importable saved objects in
[`kibana/claude-code-data-views.ndjson`](kibana/claude-code-data-views.ndjson):

| Data view | Index pattern | Shows |
| --- | --- | --- |
| **Claude Code — Metrics** | `metrics-apm.app*` | the numeric metric documents |
| **Claude Code — Events** | `logs-apm.app*` | the prompt / tool-result / API-request events |

Three **saved searches** ship in
[`kibana/claude-code-saved-searches.ndjson`](kibana/claude-code-saved-searches.ndjson).
A data view is only an index-pattern + time field — it cannot store a query or
column selection — so these per-`message` curated views are modeled as saved
searches (saved-object type `search`) layered on the **Claude Code — Events**
data view. Each one's `message` and `service.name: claude-code` constraints are
expressed as **filter pills** (labelled, removable blocks in Discover) with an
empty query bar, and ends in `labels.prompt_id` — the correlation key that
groups all events emitted within one prompt:

| Saved search | Filter pills | Curated columns |
| --- | --- | --- |
| **Claude Code — API Requests** | `message: claude_code.api_request`, `service.name: claude-code` | model, query_source, speed, effort, the `numeric_labels.*` cost / token / `duration_ms` fields, `prompt_id` |
| **Claude Code — Tool Results** | `message: claude_code.tool_result`, `service.name: claude-code` | tool_name, decision_type, decision_source, success, duration_ms, tool input / result size, `prompt_id` |
| **Claude Code — Tool Decisions** | `message: claude_code.tool_decision`, `service.name: claude-code` | tool_name, decision (accept/reject), source (config/user_temporary), `prompt_id` |

> **Note:** the `decision_type` / `decision_source` columns on **Tool Results**
> are populated only in **interactive** sessions; a headless/automated run (e.g.
> Ralph) leaves them blank. The permit decision is always recorded in the
> separate `claude_code.tool_decision` event — that is what the **Tool Decisions**
> saved search surfaces, and it is present in headless runs too. See the
> telemetry notes at the end of this README.

Both data views cover any agent telemetry that lands (real `claude-code` and the
smoke-test probe alike); the saved searches scope to real `claude-code`. The
saved searches **reference the Events data view**, so import the data views
first (or import both files together). Import either way:

- **Kibana UI** — Stack Management → Saved Objects → **Import** → choose the
  `.ndjson` file(s). Import `claude-code-data-views.ndjson` before (or alongside)
  `claude-code-saved-searches.ndjson`.
- **API one-liner** (from this directory) — data views first, then saved searches:

  ```sh
  for f in kibana/claude-code-data-views.ndjson kibana/claude-code-saved-searches.ndjson; do
    curl -s -X POST "http://localhost:5601/api/saved_objects/_import?overwrite=true" \
      -H "kbn-xsrf: true" --form file=@"$f" | jq .
  done
  ```

  On **fish** (the loop uses `for … end`, not `do … done`):

  ```fish
  for f in kibana/claude-code-data-views.ndjson kibana/claude-code-saved-searches.ndjson
      curl -s -X POST "http://localhost:5601/api/saved_objects/_import?overwrite=true" \
        -H "kbn-xsrf: true" --form file=@"$f" | jq .
  end
  ```

### 4. See the telemetry in Kibana

- **Discover** (<http://localhost:5601/app/discover>) — pick the **Claude Code —
  Metrics** or **Claude Code — Events** data view from the data-view selector.
  Filter to the agent with `service.name : claude-code` to exclude the smoke
  probe. String OTLP attributes surface under `labels.*` and numeric ones under
  `numeric_labels.*`; each metric's value is stored in a field named after the
  metric (e.g. `claude_code.token.usage`). The metric / event names and fields
  this lab has observed are catalogued in the telemetry notes at the end of this
  README — but Discover is the source of truth for the version you ran.
- **Saved searches** — in Discover, open the **Open** menu (top bar) and pick
  **Claude Code — API Requests**, **Claude Code — Tool Results**, or **Claude
  Code — Tool Decisions** for the curated, pre-filtered column layouts imported
  in step 3. Each opens with its `message` / `service.name` constraints shown as
  removable **filter pills** above the table (the query bar stays empty).
- **APM UI** (<http://localhost:5601/app/apm>) — Claude Code registers as an APM
  **service** (`claude-code`); open it to see it as a first-class APM entity.

### 5. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe ingested telemetry
```

## Verify the pipeline (smoke test)

`scripts/smoke-test.sh` checks the full **OTLP → APM Server → Elasticsearch** path
end to end, following the 3A pattern: **Arrange** brings the stack up and waits
for all three services to report healthy; **Act** POSTs one synthetic OTLP
metrics payload and one logs/event payload — shaped like Claude Code's two
channels and tagged `service.name = cce-smoke-test` — to the OTLP/HTTP endpoint;
**Assert** queries Elasticsearch and confirms they landed in the APM data
streams. It then prints the `service.name` values present, so real `claude-code`
telemetry shows up alongside the probe.

```sh
scripts/smoke-test.sh    # from anywhere — it locates its own stack directory
```

Prerequisites: `docker` (running daemon), `curl`, `jq`. If the Docker daemon is
not reachable it **SKIPs** (exit 0) — there is nothing to smoke-test without it.
Override endpoints with `ES_URL` / `APM_OTLP_URL` if you publish different ports.
A synthetic probe is used (rather than driving a real `claude` session) so the
check is self-contained and deterministic — no API key, no interactive session —
and can run as a gate; real telemetry travels the identical pipeline under its
own service name.

## Layout

```
claude-code-elastic/
├─ docker-compose.yml                  # Elasticsearch + Kibana + APM Server (Stack 9.4.2)
├─ config/apm-server.yml               # APM Server as the OTLP receiver
├─ kibana/claude-code-data-views.ndjson   # importable Discover data views (Quick Tour step 3)
├─ kibana/claude-code-saved-searches.ndjson# importable per-message saved searches (Quick Tour step 3)
└─ scripts/smoke-test.sh               # end-to-end pipeline verification (see "Verify the pipeline")
```

---

<!-- ========================================================================
     WORKING NOTES (DRAFT — to be cleaned up / folded into the sections above)

     Captured from a live session inspecting what actually landed in
     Elasticsearch (service.name = claude-code, Claude Code 2.1.159, Stack
     9.4.2). This is a scratch area: raw findings + design decisions, kept here
     so nothing is lost before it gets edited into proper docs / a PRD task.
     ===================================================================== -->

## Working notes (draft)

### Telemetry shape — how to read the data

- **Two data streams.** Metrics land in `metrics-apm.app.claude_code-default`,
  events/logs in `logs-apm.app.claude_code-default`. APM Server also auto-creates
  `metrics-apm.service_summary.1m-default` — an essentially empty "this service
  exists" marker, not useful for dashboards.
- **Metric value location:** stored in a field *named after the metric*, e.g.
  `claude_code.token.usage`. **Event type location:** the `message` field, e.g.
  `message: claude_code.api_request`.
- **Attributes:** string attrs → `labels.*`, numeric attrs → `numeric_labels.*`
  (OTLP key `.` becomes `_`). `session.id` is promoted to a top-level field.
- ⚠️ **Type inconsistency that bites aggregations:** `api_request` puts numbers
  in `numeric_labels` (true numbers), but `tool_result` / `hook_*` put
  `duration_ms`, `num_*`, `success` as **string** `labels`. Eyeballing in
  Discover is fine; `sum`/`avg` in Lens needs a runtime-field cast or sticking
  to `api_request`'s `numeric_labels`.
- ⚠️ **PII present:** `labels.user_email`, `labels.user_id`, and (if
  `OTEL_LOG_USER_PROMPTS=1`) `labels.prompt`. In this single-user demo the
  `user_*` / `organization_id` labels are constant — noise as columns, sensitive
  to bake into shared saved objects.

### Common envelope fields (all docs)

`@timestamp`, `service.name` (`claude-code`), `service.version` (`2.1.159`),
`service.framework.name` (`com.anthropic.claude_code`), `agent.name` (`otlp`),
`observer.*` (APM Server), `host.os.*` / `host.architecture`, `data_stream.*`.
Common `labels.*`: `session_id`, `user_email`, `user_id`, `user_account_id`,
`user_account_uuid`, `organization_id`, `terminal_type`.

### Metrics observed (this session)

| Metric field | Key labels | Notes |
| --- | --- | --- |
| `claude_code.session.count` | `start_type` (continue/startup) | session starts |
| `claude_code.token.usage` | `type` (input/output/cacheRead/cacheCreation), `model`, `effort`, `query_source` | finest-grained; cost driver |
| `claude_code.cost.usage` | `model`, `effort` | USD |
| `claude_code.active_time.total` | `type` (cli/user) | seconds |

Documented as possible signals but **NOT seen this session** (no such activity
occurred): `lines_of_code.count`, `commit.count`, `pull_request.count`,
`code_edit_tool.decision`. Dashboards should tolerate these arriving later.

### Events observed (this session) — discriminated by `message`

| `message` | Notable fields |
| --- | --- |
| `claude_code.user_prompt` | `labels.prompt_id`, `labels.prompt_length` (string), `labels.prompt` (`<REDACTED>` unless `OTEL_LOG_USER_PROMPTS=1`) |
| `claude_code.api_request` | `labels.model`, `request_id`, `query_source`, `speed`, `effort`; `numeric_labels.input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cost_usd`, `cost_usd_micros`, `duration_ms` |
| `claude_code.tool_decision` | `labels.tool_name`, `decision`, `source`, `tool_use_id` |
| `claude_code.tool_result` | `labels.tool_name`, `success` (string), `duration_ms` (string), `decision_type`, `decision_source`, `tool_use_id`, `tool_input_size_bytes`, `tool_result_size_bytes` |
| `claude_code.hook_execution_start` | `labels.hook_name`, `hook_event`, `hook_source`, `managed_only`, `num_hooks` |
| `claude_code.hook_execution_complete` | + `num_blocking`, `num_success`, `num_cancelled`, `num_non_blocking_error`, `total_duration_ms` |
| `claude_code.hook_plugin_metrics` | `labels.plugin_id`, `hook_event`, `skipped`; many `numeric_labels.*` review metrics (`cost_usd`, `vulns_found`, `files_reviewed`, `tok_*`, …) — plugin-specific (security-guidance) |
| `claude_code.subagent_completed` | `labels.agent_type`, `agent_source`, `model`, `is_async`, `is_built_in`; `numeric_labels.duration_ms`, `total_tokens`, `total_tool_uses` |
| `claude_code.feedback_survey` | `labels.survey_type`, `event_type`, `response`, `appearance_id` — UI survey, low signal |

Catalogued but **NOT seen this session**: `claude_code.api_error`; also `claude_code.hook_registered` (per the docs it carries the *granular* `hook_source` values — see below) has not landed here.

#### Field meanings worth recording

- **`query_source`** (api_request) — what triggered the API call. Observed:
  `repl_main_thread` (the real interactive turn), `away_summary` (background
  summarization while away), `prompt_suggestion`. Lets you separate "real" cost
  from background/auxiliary calls.
- **`decision_type` vs `decision_source`** (tool_result) — `decision_type` =
  *what* was decided (accept/reject), `decision_source` = *where* it came from
  (`config` = allowlisted, `user_temporary` = a one-off in-session approval).
  ⚠️ **Only present on `tool_result` in interactive sessions.** A headless /
  automated run (e.g. Ralph — identifiable by zero `user_prompt` events,
  `start_type: fresh`, and all decisions `source: config`) omits both — verified
  as an all-or-nothing split *by session*, same Claude Code version (2.1.159),
  not a per-tool or per-outcome effect. The decision is **not** lost: every
  `tool_result` has a matching `claude_code.tool_decision` event (1:1 by
  `tool_use_id`) carrying `decision` + `source`. So **`tool_decision` is the
  canonical, always-present source** for the permit decision; the `tool_result`
  copies are an interactive-only convenience and will be blank for automated runs.
- **`request_id` / `tool_use_id`** — opaque high-cardinality correlation IDs
  (request → API-side logs; `tool_use_id` joins `tool_decision` ⇄ `tool_result`).
  Useful as join keys, low value as scan columns.
- **Hooks** (`hook_execution_*`) — a *hook* is a shell command Claude Code runs
  automatically at a lifecycle event (`hook_event`: `UserPromptSubmit`,
  `PostToolUse`, `Stop`, …; `hook_name` adds the tool matcher, e.g.
  `PostToolUse:Edit`). Hooks come from settings or plugins; here the enabled
  `security-guidance` plugin supplies them. `hook_execution_complete` carries the
  outcome (`num_success` / `num_blocking` / `num_cancelled` /
  `num_non_blocking_error`, `total_duration_ms`).
- **`hook_source` / `managed_only`** — on the *execution* events `hook_source`
  collapses to just two values: `merged` (normal) or `policySettings`
  (managed-only mode), and that is 1:1 with `managed_only` (`true` ⇄
  `policySettings`). The granular origins
  (`userSettings`/`projectSettings`/`localSettings`/`flagSettings`/`pluginHook`/`policySettings`)
  appear only on the `hook_registered` event, which we don't capture. ⇒ Neither
  is worth a column on a Hook Executions saved search (low cardinality +
  mutually redundant); to see the source breakdown you'd ingest `hook_registered`.
  ([monitoring-usage docs](https://code.claude.com/docs/en/monitoring-usage.md))
- **Subagent** (`subagent_completed`) — `agent_type` (which subagent, e.g.
  `claude-code-guide`), `agent_source` (`built-in` / project / user / plugin) and
  `is_built_in` (the boolean form of the same fact — redundant; prefer
  `agent_source`), `is_async` (ran in background vs blocking), `model`; the
  `numeric_labels` `duration_ms` / `total_tokens` / `total_tool_uses` are true
  numbers (aggregatable). Directly on-mission for an agent-observability lab.

### Data View vs Saved Search — decision

- **Keep exactly the 2 data views** (Metrics + Events). A Kibana data view is
  just an index-pattern + time field — it canNOT store a query or column
  selection, so a "filtered-by-message view" is *not* a data view.
- The thing we actually want ("filter by `message`, show curated columns") is a
  **Saved Search** (`search` saved object): it holds data-view ref + query +
  filters + columns + sort, exports as NDJSON, opens from Discover. Build these
  on top of the existing **Events** data view (`cce-claude-code-events`); do NOT
  spawn a data view per message type (that would be the overkill).

### Saved Searches (shipped — `kibana/claude-code-saved-searches.ndjson`)

Three are now shipped as importable NDJSON (Quick Tour step 3). All reference
data view `cce-claude-code-events`, sort `@timestamp` desc, and constrain on
`message` AND defensively `service.name: claude-code`. Those constraints are
expressed as **filter pills** — `phrase` entries in `searchSourceJSON.filter[]`,
each pointing at the data view through a `references[]` entry
(`kibanaSavedObjectMeta.searchSourceJSON.filter[N].meta.index`) — with an empty
query bar, so Discover shows labelled, removable blocks rather than raw KQL. Each
ends in `labels.prompt_id`, the per-prompt correlation key. The column choices
below were made against live data — recorded here as the rationale.

**Claude Code — API Requests** — pill `message: claude_code.api_request`
```
labels.model
labels.query_source
labels.speed
labels.effort
numeric_labels.duration_ms
numeric_labels.cost_usd
numeric_labels.input_tokens
numeric_labels.output_tokens
numeric_labels.cache_read_tokens
numeric_labels.cache_creation_tokens
labels.prompt_id
```
Excluded on purpose: `request_id` (opaque, available on row-expand), `user_*` /
`message` / `service.name` (constant in this view = noise).

**Claude Code — Tool Results** — pill `message: claude_code.tool_result`
```
labels.tool_name
labels.decision_type
labels.decision_source
labels.success
labels.duration_ms
labels.tool_input_size_bytes
labels.tool_result_size_bytes
labels.prompt_id
```
Excluded on purpose: `tool_use_id` (same reasoning as `request_id`).

**Claude Code — Tool Decisions** — pill `message: claude_code.tool_decision`
```
labels.tool_name
labels.decision
labels.source
labels.prompt_id
```
The canonical, always-present permit decision (`decision` = accept/reject,
`source` = config/user_temporary), unlike `tool_result`'s interactive-only
`decision_*`. Excluded on purpose: `tool_use_id` (the `tool_decision` ⇄
`tool_result` join key — opaque, available on row-expand).

### Still open / later

- Saved searches spec'd next (PRD): **User Prompts**, **Hook Executions**
  (complete only), **Subagent Completions** (api_request, tool_result,
  tool_decision already shipped). Deferred: `hook_plugin_metrics`
  (plugin-specific, 20+ numeric fields — better as a dedicated view later) and
  `feedback_survey` (noise).
- Dashboards (Lens): cost/token trends, model breakdown, tool frequency & success,
  API latency distribution, session list. Mind the string-vs-numeric caveat above.
- The smoke-test's expected-indices/fields catalogue was removed from
  `scripts/README.md` and folded into these notes + `SPEC/SPEC.md` ("Shape in
  Elasticsearch"); this README is now the field reference.
