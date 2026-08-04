# claude-elastic

> Claude Code → APM Server (Elastic-native OTLP) → Elasticsearch → Kibana.
> Bring it up, point a Claude Code session at it, and inspect the real
> **metrics** (sessions, tokens, cost, code edits, commits) and **events**
> (prompts, tool results, API requests) the agent emits.

```
Claude Code  ──OTLP/HTTP (+gRPC)──▶  APM Server  ──▶  Elasticsearch  ──▶  Kibana
(metrics + events)                   :8200            :9200                :5601
```

**APM Server** is the OTLP receiver — Elastic's native, fully-supported way to
ingest OpenTelemetry straight into Elasticsearch; Claude Code points at it
directly.

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. The events channel can capture your
> prompt text and tool I/O — don't run a telemetry-enabled session containing
> secrets or confidential material against this stack, and never commit captured
> telemetry into the repo.

> ⚠️ **Cannot run alongside the other Elastic stacks.** Reuses the fixed `aol-*`
> container names and host ports (`9200` / `5601` / `8200`). `docker compose down`
> the other stack first.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl` and `jq` (used by the smoke test; `provision-standalone.{sh,ps1}` needs only `curl`).
- Claude Code, to generate real telemetry.

## Quick Tour

The shortest path from clone to "I see Claude Code telemetry in Kibana."

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/claude-elastic
docker compose up -d
docker compose ps        # wait until all three services report healthy
# edit agent-config.toml if your endpoints aren't the localhost defaults, then:
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

Kibana is then at <http://localhost:5601>. `scripts/setup.sh` runs every post-up
bootstrap step in one shot — loads the Elasticsearch assets (the APM `@custom`
routers, the ingest pipelines that isolate Claude Code spans into
`traces-apm-agents_claude_code`, the per-agent ILM/templates) and imports the
Kibana saved objects — and is idempotent, so re-run it any time. The config is
split by reader: the backend control plane (targets, per-stack groups,
dependency edges) lives in the shared espalier project at
`../../components/backends/espalier.toml` — `scripts/provision.{sh,ps1}` just
runs `espalier apply --group claude-elastic` in the stack's compose network —
and the `agent-config` CLI reads the agent data plane (the APM OTLP `endpoint`
under `[telemetry.apm_server]`) from the TOML `agent-config.toml`, failing
fast if a file is missing or a key is empty rather than assuming localhost.

The demo APM Server has auth disabled, so no OTLP credential is needed. For a
**secured** endpoint, copy `agent-config.local.toml.example` to the gitignored
`agent-config.local.toml` (beside `agent-config.toml`; the `--local-conf <file>`
CLI flag can point elsewhere) and set `api_key` under `[telemetry.apm_server]` —
`setup.sh` then adds `Authorization: ApiKey <key>` to the agent's OTLP exports.
Absent/empty ships no credential.

Optionally prove the pipeline with the smoke test ([Verify the pipeline](#verify-the-pipeline)):

```sh
scripts/smoke-test.sh
```

### 2. Point a Claude Code session at the stack

**Simplest path:** step 1 already generated `.claude/settings.local.json` in this
stack directory with the telemetry `env` block (pointed at this stack's `:8200`
OTLP endpoint) **and** the prompt-audit hook — so just run **`claude` from
`stacks/claude-elastic/`** and both telemetry and prompt auditing are on, with
no manual export or hook registration. (Project settings load only from the launch
directory, so launch `claude` here.) The options below are alternatives — for a
session you launch *elsewhere*, or to enable telemetry globally / org-wide.

The telemetry vars configure **`claude`** itself, not the stack. They enable
`CLAUDE_CODE_ENABLE_TELEMETRY` and the `OTEL_*` exporters for **both** metrics and
events at the `:8200` APM Server OTLP endpoint, with short export intervals so data
appears quickly. Supply them one of three ways:

| Option | What | Persistence | When |
| --- | --- | --- | --- |
| **A — shell env** | `export`/`set` the vars (below), then launch `claude` from any directory | ephemeral, creates no files | one-off, recommended |
| **B — `settings.json` `env`** | same vars in a Claude Code settings file's `env` block | persistent; project-scope applies only from the launch dir, `~/.claude/settings.json` everywhere | keep telemetry on for a project / user |
| **C — managed settings** | a machine-global [managed settings](https://code.claude.com/docs/en/monitoring-usage.md) fragment, **highest precedence, user cannot override** | enforced org-wide | force telemetry on across an org |

**Option A — shell env.**

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

With those set, launch `claude` from any directory; a **one-shot** `claude -p "summarize this repo"` emits the same metrics/events (flushed on exit).

**Option B — `settings.json` `env` block.**

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

The four `OTEL_LOG_*` content-exposure gates are shown explicitly set to `0` (off)
so they are visible knobs — Claude Code enables each only on `1` (or `file:<dir>`
for `OTEL_LOG_RAW_API_BODIES`), so `0` and "unset" both mean off. Flip **one at a
time** to observe what it adds, and keep real secrets out of any session while a
gate is on. The `file:` variant writes **untruncated** request/response bodies to
the directory you point it at (gitignore it); the `api_*_body` events then carry
`labels.body_ref` pointers instead of inline fragments — see the
`OTEL_LOG_RAW_API_BODIES` section of [`../../SPEC/claude-telemetry.md`](../../SPEC/claude-telemetry.md).
Project settings load **only from the directory `claude` is launched in** (not
inherited from parents); `~/.claude/settings.json` applies everywhere.

**Option C — managed settings (org enforcement).** The `env` block placed here is
**enforced**: users cannot turn telemetry off, change the endpoint, or flip the
`OTEL_LOG_*` gates. This stack can place it for you as a **drop-in fragment** in the
machine-global managed directory — **opt-in, always interactive, never destructive**.
The directory is admin-owned and fixed (the same one your real employer's policy may
already use); the fragment inside it is the lab's own file:

| OS | Fragment |
| --- | --- |
| Linux/WSL | `/etc/claude-code/managed-settings.d/10-agent-observability-lab.json` |
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.d/10-agent-observability-lab.json` |
| Windows | `C:\Program Files\ClaudeCode\managed-settings.d\10-agent-observability-lab.json` |

