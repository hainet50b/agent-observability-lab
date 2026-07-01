# claude-otelcol-elastic

> Claude Code → **local OpenTelemetry Collector** → APM Server (Elastic-native
> OTLP) → Elasticsearch → Kibana. Same backend and Kibana views as
> [`claude-elastic`](../claude-elastic/), but the agent talks to a
> same-host Collector instead of the APM Server directly.

```
Claude Code  ──OTLP──▶  otel-collector  ──OTLP──▶  APM Server  ──▶  Elasticsearch  ──▶  Kibana
(metrics + events + traces)  :4317/:4318           :8200            :9200                :5601
```

This stack inserts a **local OpenTelemetry Collector** between the agent and the
backend. The agent exports to `localhost:4318` — always reachable on the same host —
and the Collector relays the telemetry on to the APM Server. Everything downstream of
the Collector (APM Server, Elasticsearch, Kibana, saved objects, trace-isolation
pipelines) is the **same Elastic backend** as `claude-elastic`; only the
transport path differs. The Collector adds three behaviours:

| Behaviour | What it does | Caveat |
| --- | --- | --- |
| **Durable on-disk queue** | If APM Server is unreachable, exports are still accepted by the always-up local Collector and persisted to a named-volume `file_storage` queue, then drained when the link recovers — no loss during a backend outage; survives a Collector restart. | — |
| **Self-telemetry** | The Collector's own internal metrics (`otelcol_*`, esp. `otelcol_exporter_queue_size`) export under `service.name: otelcol-sidecar` — a silently-dead sidecar would be an audit hole. Travels a path separate from the data pipelines, so it does **not** ride the on-disk queue. Query `metrics-apm*` for `service.name: otelcol-sidecar`. | — |
| **Host identity** | A `resourcedetection` processor adds `host.name` (only where absent — never overwrites the agent's attributes), so every metric/event/span gains device attribution. Claude Code's native telemetry carries OS/arch but **no `host.name`**. | In a *container* the `system` detector reports the **container's** hostname — set deterministically to `otelcol-sidecar-demo` — **not** your laptop's. A real fleet runs the Collector as a host service (systemd/launchd), where the detector picks up the true machine name. Don't mistake the demo value for real attribution. |

**Organization asset ID (`host.id`).** Alongside the *detected* `host.name`, the
Collector **injects** an organization-assigned asset ID as a top-level `host.id` —
where `host.name` is the machine's *own* name (detected from the OS), `host.id` is the
*organization's* identity, the asset-management number used to join a document back to
an asset inventory. It is injected, not detected, fed from the Collector's environment:

```yaml
environment:
  - OTEL_RESOURCE_ATTRIBUTES=host.id=${AOL_ASSET_ID:-aol-demo-asset-0001}
```

Compose interpolates `AOL_ASSET_ID` from your shell at `up` time, falling back to the
demo default `aol-demo-asset-0001` — the lab analogue of an MDM writing the per-device
asset number into the Collector service at install time; the agent is untouched. Set
your own before bringing the stack up (recreate the Collector so the new env applies):

```sh
AOL_ASSET_ID=asset-12345 docker compose up -d
```

The key is **`host.id`** deliberately: it is an ECS/APM-modeled field, so it lands as a
**top-level, aggregatable `host.id`** (the join axis to the asset inventory) rather than
flattening into `labels.*` the way a custom key would. `resourcedetection` runs
`detectors: [env, system]`, and first-listed wins on conflict — so the injected
organizational `host.id` beats the `system` detector's *intrinsic* `host.id` (the
machine-id, **default-off** here). A fleet wanting the intrinsic machine identity would
enable that `system` `host.id`; with `[env, system]` the organizational ID wins
whenever both exist.

