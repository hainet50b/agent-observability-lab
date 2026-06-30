# codex-elastic-audit

> OpenAI **Codex CLI** audit hooks → Elasticsearch → Kibana. The **audit** counterpart to
> [`codex-elastic`](../codex-elastic/): a direct hook → Elasticsearch write with
> **no APM Server** and no OTLP telemetry.

```
Codex CLI hooks  ──HTTPS (direct)──▶  Elasticsearch  ──▶  Kibana
(UserPromptSubmit, PostToolUse)       :9200               :5601
```

This stack captures **what a Codex session did** — each submitted prompt and each completed
tool call — by writing canonical audit documents straight to Elasticsearch from fail-open
Codex hooks. There is **no APM Server**: audit is a direct hook → Elasticsearch path that
never traverses the OTLP / APM pipeline (see [`../../SPEC/agent-audit.md`](../../SPEC/agent-audit.md)).
For the OpenTelemetry **telemetry** view (metrics / events / traces over APM Server), use the
sibling [`codex-elastic`](../codex-elastic/) stack instead.

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to `127.0.0.1`.
> Never expose this publicly. Audit documents capture prompt text and tool I/O (plaintext in
> lab mode) — don't run a session containing secrets against this stack, and never commit
> captured audit data into the repo.

> ⚠️ **Cannot run alongside the other Elastic stacks.** Reuses the fixed `aol-*` container
> names and host ports (`9200` / `5601`). An **alternative** to the telemetry stack, not a
> co-run: `docker compose down` the other stack first.

## Why a separate stack