Claude Code merges **every `*.json`** in that directory — alphabetically, with arrays
concatenated and later files winning scalar conflicts — so the lab's fragment sits
**beside** any policy already deployed there and never touches `managed-settings.json`
itself. The flip side: the lab no longer notices such a policy, so check the directory
yourself before placing.

Placement **refuses to overwrite any file the lab did not place** (tracked by a
sidecar `.managed` marker) and prompts before writing. There is **no `--yes`**; a
non-interactive shell aborts having changed nothing, and permission errors fail loud
with the privileged command to run by hand. Place via `setup.sh --scope managed`
(runs after the normal setup steps) or directly via the `agent-config` CLI
(requires a Rust toolchain; `cargo run` builds on first use):

```sh
cargo run -q --manifest-path ../../components/agent-config/Cargo.toml -- place --agent claude --config agent-config.toml --scope managed
```

**Staged opt-in — also enforce the audit hooks.** Off by default (managed enforces
telemetry only — "config-only"): the CLI includes the hook bundle only when the config
it places from carries `agent_audit.*` keys, and this stack's `agent-config.toml` declares
telemetry only. Placing from an audit-bearing config (as the sibling
[`claude-elastic-audit`](../claude-elastic-audit/) stack's is) **materializes** the audit-hook bundle (entry +
shared core + adapter, both shells, plus a rendered `agent-audit.conf`) into
`hooks/agent-observability-lab/` under the **managed root** and adds a `hooks` block
pointing at it — so the enforced hooks are self-contained on the host, never
referencing this repo. The owner-scoped subdirectory keeps the bundle from colliding
with another distribution of the same tooling on a machine-global root.