> ⚠️ **Cannot run alongside the other Elastic stacks.** Reuses the fixed `aol-*`
> container names and host ports (`9200` / `5601` / `8200`; the Collector adds
> `:4317` / `:4318`). `docker compose down` the other stack first.

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. The events/traces channels can capture your
> prompt text and tool I/O — don't run a telemetry-enabled session containing secrets
> or confidential material against this stack, and never commit captured telemetry into
> the repo.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl` and `jq` (used by the smoke test and the manual import path).
- Claude Code, to generate real telemetry.

## Quick Tour

The shortest path from clone to "I see Claude Code telemetry — sent through a local
Collector — in Kibana."

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/claude-otelcol-elastic
docker compose up -d
docker compose ps        # wait until elasticsearch, kibana, apm-server report healthy
# edit setup.conf if your endpoints aren't the localhost defaults, then:
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

The Collector (`otel-collector`) carries no healthcheck — its image is distroless — so
it shows no health column; it accepts OTLP within a second or two of starting. Kibana is
at <http://localhost:5601>. `scripts/setup.sh` runs every post-up bootstrap step in one
shot — loads the Elasticsearch assets (the APM `@custom` routers, the ingest pipelines
that isolate Claude Code spans into `traces-apm-agents_claude_code`, the per-agent
ILM/templates) and imports the Kibana saved objects (including the sidecar's own health
view) — and is idempotent, so re-run it any time. Both scripts read their target
endpoints (Elasticsearch, the Collector OTLP endpoint, Kibana) from `setup.conf` at the
stack root, or another file you pass (`setup.sh <config>` / `setup.ps1 -Config <config>`);
they fail fast if the file is missing or a key is empty rather than assuming localhost.

The demo Collector's OTLP receiver has auth disabled, so no credential is needed. For a
**secured** endpoint, copy `setup.local.conf.example` to the gitignored
`setup.local.conf` and set `telemetry.otel_collector.api_key=<key>` — `setup.sh` then
adds `Authorization: ApiKey <key>` to the agent's OTLP exports. Absent/empty ships no
credential.

Optionally prove the whole path with the smoke test ([Verify the pipeline](#verify-the-pipeline)):

```sh
scripts/smoke-test.sh
```

### 2. Point a Claude Code session at the Collector

**Simplest path:** step 1 already generated `.claude/settings.local.json` in this stack
directory with the telemetry `env` (pointed at the **Collector** on `:4318`) **and** the
prompt-audit hook — so just run **`claude` from `stacks/claude-otelcol-elastic/`**
and both telemetry and prompt auditing are on, no manual setup. (Project settings load
only from the launch directory.) A **one-shot** `claude -p "list files here"` works too
(telemetry + prompt audit). The options below are alternatives.

The telemetry vars configure **`claude`** itself, not the stack. The only difference from
`claude-elastic` is the endpoint: point `OTEL_EXPORTER_OTLP_ENDPOINT` at the
**Collector** on `:4318`, not the APM Server on `:8200`. Supply them one of three ways —
shell env (below; ephemeral, recommended), a `settings.json` `env` block, or
`managed-settings.json` (org enforcement) — exactly as in
[`claude-elastic`](../claude-elastic/#2-point-a-claude-code-session-at-the-stack).

```sh
# bash / zsh
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # ← the local Collector
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
# export OTEL_LOG_RAW_API_BODIES=file:<dir>   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
```

```fish
# fish
set -gx CLAUDE_CODE_ENABLE_TELEMETRY 1
set -gx OTEL_METRICS_EXPORTER otlp
set -gx OTEL_LOGS_EXPORTER otlp
set -gx OTEL_EXPORTER_OTLP_PROTOCOL http/protobuf
set -gx OTEL_EXPORTER_OTLP_ENDPOINT http://localhost:4318   # ← the local Collector
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
# set -gx OTEL_LOG_RAW_API_BODIES file:<dir>   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
```

```powershell
# PowerShell
$env:CLAUDE_CODE_ENABLE_TELEMETRY = "1"
$env:OTEL_METRICS_EXPORTER = "otlp"
$env:OTEL_LOGS_EXPORTER = "otlp"
$env:OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
$env:OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:4318"   # ← the local Collector
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
# $env:OTEL_LOG_RAW_API_BODIES = "file:<dir>"   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
```

The persistent (`settings.json` `env`) and org-enforced (`managed-settings.json`)
configurations, including the four `OTEL_LOG_*` content-exposure gates and the host-path
caveats, work the same as in `claude-elastic` — just with the `:4318` Collector
endpoint. The same staged `--with-hooks` opt-in (off by default, gated on a one-time host
check) also applies here for managed audit-hook enforcement. Remove the managed config
with `setup-config.sh --scope managed --teardown` (`-Teardown` on `.ps1`); add
`--with-hooks` / `-WithHooks` to also remove a materialized hook bundle. Then run `claude`
from a configured shell and do a little work; telemetry flushes on the export interval, so
data lands within ~10–30s (the Collector adds only a brief batching delay).

**Deploy this config into another scope.** `setup-config` deploys the same self-contained
bundle (pointing at this stack's **Collector**) to a `(target, scope)`; details in
[`../../SPEC/config-deployment.md`](../../SPEC/config-deployment.md).

| Scope | `--target` | MCP | Codex auth-link | Interactive | Teardown |
| --- | --- | --- | --- | --- | --- |
| `local` (default) | rejected (stack dir) | yes | n/a (Claude) | no | `--scope local --teardown` |
| `project` | required | no | n/a | no | `--scope project --target <dir> --teardown` |
| `managed` | n/a | no | n/a | yes | `--scope managed --teardown [--with-hooks]` |

```sh
scripts/setup-config.sh --scope project --target /path/to/your/project
# PowerShell: scripts/setup-config.ps1 -Scope project -Target C:\path\to\your\project
```

`project` scope writes a self-contained `.claude/` into that directory (nothing pointing
back into this repo), deploying the telemetry config **only** — it does **not** register
the Elasticsearch MCP, keeping the foreign project's footprint minimal (the MCP is a
`local`-scope convenience). **Caveat:** this flows that project's prompts and tool I/O
into the lab's Elasticsearch — don't point secret-bearing work at it.

### 3. Verify the pipeline

See [Verify the pipeline](#verify-the-pipeline) and [Durable queue](#durable-queue-backend-outage-resilience)
below. The Kibana saved objects are imported by step 1: the backend import, the agent
import, then the sidecar (path) import, each in dependency order (data views first). To
re-import after editing the NDJSON, re-run `scripts/setup.sh` (idempotent), or import from
the Kibana UI (Stack Management → Saved Objects → **Import**, data views first).

### 4. See the telemetry in Kibana

- **Discover** — pick the **Claude Code — Metrics** or **Events** data view, or open one of
  the saved searches from the **Open** menu.
- **APM UI** (<http://localhost:5601/app/apm>) — Claude Code registers as an APM **service**
  (`claude-code`). Telemetry routed through the Collector lands here exactly as the direct
  path does.

### 5. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe ingested telemetry
```

