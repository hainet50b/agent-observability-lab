# claude-code-otelcol-elastic

> Claude Code → **local OpenTelemetry Collector** → APM Server (Elastic-native
> OTLP) → Elasticsearch → Kibana. Same backend and Kibana views as
> `claude-code-elastic`, but the agent talks to a same-host Collector instead of
> the APM Server directly.

```
Claude Code  ──OTLP──▶  otel-collector  ──OTLP──▶  APM Server  ──▶  Elasticsearch  ──▶  Kibana
(metrics + events + traces)  :4317/:4318           :8200            :9200                :5601
```

This stack inserts a **local OpenTelemetry Collector** between the agent and the
backend. The agent exports to `localhost:4318` — always reachable on the same
host — and the Collector relays the telemetry on to the APM Server. Everything
downstream of the Collector (APM Server, Elasticsearch, Kibana, the Kibana saved
objects, the trace-routing pipeline) is the **same Elastic backend** as
`claude-code-elastic`; only the transport path differs.

The Collector buffers telemetry to a **durable on-disk queue**: if the central
backend (APM Server) is unreachable, the agent's exports are still accepted by
the always-up local Collector and persisted to disk, then drained automatically
when the link recovers — no loss during a backend outage. The queue is a named
Docker volume, so it survives a Collector restart too.

The Collector also reports its **own** health. A silently-dead sidecar would be
an audit hole, so its internal metrics (`otelcol_*` — most usefully
`otelcol_exporter_queue_size`, which grows when the central link is failing)
are exported to the same backend under the `service.name` **`otelcol-sidecar`**,
distinct from `claude-code`. This self-telemetry travels a path separate from the
data pipelines, so it does **not** ride the on-disk queue above — query
`metrics-apm*` for `service.name: otelcol-sidecar` to see it.

The Collector also **stamps host identity** onto every signal it relays. Claude
Code's native telemetry carries OS/architecture resource attributes but **no
`host.name`** — a document can be attributed to a person (`labels.user_email`)
and a session (`session.id`) but not to a *device*. A `resourcedetection`
processor adds `host.name` (only where absent — it never overwrites the agent's
own attributes), so every metric, event, and span gains device attribution. The
local Collector is the natural place to do this: it sees every signal on the way
out, and host identity is a property of where the agent runs, not of the agent.

> ⚠️ **Container caveat — the demo `host.name` is the Collector's, not your
> laptop's.** Because the Collector runs in a *container*, its `system` hostname
> detector reports the **container's** hostname — set deterministically to
> `otelcol-sidecar-demo` on the service — **not** the host machine's. This
> dockerized stack demonstrates the *mechanism*; a real fleet runs the Collector
> as a host service (systemd / launchd), where the same detector picks up the
> true machine name. Don't mistake the demo value for real device attribution.

Alongside the *detected* `host.name`, the Collector also **injects an
organization-assigned asset ID** as a top-level `host.id`. Where `host.name` is
the machine's *own* name (detected from the OS), `host.id` is the
*organization's* identity — the asset-management number used to join a document
back to an asset inventory. That is injected, not detected, so it is fed from the
Collector's environment in `docker-compose.yml`:

```yaml
environment:
  - OTEL_RESOURCE_ATTRIBUTES=host.id=${AOL_ASSET_ID:-aol-demo-asset-0001}
```

Compose interpolates `AOL_ASSET_ID` from your shell at `up` time, falling back to
the demo default `aol-demo-asset-0001` — the lab analogue of an MDM writing the
per-device asset number into the Collector service definition at install time;
the agent is untouched. Set your own before bringing the stack up (recreate the
Collector so the new env applies):

```sh
AOL_ASSET_ID=asset-12345 docker compose up -d
```

The attribute key is **`host.id`** deliberately: it is an ECS/APM-modeled field,
so it lands as a **top-level, aggregatable `host.id`** (the join axis to the asset
inventory) rather than flattening into `labels.*` the way a custom attribute key
would. The Collector's `resourcedetection` runs `detectors: [env, system]`, and
first-listed wins on conflict — so the injected organizational `host.id` beats the
`system` detector's *intrinsic* `host.id` (the machine-id, which is **default-off**
here). A real fleet that wanted the intrinsic machine identity instead would
enable that `system` `host.id`; with `[env, system]`, the organizational ID wins
whenever both exist.