> **Host-check gate — do this once before relying on managed hooks.** Claude Code has
> no managed hooks-directory convention, so the lab picks its own dir under the managed
> root. Confirm on a **real host** that an absolute hook `command`
> path actually fires (mind the macOS space in `Application Support` and the Windows
> `C:\Program Files\ClaudeCode` path) and record the result. Until confirmed, keep
> managed config-only (place from a telemetry-only config).

Remove it (restores the host, removes only the lab-placed files + their markers —
the CLI enumerates every candidate target, including a materialized hook bundle,
from the config on its own):

```sh
cargo run -q --manifest-path ../../components/agent-config/Cargo.toml -- teardown --agent claude --config agent-config.toml --scope managed
```

Then run `claude` from a configured shell/directory and do a little work (ask a
question, let it read or edit a file). Telemetry flushes on the export interval, so
data lands within ~10–30s.

**Deploy this config into another scope.** The `agent-config` CLI's `place` deploys
the same self-contained bundle to a `(target, scope)`, and its `teardown` subcommand
removes it; details in [`../../SPEC/config-deployment.md`](../../SPEC/config-deployment.md).

| Scope | `--target` | MCP | Codex auth-link | Interactive | Teardown |
| --- | --- | --- | --- | --- | --- |
| `local` (default) | rejected (stack dir) | yes | n/a (Claude) | no | `teardown --scope local` |
| `project` | required | no | n/a | no | `teardown --scope project --target <dir>` |
| `managed` | n/a | no | n/a | yes | `teardown --scope managed` |

```sh
cargo run -q --manifest-path ../../components/agent-config/Cargo.toml -- place --agent claude --config agent-config.toml --scope project --target /path/to/your/project
```

`project` scope writes a self-contained `.claude/` into that directory (nothing
pointing back into this repo), deploying the telemetry config **only** — it does
**not** register the Elasticsearch MCP, keeping the foreign project's footprint
minimal (the MCP is a `local`-scope convenience). **Caveat:** this flows that
project's prompts and tool I/O into the lab's Elasticsearch — don't point
secret-bearing work at it.

### 3. Verify the pipeline

