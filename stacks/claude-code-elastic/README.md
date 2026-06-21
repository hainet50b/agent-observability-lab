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

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/claude-code-elastic
docker compose up -d
docker compose ps        # wait until all three services report healthy
# edit setup.conf if your endpoints aren't the localhost defaults, then:
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

Kibana is then at <http://localhost:5601>. `scripts/setup.sh` runs every post-up
bootstrap step in one shot — it installs the trace-routing ingest pipeline
(isolates Claude Code's spans into `traces-apm-agents_claude_code`) and imports the Kibana saved objects — and is idempotent,
so re-run it any time (e.g. after editing saved objects). Both scripts read their
target endpoints — Elasticsearch, the APM OTLP endpoint, and Kibana — from
`setup.conf` at the stack root, or another file you pass (`setup.sh <config>` /
`setup.ps1 -Config <config>`); they fail fast if the file is missing or a key is
empty rather than assuming localhost.

The demo APM Server has auth disabled, so no OTLP credential is needed. To point a
session at a **secured** endpoint, copy `setup.local.conf.example` to the gitignored
`setup.local.conf` and set `telemetry.apm_server.api_key=<key>` — `setup.sh` then adds
`Authorization: ApiKey <key>` to the agent's OTLP exports. Leaving it empty (or
skipping the file) ships no credential.