> ⚠️ **Cannot run alongside `claude-code-elastic`.** This stack reuses the Elastic
> backend's fixed `aol-*` container names and host ports (`9200` / `5601` /
> `8200`). Run only one of the two at a time — `docker compose down` the other
> stack first. (The Collector adds `:4317` / `:4318`.)

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. The events/traces channels can capture
> your prompt text and tool I/O — don't run a telemetry-enabled session containing
> secrets or confidential material against this stack, and never commit captured
> telemetry into the repo.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl` and `jq` (used by the smoke test and the manual import path).
- Claude Code, to generate real telemetry.

## Quick Tour

The shortest path from clone to "I see Claude Code telemetry — sent through a
local Collector — in Kibana."

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/claude-code-otelcol-elastic
docker compose up -d
docker compose ps        # wait until elasticsearch, kibana, apm-server report healthy
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

The Collector (`otel-collector`) carries no healthcheck — its image is
distroless — so it shows no health column; it accepts OTLP within a second or two
of starting. Kibana is at <http://localhost:5601>. `scripts/setup.sh` runs every
post-up bootstrap step in one shot — it installs the trace-routing ingest
pipeline (isolates Claude Code's spans into `traces-apm-agents_claude_code`),
creates the `prompts-audit` index, and imports the Kibana saved objects — and is
idempotent, so re-run it any time. Override endpoints with `ES_URL` / `KIBANA_URL`
(or `-EsUrl` / `-KibanaUrl` for the `.ps1`).

Optionally prove the whole path end to end with the smoke test (see
[Verify the pipeline](#verify-the-pipeline)):

```sh
scripts/smoke-test.sh
```

### 2. Point a Claude Code session at the Collector

**Simplest path:** `scripts/setup.sh` (step 1) already generated
`.claude/settings.local.json` in this stack directory with the telemetry `env`
(pointed at the **Collector** on `:4318`) **and** the prompt-audit hook — so just
run **`claude` from `stacks/claude-code-otelcol-elastic/`** and both telemetry
and prompt auditing are on, no manual setup. (Project settings load only from the
launch directory.) The options below are alternatives.

The telemetry vars configure **`claude`** itself, not the stack. The only
difference from `claude-code-elastic` is the endpoint: point
`OTEL_EXPORTER_OTLP_ENDPOINT` at the **Collector** on `:4318`, not the APM Server
on `:8200`. Paste into the shell that runs `claude`, then launch it from *any*
directory (ephemeral and side-effect-free — creates no files).

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
# export OTEL_LOG_RAW_API_BODIES=file:<repo>/var/api-bodies   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
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
# set -gx OTEL_LOG_RAW_API_BODIES file:<repo>/var/api-bodies   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
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
# $env:OTEL_LOG_RAW_API_BODIES = "file:<repo>/var/api-bodies"   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
```

Persistent (`settings.json` `env` block) and org-enforced (`managed-settings.json`)
configurations work the same way as in `claude-code-elastic` — just with the
`:4318` Collector endpoint. Then run `claude` from a configured shell and do a
little work; telemetry flushes on the export interval, so data lands within
~10–30s (the Collector adds only a brief batching delay).

### 3. Import the Kibana saved objects

The backend and agent saved objects are the same as `claude-code-elastic` (this
stack reuses both components unchanged); this stack adds **one** more — a data
view for the sidecar's own metrics. These are **imported by `scripts/setup.sh`**
(Quick Tour step 1), which runs the backend import, the agent import, then the
sidecar (path) import, each in dependency order (data views first). To re-import
after editing the NDJSON, just re-run `scripts/setup.sh` (idempotent). You can
also import from the Kibana UI (Stack Management → Saved Objects → **Import**,
data views first).

This brings in the **Metrics**, **Events**, **Traces**, **AI Agents — Traces**,
and **OTel Collector Sidecar — Metrics** data views, the curated **saved
searches** (Event Overview, API Requests, Tool Results, …, Interactions, Traces),
and the **Claude Code — Overview** dashboard.

### 4. See the telemetry in Kibana

- **Discover** — pick the **Claude Code — Metrics** or **Events** data view, or
  open one of the saved searches from the **Open** menu.
