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
a synthetic probe and asserts it lands — see [`scripts/README.md`](scripts/README.md)):

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
set -a && . ./.env && set +a   # bash/zsh; loads the OTEL_* vars into the env
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
  metric (e.g. `claude_code.token.usage`). The metric/event names this lab
  expects are catalogued in [`scripts/README.md`](scripts/README.md) — but
  Discover is the source of truth for the version you ran.
- **APM UI** (<http://localhost:5601/app/apm>) — Claude Code registers as an APM
  **service** (`claude-code`); open it to see it as a first-class APM entity.

### 5. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe ingested telemetry
```

## Layout

```
claude-code-elastic/
├─ docker-compose.yml                  # Elasticsearch + Kibana + APM Server (Stack 9.4.2)
├─ config/apm-server.yml               # APM Server as the OTLP receiver
├─ .env.example                        # Claude Code telemetry env (CLAUDE_CODE_ENABLE_TELEMETRY, OTEL_*)
├─ kibana/claude-code-data-views.ndjson# importable Discover data views (this Quick Tour, step 3)
└─ scripts/smoke-test.sh               # end-to-end pipeline verification (+ scripts/README.md)
```