Optionally prove the pipeline end to end with the smoke test (see
[Verify the pipeline](#verify-the-pipeline)):

```sh
scripts/smoke-test.sh
```

### 2. Point a Claude Code session at the stack

**Simplest path:** `scripts/setup.sh` (step 1) already generated
`.claude/settings.local.json` in this stack directory with the telemetry `env`
block (pointed at this stack's OTLP endpoint) **and** the prompt-audit hook — so
just run **`claude` from `stacks/claude-code-elastic/`** and both telemetry and
prompt auditing are on, with no manual export or hook registration. (Project
settings load only from the launch directory, so launch `claude` here.) The
options below are alternatives — for pointing a session you launch *elsewhere*,
or enabling telemetry globally / org-wide.

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
# export OTEL_LOG_RAW_API_BODIES=file:<dir>   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
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
# set -gx OTEL_LOG_RAW_API_BODIES file:<dir>   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
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
# $env:OTEL_LOG_RAW_API_BODIES = "file:<dir>"   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
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
keep real secrets out of any session while a gate is on. The commented-out
`file:` variant writes **untruncated** request/response bodies to that
directory you point it at (gitignore it) and
the `api_*_body` events carry `labels.body_ref` pointers instead of inline
fragments — see the `OTEL_LOG_RAW_API_BODIES` section of
`SPEC/claude-code-telemetry.md`.

Project settings load **only from the directory `claude` is launched in** (not
inherited from parents), so a stack-local `.claude/settings.local.json` keeps
telemetry on only when you launch from inside the stack; `~/.claude/settings.json`
applies everywhere.

**Option C — `managed-settings.json` (org enforcement).** Enterprise/MDM-distributed
[managed settings](https://code.claude.com/docs/en/monitoring-usage.md) have the
**highest precedence and cannot be overridden by users** — the way to force
telemetry on across an organization. The `env` block placed here is **enforced**:
users cannot turn telemetry off, change the endpoint, or flip the `OTEL_LOG_*`
gates.

This stack can place that single machine-global file for you — **opt-in,
always interactive, and never destructive**. It lives at a fixed admin-owned
path (`/etc/claude-code/managed-settings.json` on Linux/WSL,
`/Library/Application Support/ClaudeCode/managed-settings.json` on macOS,
`C:\Program Files\ClaudeCode\managed-settings.json` on Windows) — the same file
your real employer may already use, so placement **refuses to overwrite any file
the lab did not place** (tracked by a sidecar `.managed` marker) and prompts
before writing. There is **no `--yes`**; a non-interactive shell aborts having
changed nothing, and permission errors fail loud with the privileged command to
run by hand.

Place it via `setup.sh --scope managed` (runs after the normal setup steps) or
directly:

```sh
../../components/agents/claude-code/scripts/setup-managed.sh \
  --logs-endpoint http://localhost:8200/v1/logs \
  --traces-endpoint http://localhost:8200/v1/traces \
  --metrics-endpoint http://localhost:8200/v1/metrics
```

```powershell
..\..\components\agents\claude-code\scripts\setup-managed.ps1 `
  -LogsEndpoint http://localhost:8200/v1/logs `
  -TracesEndpoint http://localhost:8200/v1/traces `
  -MetricsEndpoint http://localhost:8200/v1/metrics
```

**Staged opt-in — also enforce the audit hooks (`--with-hooks`).** Off by default
(managed enforces telemetry only — "config-only"). Adding `--with-hooks --es-url <es>`
(sh) / `-WithHooks -EsUrl <es>` (ps1) **materializes** the audit-hook bundle (entry +
shared core + adapter, both shells, plus a rendered `agent-audit.conf`) into a
`hooks/` dir **beside** `managed-settings.json` and adds a `hooks` block pointing at
it — so the enforced hooks are self-contained on the host, never referencing this
repo.

> **Host-check gate — do this once before relying on `--with-hooks`.** Claude Code has
> no managed hooks-directory convention, so the lab picks `hooks/` beside
> `managed-settings.json`. Confirm on a **real host** that an absolute hook `command`
> path actually fires (mind the macOS space in `Application Support` and the Windows
> `ProgramData`/`Program Files` paths) and record the result. Until you have confirmed
> it, leave `--with-hooks` off and keep managed config-only.

Remove it (restores the host, removes only the lab-placed file + its marker; add
`--with-hooks` / `-WithHooks` to also remove a materialized hook bundle) — either
`setup-config.sh --scope managed --teardown [--with-hooks]` (the `-Teardown` /
`-WithHooks` switches on `.ps1`) or directly:

```sh
../../components/agents/claude-code/scripts/teardown-managed.sh
```

```powershell
..\..\components\agents\claude-code\scripts\teardown-managed.ps1
```

Then run `claude` from a configured shell/directory and do a little work (ask a
question, let it read or edit a file). Telemetry flushes on the export interval,
so data lands within ~10–30s.

#### Deploy this config into your own project (`--target`)

The bundle generated above is self-contained, so you can deploy the same telemetry
config into **any** directory — e.g. a real project — to see what your everyday work
emits against this lab's backend:

```sh
scripts/setup-config.sh --scope project --target /path/to/your/project
# PowerShell: scripts/setup-config.ps1 -Scope project -Target C:\path\to\your\project
```

It writes a self-contained `.claude/` into that directory, with nothing pointing back
into this repo. `project` scope deploys the telemetry config only and does **not**
register the Elasticsearch MCP, keeping the foreign project's footprint minimal (the
MCP is a `local`-scope convenience). **Caveat:** this flows that project's prompts and
tool I/O into the lab's Elasticsearch — don't point secret-bearing work at it.

### 3. Import the Kibana saved objects

Already done by `scripts/setup.sh` (step 1): it imports the Claude Code data
views and curated saved searches from
`../../components/backends/services/kibana/claude-code/`. Re-run `scripts/setup.sh`
to re-import after editing the NDJSON (idempotent, `overwrite=true`), or import
the files by hand via Stack Management → Saved Objects → **Import**.

### 4. See the telemetry in Kibana

- **Discover** — pick the **Claude Code — Metrics** or **Events** data view, or
  open one of the saved searches from the **Open** menu. Each per-`message` saved
  search opens with its `message` constraint as a removable **filter pill** (the
  query bar stays empty; **Event Overview** opens with no pill at all).
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
`service.name = aol-smoke-test`) to the OTLP/HTTP endpoint; **Assert** confirms
the docs landed in the APM data streams, then prints the `service.name` values
present so real `claude-code` telemetry shows up alongside the probe. A synthetic
probe is used (not a real `claude` session) so the check is deterministic and
runnable as a gate; real telemetry travels the identical path under its own name.

```sh
scripts/smoke-test.sh    # from anywhere — it locates its own stack directory
```

Needs `docker` (running daemon), `curl`, `jq`; it **SKIPs** (exit 0) when the
daemon is unreachable. Override endpoints with `ES_URL` / `APM_OTLP_URL`.

## Inspect Elasticsearch from Claude (optional)

Purely a developer convenience — **not part of the stack**. It lets a Claude Code
session query this stack's Elasticsearch through the [Elasticsearch MCP
server](https://github.com/elastic/mcp-server-elasticsearch) (read-only tools:
`search`, `esql`, `list_indices`, `get_mappings`, `get_shards`). The MCP server is
not a service you deploy — in stdio mode Claude Code launches it as a per-session
subprocess (a `docker run -i --rm …` that exits with the session) and it connects
*to* Elasticsearch as a client.

Register it once, in **`local` scope** (the `claude mcp add` default) so it is
active **only in this repo** (not your other projects) and is **not committed**
(it lives in your `~/.claude.json` keyed by project path). Run from the directory
you launch `claude` in, with the stack up:

Linux (reach the host's `:9200` via host networking):

```sh
claude mcp add elasticsearch -- \
  docker run -i --rm --network host \
  -e ES_URL=http://localhost:9200 \
  docker.elastic.co/mcp/elasticsearch stdio
```

macOS / Windows (Docker Desktop has no host networking — reach the host via
`host.docker.internal`):

```sh
claude mcp add elasticsearch -- \
  docker run -i --rm \
  -e ES_URL=http://host.docker.internal:9200 \
  docker.elastic.co/mcp/elasticsearch stdio
```

```powershell
claude mcp add elasticsearch -- `
  docker run -i --rm `
  -e ES_URL=http://host.docker.internal:9200 `
  docker.elastic.co/mcp/elasticsearch stdio
```

- **No API key** — this stack runs with security disabled, so `ES_URL` alone
  connects (the image's `ES_API_KEY` / basic-auth vars are unneeded here).
- Check status with `/mcp`; remove with `claude mcp remove elasticsearch`. When the
  stack is down the subprocess just fails to connect (no harm).
- ⚠️ This standalone server is **deprecated**; the supported successor is the
  [Elastic Agent Builder MCP server](https://www.elastic.co/docs/explore-analyze/ai-features/agent-builder/mcp-server)
  (built into Kibana at `/api/agent_builder/mcp`, GA in Stack 9.3+). It requires an
  API key + Kibana privileges — i.e. **security enabled** — so it does not fit this
  security-disabled demo, but it is the path on a real cluster.

## Layout

```
claude-code-elastic/
├─ docker-compose.yml                     # thin composition: `include:`s the Elastic backend component
├─ setup.conf                             # endpoints setup.{sh,ps1} target: elasticsearch.url / kibana.url + telemetry.apm_server.endpoint (APM OTLP)
├─ setup.local.conf.example               # template for the gitignored setup.local.conf (optional telemetry.apm_server.api_key)
└─ scripts/
   ├─ setup.sh                            # one-shot bootstrap: trace-routing + Kibana import
   ├─ setup.ps1                           # PowerShell mirror of setup.sh
   └─ smoke-test.sh                       # end-to-end pipeline verification (stack property)
```

`setup.{sh,ps1}` calls the component bootstrap scripts directly. The `elastic`
backend (`../../components/backends/elastic/`) is a thin `include:` of the
`elasticsearch` / `kibana` / `apm-server` service fragments plus a composition
script that selects its assets — it owns no asset files. The service fragments
under `../../components/backends/services/` own the service definitions and
config, the asset libraries (the `traces-apm@custom` / `logs-apm.app@custom`
ingest pipelines under `elasticsearch/`; the
Claude Code data views and saved searches under `kibana/claude-code/`), and the
generic Elasticsearch / Kibana appliers that load them. The Claude Code agent
component (`../../components/agents/claude-code/`) owns only agent-runtime
config — the **settings template + render
scripts** (the `.claude/settings.local.json` content), no Kibana assets.