See [Verify the pipeline](#verify-the-pipeline) below. The Kibana saved objects
(data views + curated saved searches for **both** agents, plus the cross-agent
**Agents — Adoption Overview** dashboard) are already imported by step 1; to
re-import after editing the NDJSON, re-run `scripts/setup.sh` (idempotent,
`overwrite=true`), or import by hand via Stack Management → Saved Objects →
**Import**.

### 4. See the telemetry in Kibana

- **Discover** — pick the **Claude Code — Metrics** or **Events** data view, or open
  one of the saved searches from the **Open** menu. Each per-`message` saved search
  opens with its `message` constraint as a removable **filter pill** (the query bar
  stays empty; **Event Overview** opens with no pill at all).
- **Dashboards** — **Agents — Adoption Overview** places Codex (left) and Claude
  (right) side by side. Only Claude feeds data in this stack, so the Codex half
  shows no results — expected, not a fault.
- **APM UI** (<http://localhost:5601/app/apm>) — Claude Code registers as an APM
  **service** (`claude-code`); open it to see it as a first-class APM entity.

### 5. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe ingested telemetry
```

## Verify the pipeline

`scripts/smoke-test.sh` checks the full **OTLP → APM Server → Elasticsearch** path
end to end, following the 3A pattern: **Arrange** brings the stack up and waits for
health; **Act** POSTs a synthetic OTLP metrics + logs probe (tagged
`service.name = aol-smoke-test`) to the OTLP/HTTP endpoint; **Assert** confirms the
docs landed in the APM data streams, then prints the `service.name` values present so
real `claude-code` telemetry shows up alongside the probe. A synthetic probe is used
(not a real `claude` session) so the check is deterministic and runnable as a gate;
real telemetry travels the identical path under its own name.

```sh
scripts/smoke-test.sh    # from anywhere — it locates its own stack directory
```

Needs `docker` (running daemon), `curl`, `jq`; it **SKIPs** (exit 0) when the daemon
is unreachable. Override endpoints with `ES_URL` / `APM_OTLP_URL`.

> **The probe writes into the stack and is not cleaned up.** The metrics/logs documents
> create `*_aol_smoke_test-default` data streams that stay visible in Kibana, and the
> trace span lands in the shared `traces-apm-default` stream next to real agent traces.
> Don't run it against an environment you are inspecting by hand; `docker compose down -v`
> is the reset.

## Data streams & assets

| Asset | Where | Notes |
| --- | --- | --- |
| `metrics-apm.app.*` / `logs-apm.app.*` | per-service data streams | metrics + events under `service.name: claude-code` |
| `traces-apm-agents_claude_code` | per-agent trace data stream | spans isolated by the ingest pipelines |
| Data views | `Claude Code — Metrics` / `Events` (+ Traces) | imported by `setup.sh` |
| Saved searches | Event Overview, API Requests, Tool Results, … | per-`message` searches open with a filter pill |
| APM service | `claude-code` | first-class entity in the APM UI |

## Inspect Elasticsearch from Claude (optional)

Purely a developer convenience — **not part of the stack**. It lets a Claude Code
session query this stack's Elasticsearch through the [Elasticsearch MCP server](https://github.com/elastic/mcp-server-elasticsearch)
(read-only tools: `search`, `esql`, `list_indices`, `get_mappings`, `get_shards`).
The MCP server is not a service you deploy — in stdio mode Claude Code launches it as
a per-session subprocess (a `docker run -i --rm …` that exits with the session) and it
connects *to* Elasticsearch as a client.

Register it once, in **`local` scope** (the `claude mcp add` default) so it is active
**only in this repo** and is **not committed** (it lives in your `~/.claude.json` keyed
by project path). Run from the directory you launch `claude` in, with the stack up:

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

- **No API key** — this stack runs with security disabled, so `ES_URL` alone connects
  (the image's `ES_API_KEY` / basic-auth vars are unneeded here).
- Check status with `/mcp`; remove with `claude mcp remove elasticsearch`. When the
  stack is down the subprocess just fails to connect (no harm).
- ⚠️ This standalone server is **deprecated**; the supported successor is the
  [Elastic Agent Builder MCP server](https://www.elastic.co/docs/explore-analyze/ai-features/agent-builder/mcp-server)
  (built into Kibana at `/api/agent_builder/mcp`, GA in Stack 9.3+). It requires an API
  key + Kibana privileges — i.e. **security enabled** — so it does not fit this
  security-disabled demo, but it is the path on a real cluster.

## Layout

```
claude-elastic/
├─ docker-compose.yml                     # thin composition: `include:`s the Elastic backend component
├─ agent-config.toml                      # agent data plane the agent-config CLI reads: [telemetry.apm_server] endpoint (APM OTLP)
├─ agent-config.local.toml.example        # template for the gitignored agent-config.local.toml (optional [telemetry.apm_server] api_key)
└─ scripts/
   ├─ setup.sh / setup.ps1               # one-shot bootstrap = provision then agent-config place
   ├─ provision.sh / .ps1                # espalier apply --group claude-elastic (docker, in-network)
   ├─ provision-standalone.sh / .ps1     # generated by espalier render-script: curl-only, payloads embedded
   └─ smoke-test.sh                       # end-to-end pipeline verification (stack property)
```

`setup.{sh,ps1}` composes the two halves: the `provision` façade script, then the
`agent-config` CLI's `place` (`cargo run` against
`../../components/agent-config/`). The `elastic` backend
(`../../components/backends/elastic/`) is a thin `include:` of the `elasticsearch` /
`kibana` / `apm-server` service fragments plus a composition script that selects its
assets — it owns no asset files. The service fragments under
`../../components/backends/services/` own the service definitions and config, the asset
libraries (the `traces-apm@custom` / `logs-apm.app@custom` ingest pipelines under
`elasticsearch/`; the Claude Code data views and saved searches under
`kibana/claude/`), and the generic appliers that load them. The Claude Code agent
component (`../../components/agents/claude/`) owns only agent-runtime config — the
settings templates (the `.claude/settings.local.json` content, rendered by the
`agent-config` CLI), no Kibana assets.