Telemetry and audit are composed as **separate stacks** — not for physical isolation (the
lab is single-node) but to keep each stack's load-bearing set legible. This stack's compose
visibly carries **no APM Server**, and its agent home (`.codex`) carries `config.toml` (the
inline `[hooks]` audit-hook registrations plus the Elasticsearch MCP) and `agent-audit.conf`
(the hook delivery config), with no `[otel]` telemetry. The two stacks own separate Compose
projects, volumes, and agent homes. See [`../../SPEC/agent-audit.md`](../../SPEC/agent-audit.md)
"Where this runs".

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl` and `jq` (used by `setup.sh` and the verify scripts).
- Codex CLI (`codex`), to generate real audit records.

## Quick Tour

The shortest path from clone to "I see Codex prompts and tool calls in Elasticsearch."

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/codex-elastic-audit
docker compose up -d
docker compose ps        # wait until both services report healthy
# edit setup.conf if your endpoints aren't the localhost defaults, then:
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

Kibana is then at <http://localhost:5601>. The two backend services (`aol-elasticsearch`,
`aol-kibana`) are the `elastic-audit` backend — the same local Elasticsearch as the
telemetry stack, **minus APM Server**. `scripts/setup.sh` runs the post-up bootstrap in one
shot — provisions the two Agent Audit data streams and their strict index templates, renders
the hook delivery config to `.codex/hooks/agent-audit.conf` and registers the audit hooks as inline
`[hooks]` in `.codex/config.toml` (both in this directory), and imports the Agent Audit Kibana
**data views** and **saved searches**. Steps are idempotent / create-if-absent, so re-run it
any time.

Both scripts read their endpoints from `setup.conf` at the stack root, or another file you
pass (`setup.sh <config>` / `setup.ps1 -Config <config>`), and fail fast if the file is
missing or a required key is empty rather than assuming localhost. `setup.conf` is two planes:

| Plane | Keys | Notes |
| --- | --- | --- |
| **Control plane** | `elasticsearch.url`, `kibana.url` | backend + Elasticsearch MCP |
| **Agent data plane** | `agent_audit.elasticsearch.url`, `.timeout_ms`, `agent_audit.capture.{user_prompt,tool_call}.{enabled,content}` | the audit hook's required keys; no fallback to `elasticsearch.url` |
| **Secret** (gitignored) | `agent_audit.elasticsearch.api_key` in `setup.local.conf` | copy `setup.local.conf.example`; absent → empty (fine for this security-disabled demo) |

### 2. Point a Codex session at the stack

`scripts/setup.sh` (step 1) wrote a self-contained Codex home at
`stacks/codex-elastic-audit/.codex/` (gitignored) carrying the audit config —
`agent-audit.conf` (the hooks' Elasticsearch delivery config) and `config.toml` (the
`UserPromptSubmit` + `PostToolUse` hook registrations as inline `[hooks]`, plus the
Elasticsearch MCP). There is no `[otel]` config — this stack does no telemetry. Launch Codex
with **`CODEX_HOME`** pointed at it so the hooks are picked up as user-level config:

```sh
# bash / zsh — from the stack directory
CODEX_HOME="$PWD/.codex" codex
```

```fish
# fish
env CODEX_HOME="$PWD/.codex" codex
```

```powershell
# PowerShell — from the stack directory
$env:CODEX_HOME = "$PWD\.codex"; codex
```

> **Credentials under the relocated `CODEX_HOME`.** Because `CODEX_HOME` relocates the
> entire Codex home, Codex won't see your existing `~/.codex` login on its own. `local`-scope
> setup links your `~/.codex/auth.json` into this `.codex/` for you (symlink, or a copy with a
> staleness note); if the link is absent (no source login), `codex login` once under this
> `CODEX_HOME`. Provider identity (`agent_audit.agent.account.*` / `organization.*`) is read
> from that `auth.json`; without it those fields stay `null` (valid — the workstation
> `user.id` is still derived). Everything Codex writes here stays in the gitignored `.codex/`.

Then do a little work in the session. Each prompt you submit and each tool call Codex
completes is reshaped into a canonical `agent_audit.*` document and POSTed (fail-open, short
timeout) to the local audit data streams. Lab mode stores the captured text in **plaintext**
for searchability; production-oriented deployments should use encrypted content and
restricted read access.

> **Entrypoint matters.** The hooks fire from the interactive `codex` REPL. The audit path is
> independent of telemetry, so it works even though this stack emits no OTLP.

**Deploy this audit bundle into another scope.** `setup-config` deploys the same
self-contained bundle (hook entry + shared core + adapter all materialized) to a
`(target, scope)`; details in [`../../SPEC/config-deployment.md`](../../SPEC/config-deployment.md).

| Scope | `--target` | MCP | Codex auth-link | Interactive | Teardown |
| --- | --- | --- | --- | --- | --- |
| `local` (default) | rejected (stack dir) | yes | yes (links `~/.codex/auth.json`) | no | `--scope local --teardown` |
| `project` | required | no | no | no | `--scope project --target <dir> --teardown` |
| `managed` | n/a | no | no | yes | `--scope managed --teardown` |

**`project`** — the target gets its own `.codex/hooks/` (entry + core + adapter), with
nothing pointing back into this repo; deploys the audit config **only** and does **not**
register the Elasticsearch MCP (the MCP is a `local`-scope convenience). **Caveat:** this
captures that project's prompts and tool I/O into the lab's Elasticsearch — don't point
secret-bearing work at it.

```sh
scripts/setup-config.sh --scope project --target /path/to/your/project
# PowerShell: scripts/setup-config.ps1 -Scope project -Target C:\path\to\your\project
```

**`managed`** — enforce the audit hooks for **every** user on a machine (highest
precedence). This is an **audit-only** managed deploy — hooks, no telemetry — so it places
**only `requirements.toml`** (pinning `[features].hooks` and the hook tables, pointing at the
host `managed_dir`) and **no `managed_config.toml`** (with no telemetry that file would be
just a comment). It materializes the hook bundle into the host `managed_dir` and pins it via
`requirements.toml`. Placement is **interactive, deploy-only, and marker-aware** (confirms
each file, never overwrites a foreign/real-org config, writes a provenance sidecar keyed on
the audit ES url); a non-TTY shell aborts.

```sh
scripts/setup-config.sh --scope managed
# PowerShell: scripts/setup-config.ps1 -Scope managed
# teardown:   scripts/setup-config.sh --scope managed --teardown
```

> **Caveat — validate the host path.** Confirm on a **real host** that the absolute hook
> `command` path resolves under the managed root — `/etc/codex` on macOS/Linux and
> `%ProgramData%\OpenAI\Codex` (Windows `Program Files`-class path). The managed scripts abort
> under Git Bash / MINGW by design; run them on the real OS entry. See
> [`../../SPEC/config-deployment.md`](../../SPEC/config-deployment.md) "Managed materialize".

### 3. Verify the audit path (optional)

See [Verify the audit path](#verify-the-audit-path) below.

### 4. See the audit records

The Agent Audit **data views** — **Agent Audit — User Prompts** and **Agent Audit — Tool
Calls** — plus their curated saved searches are imported by `scripts/setup.sh` (step 1). Open
Discover, pick a data view from the selector or open a saved search from the Open menu. These
views are backed by `logs-agent_audit.*-*`, not by any APM data stream.

You can also look directly with a query:

```sh
# the latest captured prompts
curl -s 'http://localhost:9200/logs-agent_audit.user_prompt-default/_search?size=5&sort=@timestamp:desc' \
  -H 'Content-Type: application/json' | jq '.hits.hits[]._source.agent_audit.user_prompt'