- **APM UI** (<http://localhost:5601/app/apm>) — Claude Code registers as an APM
  **service** (`claude-code`). Telemetry routed through the Collector lands here
  exactly as the direct path does.

### 5. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe ingested telemetry
```

## Prompt audit trail (independent of OTLP)

A separate, opt-in capability that answers **"when / who / what prompt"** for
compliance — on a path **completely independent of the OTLP analytics pipeline**
above. A Claude Code `UserPromptSubmit` hook captures each prompt **at the
source** (full text, before any `OTEL_LOG_USER_PROMPTS` redaction/truncation)
and POSTs one document straight to a dedicated Elasticsearch index,
`prompts-audit`. Note this path does **not** go through the Collector — the
sidecar relays OTLP only; the audit hook talks directly to Elasticsearch
(`:9200`), so the analytics relay (and its durable queue) is untouched. As a
plain agent hook it carries zero extra infrastructure and can be pushed to a
fleet via [managed settings](https://code.claude.com/docs/en/monitoring-usage.md).

> ⚠️ **Plaintext phase.** Prompts are stored as-is for now; local public-key
> sealing (`prompt` → `prompt_cipher`, openable only with the central
> investigator key) is a later phase. Until then, treat the store as sensitive
> and don't audit real-secret sessions against a shared backend.

**1. The store** is created by `scripts/setup.sh` (Quick Tour step 1) — the
`prompts-audit` index, with a `dynamic: strict` mapping: a searchable keyword
**envelope** (`agent`, `user_email`, `organization`, `session_id`, `hostname`),
the `prompt` text, and a reserved `prompt_cipher` field for the sealing phase.
`cwd` is deliberately **not** stored — a working-directory path is PII (it leaks
project / client / user names). `session_id` equals the OTLP `session.id`, so an
audit document **joins back** to that session's analytics telemetry.

**2. The capture hook is already registered** by `scripts/setup.sh` (step 1) —
it writes the `hooks` block into the generated `.claude/settings.local.json`
alongside the telemetry `env`, so launching `claude` from this stack directory
audits prompts automatically. To register it **manually elsewhere** (e.g. in
`~/.claude/settings.json` for all your projects, or `managed-settings.json` for
org-wide enforcement), add a `hooks` block pointing at the capture script
`components/agents/claude-code/hooks/capture-prompt.sh` (PowerShell mirror:
`capture-prompt.ps1`) by its absolute path:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/abs/path/to/components/agents/claude-code/hooks/capture-prompt.sh",
            "timeout": 6
          }
        ]
      }
    ]
  }
}
```

On Windows, point the command at PowerShell instead:
`powershell -NoProfile -ExecutionPolicy Bypass -File C:\abs\path\...\hooks\capture-prompt.ps1`
(`powershell` is the stock Windows PowerShell 5.1, present on every machine;
`pwsh`/PowerShell 7 also works). Put the block in `~/.claude/settings.json` (all
your projects), a launch-dir `.claude/settings.local.json` (just here), or
`managed-settings.json` (org-wide enforcement). The hook needs **nothing
installed** beyond what ships with the OS — the `.sh` uses only `curl` + `awk`
(POSIX base; no `jq`), the `.ps1` only built-in PowerShell — so it runs unchanged
across a fleet. It is **best-effort and side-effect-only**: writes nothing to
stdout (so it never injects into the prompt), always exits 0, and fails fast
(`--max-time 5`), so if Elasticsearch is unreachable your prompt proceeds
unaudited rather than blocked. Identity is resolved locally from `~/.claude.json`
(`.oauthAccount`); override the endpoint with `PROMPTS_AUDIT_ES_URL` (default
`http://localhost:9200`).

**3. Submit a prompt, then look at the store** (no Kibana asset yet — a data
view / saved search is a later increment):

```sh
curl -s 'http://localhost:9200/prompts-audit/_search?pretty' \
  -H 'Content-Type: application/json' -d '{"sort":[{"@timestamp":"desc"}]}'
```

## Verify the pipeline

`scripts/smoke-test.sh` checks the full **Claude Code → Collector → APM Server →
Elasticsearch** path end to end, following the 3A pattern: **Arrange** brings the
stack up, waits for the backend services to report healthy, then waits for the
Collector to accept OTLP on `:4318`; **Act** POSTs a synthetic OTLP/protobuf
metrics + logs + traces probe (tagged `service.name = aol-smoke-test`) to the
**Collector**, which forwards it to the APM Server; **Assert** confirms the docs
landed in the APM data streams in Elasticsearch — proving the telemetry traversed
the Collector. A synthetic probe is used (not a real `claude` session) so the
check is deterministic and runnable as a gate; real telemetry travels the
identical path under its own name.

```sh
scripts/smoke-test.sh    # from anywhere — it locates its own stack directory
```

Needs `docker` (running daemon), `curl`, `jq`, `base64`; it **SKIPs** (exit 0)
when the daemon is unreachable. Override endpoints with `ES_URL` /
`OTEL_COLLECTOR_URL`.

### Durable queue (backend-outage resilience)

`scripts/resilience-test.sh` proves the on-disk queue end to end: it stops
`apm-server` to simulate the central backend going dark, POSTs a uniquely-tagged
probe to the Collector (which accepts and queues it), **restarts the Collector**
(a pure in-memory queue would lose the probe here — only the file_storage queue
survives), then starts `apm-server` again and asserts the probe drains into
Elasticsearch. Same prerequisites and SKIP behaviour as the smoke test.

```sh
scripts/resilience-test.sh    # from anywhere — it locates its own stack directory
```

## Layout

```
claude-code-otelcol-elastic/
├─ docker-compose.yml                     # thin composition: `include:`s the Elastic backend + otelcol-sidecar path
└─ scripts/
   ├─ setup.sh                            # one-shot bootstrap: trace-routing + prompts-audit + Kibana import (3 components)
   ├─ setup.ps1                           # PowerShell mirror of setup.sh
   ├─ smoke-test.sh                       # end-to-end pipeline verification through the Collector (stack property)
   └─ resilience-test.sh                  # durable-queue / backend-outage check (stack property)
```

`setup.{sh,ps1}` calls the component bootstrap scripts directly. The Collector
service, its config, and its self-telemetry data view — with their own import
script — live in `../../components/paths/otelcol-sidecar/`. The backend services,
their config, the cross-agent data view, the `traces-apm@custom` pipeline body,
the `prompts-audit` index mapping, and the Backend bootstrap scripts live in
`../../components/backends/elastic/`; the Claude Code agent's data views, saved
searches, Overview dashboard — with their own import script — and the
prompt-capture **hooks**, and the **settings template + render scripts** (the
`.claude/settings.local.json` content) live in `../../components/agents/claude-code/`.
