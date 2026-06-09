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
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

Kibana is then at <http://localhost:5601>. `scripts/setup.sh` runs every post-up
bootstrap step in one shot — it installs the trace-routing ingest pipeline
(isolates Claude Code's spans into `traces-apm-agents_claude_code`), creates the
`prompts-audit` index, and imports the Kibana saved objects — and is idempotent,
so re-run it any time (e.g. after editing saved objects). Override endpoints with
`ES_URL` / `KIBANA_URL` (or `-EsUrl` / `-KibanaUrl` for the `.ps1`).

Optionally prove the pipeline end to end with the smoke test (see
[Verify the pipeline](#verify-the-pipeline)):

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
# set -gx OTEL_LOG_RAW_API_BODIES file:<repo>/var/api-bodies   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
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
# $env:OTEL_LOG_RAW_API_BODIES = "file:<repo>/var/api-bodies"   # file mode: untruncated bodies on disk (gitignored), events carry body_ref
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
directory (the repo ships a gitignored `var/api-bodies/` for exactly this) and
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
telemetry on across an organization.

Then run `claude` from a configured shell/directory and do a little work (ask a
question, let it read or edit a file). Telemetry flushes on the export interval,
so data lands within ~10–30s.

### 3. Import the Kibana saved objects

The importable NDJSON lives in the component directories — the backend's
cross-agent data view in `../../components/backends/elastic/kibana/`
(`agents-data-views.ndjson`), and the Claude Code agent's **data views**
(`data-views.ndjson`), **saved searches** (`saved-searches.ndjson`), and
**dashboard** (`dashboard.ndjson`) in
`../../components/agents/claude-code/kibana/`. The import helper below pulls
them in dependency order:

| Saved object | Type | Shows |
| --- | --- | --- |
| **Claude Code — Metrics** | data view (`metrics-apm.app.claude_code*`) | the numeric metric documents (physically scoped to the agent's data stream) |
| **Claude Code — Events** | data view (`logs-apm.app.claude_code*`) | the prompt / tool-result / API-request events (physically scoped to the agent's data stream) |
| **Claude Code — Traces** | data view (`traces-apm-agents_claude_code*`) | this agent's beta trace spans (per-agent isolated) |
| **AI Agents — Traces** | data view (`traces-apm-agents_*`) | all AI agents' trace spans (cross-agent: claude_code, codex, …), excludes non-agent traces |
| **Event Overview**, **API Requests**, **Tool Results**, **Tool Decisions**, **User Prompts**, **Hook Registered**, **Hook Executions**, **Subagent Completions**, **Permission Mode Changes**, **MCP Server Connections**, **Auth Events** | saved searches | **Event Overview** is the all-event-types timeline; the rest are per-`message` curated column views on the Events data view (each ends with `trace.id`, a click-through to the APM UI trace) |
| **Claude Code — Interactions** | saved search | one row per **interactive turn** (the `interaction` root) — rich turn columns (prompt, sequence, duration); interactive-only |
| **Claude Code — Traces** | saved search | one row per **trace, all session types** (`processor.event: transaction`); `transaction.name` shows the root type (interaction vs llm_request/tool) |
| **Claude Code — Overview** | dashboard | a starter demo dashboard — Lens panels over the metrics & events data views |

The saved searches and the dashboard **reference the data views**, so they are
imported data-views-first (or all together).

- **Already imported by `scripts/setup.sh`** (step 1) — it runs the backend
  import then the agent import, each in dependency order (data views first). To
  re-import after editing the NDJSON, just re-run `scripts/setup.sh` (idempotent,
  `overwrite=true`).
- **Kibana UI** — Stack Management → Saved Objects → **Import** → choose the
  `.ndjson` file(s), data views first.
- **Manual API** — `POST` each file (data views first) to
  `/api/saved_objects/_import?overwrite=true` with header `kbn-xsrf: true`; the
  helper above just wraps this.

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

## Prompt audit trail (independent of OTLP)

A separate, opt-in capability that answers **"when / who / what prompt"** for
compliance — built on a path that is **completely independent of the OTLP
analytics pipeline** above. A Claude Code `UserPromptSubmit` hook captures each
prompt **at the source** (full text, before any `OTEL_LOG_USER_PROMPTS`
redaction/truncation) and POSTs one document straight to a dedicated
Elasticsearch index, `prompts-audit` — it does **not** travel through the APM
Server, so metrics/events/traces keep flowing untouched. Because it is a plain
agent hook, it carries zero extra infrastructure and can be pushed to an entire
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

**2. Register the capture hook** in a Claude Code settings file's `hooks` block
(the hook is agent config, like the `OTEL_*` env above). The capture script is
`components/agents/claude-code/hooks/capture-prompt.sh` (PowerShell mirror:
`capture-prompt.ps1`); point the command at its absolute path:

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
└─ scripts/
   ├─ setup.sh                            # one-shot bootstrap: trace-routing + prompts-audit + Kibana import
   ├─ setup.ps1                           # PowerShell mirror of setup.sh
   └─ smoke-test.sh                       # end-to-end pipeline verification (stack property)
```

`setup.{sh,ps1}` calls the component bootstrap scripts directly. The backend
services, their config, the cross-agent data view, the `traces-apm@custom`
pipeline body, the `prompts-audit` index mapping, and the Backend bootstrap
scripts (trace-routing, prompt-audit, Kibana import) live in
`../../components/backends/elastic/`; the Claude Code agent's data views, saved
searches, Overview dashboard — with their own import script — and the
prompt-capture **hooks** live in `../../components/agents/claude-code/`.