## Verify the pipeline

`scripts/smoke-test.sh` checks the full **Claude Code → Collector → APM Server →
Elasticsearch** path end to end, following the 3A pattern: **Arrange** brings the stack up,
waits for the backend services to report healthy, then waits for the Collector to accept
OTLP on `:4318`; **Act** POSTs a synthetic OTLP/protobuf metrics + logs + traces probe
(tagged `service.name = aol-smoke-test`) to the **Collector**, which forwards it to the APM
Server; **Assert** confirms the docs landed in the APM data streams in Elasticsearch —
proving the telemetry traversed the Collector. A synthetic probe is used (not a real
`claude` session) so the check is deterministic and runnable as a gate; real telemetry
travels the identical path under its own name.

```sh
scripts/smoke-test.sh    # from anywhere — it locates its own stack directory
```

Needs `docker` (running daemon), `curl`, `jq`, `base64`; it **SKIPs** (exit 0) when the
daemon is unreachable. Override endpoints with `ES_URL` / `OTEL_COLLECTOR_URL`.

### Durable queue (backend-outage resilience)

`scripts/resilience-test.sh` proves the on-disk queue end to end: it stops `apm-server` to
simulate the central backend going dark, POSTs a uniquely-tagged probe to the Collector
(which accepts and queues it), **restarts the Collector** (a pure in-memory queue would
lose the probe here — only the file_storage queue survives), then starts `apm-server` again
and asserts the probe drains into Elasticsearch. Same prerequisites and SKIP behaviour as the
smoke test.

```sh
scripts/resilience-test.sh    # from anywhere — it locates its own stack directory
```

## Data streams & assets

Same backend and agent assets as [`claude-elastic`](../claude-elastic/#data-streams--assets),
plus the sidecar's own:

| Asset | Where | Notes |
| --- | --- | --- |
| `metrics-apm.app.*` / `logs-apm.app.*` | per-service data streams | metrics + events under `service.name: claude-code` |
| `traces-apm-agents_claude_code` | per-agent trace data stream | spans isolated by the ingest pipelines |
| `metrics-apm*` | sidecar self-telemetry | `otelcol_*` under `service.name: otelcol-sidecar` |
| Data views | Metrics / Events / Traces + **OTel Collector Sidecar — Metrics** | imported by `setup.sh` |
| Saved searches | Event Overview, API Requests, Tool Results, …, Interactions, Traces | curated |
| Dashboard | **OTel Collector Sidecar — Health** | the sidecar's own health |
| APM service | `claude-code` | first-class entity in the APM UI |

## Layout

```
claude-otelcol-elastic/
├─ docker-compose.yml                     # thin composition: `include:`s the Elastic backend + otelcol-sidecar path
├─ setup.conf                             # endpoints setup.{sh,ps1} target: elasticsearch.url / kibana.url + telemetry.otel_collector.endpoint (Collector OTLP)
├─ setup.local.conf.example               # template for the gitignored setup.local.conf (optional telemetry.otel_collector.api_key)
└─ scripts/
   ├─ setup.sh / setup.ps1               # one-shot bootstrap = setup-backend then setup-config
   ├─ setup-backend.sh / .ps1            # wait for health, load ES + Kibana assets (3 sources: claude-code + otelcol-sidecar)
   ├─ setup-config.sh / .ps1             # deploy the agent config bundle (--scope local|project|managed)
   ├─ smoke-test.sh                       # end-to-end pipeline verification through the Collector (stack property)
   └─ resilience-test.sh                  # durable-queue / backend-outage check (stack property)
```

`setup.{sh,ps1}` composes the two halves (`setup-backend` then `setup-config`), each
calling the component façade scripts directly. The Collector service and its config live in
`../../components/paths/otelcol-sidecar/`. The `elastic` backend
(`../../components/backends/elastic/`) is a thin `include:` of the `elasticsearch` /
`kibana` / `apm-server` service fragments plus a composition script that selects its assets
— it owns no asset files. The service fragments under `../../components/backends/services/`
own the service definitions and config, the asset libraries (the `traces-apm@custom` /
`logs-apm.app@custom` ingest pipelines under `elasticsearch/`; the Claude Code saved-object
bundle under `kibana/claude/` and the sidecar's self-telemetry data view + dashboard
under `kibana/otelcol-sidecar/`), and the generic appliers that load them. The Claude Code
agent component (`../../components/agents/claude/`) owns only agent-runtime config —
the settings template + render scripts (the `.claude/settings.local.json` content), no
Kibana assets.