```

### 5. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe captured audit records
```

## Verify the audit path

```sh
scripts/verify-agent-audit.sh        # UserPromptSubmit -> user_prompt stream
scripts/verify-tool-call-audit.sh    # PostToolUse      -> tool_call stream
```

Each follows the 3A pattern: **Arrange** brings the stack up and waits for Elasticsearch
health; **Act** feeds a synthetic Codex hook payload through the configured hook (with
`CODEX_HOME` pointed at this stack's `.codex`, exactly as a real session invokes it);
**Assert** confirms the canonical audit document landed in the right stream; **Cleanup**
deletes the synthetic document. They need `docker` (running daemon), `curl`, `jq`, and a
completed `setup.sh`; they **SKIP** (exit 0) when the daemon is unreachable or setup has not
run. Override the ES endpoint with `ES_URL` (`-EsUrl` for the `.ps1`).

## Data streams & assets

Audit records are **agent-cross-cutting**: the AI agent (Codex / Claude Code / …) is a
document field (`agent_audit.agent.*`), not a segment of the data-stream name. Provisioned by
`scripts/setup.sh`:

| Asset | Where | Notes |
| --- | --- | --- |
| `logs-agent_audit.user_prompt-default` | one doc per submitted prompt | the `UserPromptSubmit` hook |
| `logs-agent_audit.tool_call-default` | one doc per completed tool call | the `PostToolUse` hook |
| Mappings / retention | both streams | **strict** mappings (unexpected field fails the index) + 3-day ILM default |
| Data views | **Agent Audit — User Prompts** / **Tool Calls** | backed by `logs-agent_audit.*-*`, no APM stream |
| Saved searches | curated Agent Audit searches | imported by `setup.sh` |

## What's deferred

Wired now: the composition (Elasticsearch + Kibana, no APM Server), the two Agent Audit data
streams with strict mappings, the fail-open `UserPromptSubmit` + `PostToolUse` hooks, and the
Agent Audit data views + saved searches. Authored later, with the human:

- **Prompt / tool-I/O sealing** — lab mode stores captured text in plaintext; an encrypted
  mode (null `text`, populated `encrypted_text`) is reserved in the schema but not built.

## Layout

```
codex-elastic-audit/
├─ docker-compose.yml                     # thin composition: `include:`s the elastic-audit backend component
├─ setup.conf                             # control plane (Elasticsearch / Kibana) + agent data plane (agent_audit.*)
├─ setup.local.conf.example               # template for the gitignored setup.local.conf (audit api_key secret)
├─ README.md                              # this Quick Tour
└─ scripts/
   ├─ setup.sh / setup.ps1               # one-shot bootstrap = setup-backend then setup-config
   ├─ setup-backend.sh / .ps1            # wait for health, provision audit streams + Kibana import
   ├─ setup-config.sh / .ps1             # deploy the audit bundle (--scope local|project|managed)
   ├─ verify-agent-audit.sh / .ps1       # UserPromptSubmit -> user_prompt stream verification
   └─ verify-tool-call-audit.sh / .ps1   # PostToolUse -> tool_call stream verification
```

`setup.{sh,ps1}` composes the two halves (`setup-backend` then `setup-config`), each calling
the component façade scripts directly. The `elastic-audit` backend
(`../../components/backends/elastic-audit/`) is a thin `include:` of the `elasticsearch` /
`kibana` service fragments plus a composition script that selects its assets — it owns no
asset files. The service fragments under `../../components/backends/services/` own the service
definitions and config, the asset libraries (the Agent Audit data-stream ILM / `@mappings` +
`@lifecycle` component templates / index templates under `elasticsearch/agent-audit/`; the
Agent Audit data views and saved searches under `kibana/agent-audit/`), and the generic
appliers that load them. The Codex agent component (`../../components/agents/codex/`)
owns only agent-runtime config — the single audit-hook entry `hooks/agent-audit.{sh,ps1}` over
its per-agent `hooks/lib/adapter.{sh,ps1}` (the shared hook core lives once under
`../../components/agents/shared/agent-audit/lib/`), the hook delivery-config template, and the
render scripts. `setup-config` renders the delivery config into this directory's gitignored
`.codex/hooks/agent-audit.conf` and registers the stack-local hooks as inline `[hooks]` (plus the
Elasticsearch MCP) in `.codex/config.toml`.
