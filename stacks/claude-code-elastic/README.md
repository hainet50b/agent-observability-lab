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

Copy the telemetry env template and load it into the shell that will run
`claude` (it sets `CLAUDE_CODE_ENABLE_TELEMETRY=1` and the `OTEL_*` exporters
for **both** metrics and events at the APM Server OTLP endpoint on `:8200`,
with short export intervals so data appears quickly):

```sh
cp .env.example .env
set -a && . ./.env && set +a   # bash/zsh: export every OTEL_* var into the shell
```

On **fish**, load it with (splits each non-comment line on the first `=` and exports it):

```fish
for line in (string match -rv '^\s*(#|$)' < .env); set -gx (string split -m1 '=' $line); end
```

Then run Claude Code from that same shell and do a little work — ask a question,
let it read or edit a file — so it emits a few sessions, prompts, and API
requests:

```sh
claude
```

Telemetry flushes on the export interval; give it ~10–30s after activity.

### 3. Import the Kibana data views

Two data views ship as importable saved objects in
[`kibana/claude-code-data-views.ndjson`](kibana/claude-code-data-views.ndjson):

| Data view | Index pattern | Shows |
| --- | --- | --- |
| **Claude Code — Metrics** | `metrics-apm.app*` | the numeric metric documents |
| **Claude Code — Events** | `logs-apm.app*` | the prompt / tool-result / API-request events |

Both cover any agent telemetry that lands (real `claude-code` and the smoke-test
probe alike). Import them either way:

- **Kibana UI** — Stack Management → Saved Objects → **Import** → choose the
  `.ndjson` file.
- **API one-liner** (from this directory):

  ```sh
  curl -s -X POST "http://localhost:5601/api/saved_objects/_import?overwrite=true" \
    -H "kbn-xsrf: true" \
    --form file=@kibana/claude-code-data-views.ndjson | jq .
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
├─ .env.example                        # Claude Code telemetry env (CLAUDE_CODE_ENABLE_TELEMETRY, OTEL_*)
├─ kibana/claude-code-data-views.ndjson# importable Discover data views (this Quick Tour, step 3)
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
| `claude_code.hook_plugin_metrics` | `labels.plugin_id`; `numeric_labels.pv`, `sdk_bootstrap`, `sdk_bootstrap_ms` |

Catalogued but **NOT seen this session**: `claude_code.api_error`.

#### Field meanings worth recording

- **`query_source`** (api_request) — what triggered the API call. Observed:
  `repl_main_thread` (the real interactive turn), `away_summary` (background
  summarization while away), `prompt_suggestion`. Lets you separate "real" cost
  from background/auxiliary calls.
- **`decision_type` vs `decision_source`** (tool_result) — `decision_type` =
  *what* was decided (accept/reject; all `accept` this session), `decision_source`
  = *where* it came from (observed `config` = allowlisted, `user_temporary` = a
  one-off in-session approval). Keep both: type is the first thing you want when a
  rejection happens; source shows how automated the permissioning is.
- **`request_id` / `tool_use_id`** — opaque high-cardinality correlation IDs
  (request → API-side logs; `tool_use_id` joins `tool_decision` ⇄ `tool_result`).
  Useful as join keys, low value as scan columns.

### Data View vs Saved Search — decision

- **Keep exactly the 2 data views** (Metrics + Events). A Kibana data view is
  just an index-pattern + time field — it canNOT store a query or column
  selection, so a "filtered-by-message view" is *not* a data view.
- The thing we actually want ("filter by `message`, show curated columns") is a
  **Saved Search** (`search` saved object): it holds data-view ref + query +
  filters + columns + sort, exports as NDJSON, opens from Discover. Build these
  on top of the existing **Events** data view (`cce-claude-code-events`); do NOT
  spawn a data view per message type (that would be the overkill).

### Finalized Saved Searches (scope: option B — start with these 2)

Both reference data view `cce-claude-code-events`, sort `@timestamp` desc, and
filter on `message` AND defensively `service.name: claude-code`.

**Claude Code — API Requests** — filter `message: claude_code.api_request`
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
```
Excluded on purpose: `request_id` (opaque, available on row-expand), `user_*` /
`message` / `service.name` (constant in this view = noise).

**Claude Code — Tool Results** — filter `message: claude_code.tool_result`
```
labels.tool_name
labels.decision_type
labels.decision_source
labels.success
labels.duration_ms
labels.tool_input_size_bytes
labels.tool_result_size_bytes
```
Excluded on purpose: `tool_use_id` (same reasoning as `request_id`).

### Still open / later

- Remaining event types (tool_decision, user_prompt, hook_*) — more saved
  searches later if useful.
- Dashboards (Lens): cost/token trends, model breakdown, tool frequency & success,
  API latency distribution, session list. Mind the string-vs-numeric caveat above.
- The smoke-test's expected-indices/fields catalogue was removed from
  `scripts/README.md` and folded into these notes + `SPEC/SPEC.md` ("Shape in
  Elasticsearch"); this README is now the field reference.
