# claude-elastic-audit

> **Claude Code** audit hook → Elasticsearch → Kibana. The **audit** counterpart to
> [`claude-elastic`](../claude-elastic/): a direct hook → Elasticsearch write
> with **no APM Server** and no OTLP telemetry.

```
Claude Code hooks               ──HTTP (direct)──▶  Elasticsearch  ──▶  Kibana
(UserPromptSubmit, PostToolUse)                     :9200               :5601
```

This stack captures **what a Claude session did** — each submitted prompt and each
completed tool call — by writing canonical audit documents straight to Elasticsearch from
fail-open Claude Code hooks. There is **no APM Server**: audit is a direct hook →
Elasticsearch path that never traverses the OTLP / APM pipeline (see
[`../../SPEC/agent-audit.md`](../../SPEC/agent-audit.md)). For the OpenTelemetry
**telemetry** view (metrics / events / traces over APM Server), use the sibling
[`claude-elastic`](../claude-elastic/) stack instead.

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to `127.0.0.1`.
> Never expose this publicly. Audit documents capture prompt text and tool I/O (plaintext
> in lab mode) — don't run a session containing secrets against this stack, and never commit
> captured audit data into the repo.

> ⚠️ **Cannot run alongside the other Elastic stacks.** Reuses the fixed `aol-*` container
> names and host ports (`9200` / `5601`). An **alternative** to the telemetry stack, not a
> co-run: `docker compose down` the other stack first.

## Why a separate stack

Telemetry and audit are composed as **separate stacks** — not for physical isolation (the
lab is single-node) but to keep each stack's load-bearing set legible. This stack's compose
visibly carries **no APM Server**, and its agent home (`.claude`) carries
`settings.local.json` (the `UserPromptSubmit` + `PostToolUse` audit-hook registrations —
Claude registers hooks in settings, not a separate file), `agent-audit.conf` (the hook
delivery config), and `.mcp.json` (the Elasticsearch MCP), with no telemetry `env`. The two
stacks own separate Compose projects, volumes, and agent homes. It reuses the `elastic-audit`
backend wholesale, adding only Claude Code's audit hooks. See
[`../../SPEC/agent-audit.md`](../../SPEC/agent-audit.md) "Where this runs".

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl` and `jq` (used by `setup.sh` and the verify scripts).
- Claude Code (`claude`), to generate real audit records.

## Quick Tour

The shortest path from clone to "I see Claude prompts in Elasticsearch."

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/claude-elastic-audit
docker compose up -d
docker compose ps        # wait until both services report healthy
# edit setup.conf if your endpoints aren't the localhost defaults, then:
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

Kibana is then at <http://localhost:5601>. The two backend services (`aol-elasticsearch`,
`aol-kibana`) are the `elastic-audit` backend — the same local Elasticsearch as the
telemetry stack, **minus APM Server**. `scripts/setup.sh` runs the post-up bootstrap in one
shot — provisions the Agent Audit data streams and their strict index templates, registers
the `UserPromptSubmit` + `PostToolUse` hooks in `.claude/settings.local.json`, renders the
hook delivery config to `.claude/hooks/agent-audit.conf`, writes the Elasticsearch MCP to
`.mcp.json` (all in this directory), and imports the Agent Audit Kibana **data views** and
**saved searches**. Steps are idempotent / create-if-absent, so re-run it any time.

Both scripts read their endpoints from `setup.conf` at the stack root, or another file you
pass (`setup.sh <config>` / `setup.ps1 -Config <config>`), and fail fast if the file is
missing or a required key is empty rather than assuming localhost. `setup.conf` is two
planes:

| Plane | Keys | Notes |
| --- | --- | --- |
| **Control plane** | `elasticsearch.url`, `kibana.url` | backend + Elasticsearch MCP |
| **Agent data plane** | `agent_audit.elasticsearch.url`, `.timeout_ms`, `agent_audit.capture.{user_prompt,tool_call}.{enabled,content}` | the audit hook's required keys; no fallback to `elasticsearch.url` |
| **Secret** (gitignored) | `agent_audit.elasticsearch.api_key` in `setup.local.conf` | copy `setup.local.conf.example`; absent → empty (fine for this security-disabled demo) |

### 2. Point a Claude session at the stack

`scripts/setup.sh` wrote a self-contained Claude home at
`stacks/claude-elastic-audit/.claude/` (gitignored) carrying the audit config —
`settings.local.json` (the `UserPromptSubmit` + `PostToolUse` hook registrations, with each
hook command's `--config` pointing at the absolute `agent-audit.conf` path) and
`agent-audit.conf` (the hooks' Elasticsearch delivery config) — plus a project `.mcp.json`
(the Elasticsearch MCP server). There is no telemetry `env` — this stack does no telemetry.
Because Claude Code loads project settings from the launch directory, just run `claude`
**from this stack directory**:

```sh
# bash / zsh / fish / PowerShell — from the stack directory
claude
```

For a **one-shot** run, `claude -p "…"` fires the hooks too; pre-allow a tool so `PostToolUse`
actually runs, e.g. `claude -p "run: echo hello" --allowedTools Bash` (a prompt with no tool call
yields only the `user_prompt` audit).

The first launch prompts to trust the project-scoped Elasticsearch MCP server (interactive
approval — deliberately not pre-approved). Provider identity (`agent_audit.agent.account.*`
/ `organization.*`) is read locally from your `~/.claude.json` `oauthAccount`; without an
OAuth session those fields stay `null` (valid — the workstation `user.id` is still derived).

Then do a little work in the session. Each prompt you submit and each tool call Claude
completes is reshaped into a canonical `agent_audit.*` document and POSTed (fail-open, short
timeout) to the local audit data streams. Lab mode stores the captured text in **plaintext**
for searchability; production-oriented deployments should use encrypted content and
restricted read access.

**Deploy this audit bundle into another scope.** `setup-config` deploys the same
self-contained bundle (hook entry + shared core + adapter all materialized) to a
`(target, scope)`; details in [`../../SPEC/config-deployment.md`](../../SPEC/config-deployment.md).

| Scope | `--target` | MCP | Interactive | Teardown |
| --- | --- | --- | --- | --- |
| `local` (default) | rejected (stack dir) | yes | no | `--scope local --teardown` |
| `project` | required | no | no | `--scope project --target <dir> --teardown` |
| `managed` | n/a | no | yes | `--scope managed --teardown` |

**`project`** — the target gets its own `.claude/hooks/` (entry + core + adapter), with
nothing pointing back into this repo; deploys the audit config **only** and does **not**
register the Elasticsearch MCP (the MCP is a `local`-scope convenience). **Caveat:** this
captures that project's prompts and tool I/O into the lab's Elasticsearch — don't point
secret-bearing work at it.

```sh
scripts/setup-config.sh --scope project --target /path/to/your/project
# PowerShell: scripts/setup-config.ps1 -Scope project -Target C:\path\to\your\project
```

**`managed`** — enforce the audit hooks for **every** user on a machine (highest
precedence). This is an **audit-only** managed deploy — hooks, no telemetry — so the lab's
managed fragment, `managed-settings.d/10-observability.json` under the managed root, carries
only the `hooks` block (no telemetry `env`). It materializes the hook bundle into a `hooks/`
dir at that root and pins it. Claude merges every `*.json` in `managed-settings.d/`, so the
fragment sits beside any policy already deployed there and `managed-settings.json` is never
touched — which also means the lab will not warn you about one. Placement is **interactive,
deploy-only, and marker-aware** (confirms each file, never overwrites a file the lab did not
place, writes a provenance sidecar keyed on the audit ES url); a non-TTY shell aborts.

```sh
scripts/setup-config.sh --scope managed
# PowerShell: scripts/setup-config.ps1 -Scope managed
# teardown:   scripts/setup-config.sh --scope managed --teardown
```

> **Caveat — validate the host path.** Claude has no managed `hooks/` convention, so confirm
> on a **real host** that the absolute hook `command` path resolves under the managed root —
> `/Library/Application Support/ClaudeCode` on macOS (note the space) and
> `C:\Program Files\ClaudeCode` on Windows. The managed scripts abort under Git Bash / MINGW
> by design; run them on the real OS entry. See
> [`../../SPEC/config-deployment.md`](../../SPEC/config-deployment.md) "Managed materialize".

### 3. Verify the audit path (optional)

See [Verify the audit path](#verify-the-audit-path) below.

### 4. See the audit records

The Agent Audit **data views** — **Agent Audit — User Prompts** and **Agent Audit — Tool
Calls** — plus their curated saved searches are imported by `scripts/setup.sh`. Open
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
health; **Act** feeds a synthetic Claude hook payload through the **rendered** hook exactly
as Claude spawns it (reading the command + `args[]` from `settings.local.json`, with the
delivery config already baked into `--config`); **Assert** confirms the canonical audit
document landed in the right stream; **Cleanup** deletes the synthetic document. They need
`docker` (running daemon), `curl`, `jq`, and a completed `setup.sh`; they **SKIP** (exit 0)
when the daemon is unreachable or setup has not run. Override the ES endpoint with `ES_URL`
(`-EsUrl` for the `.ps1`).

## Data streams & assets

Audit records are **agent-cross-cutting**: the AI agent (Claude Code / Codex CLI / …) is a
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

Wired now: the composition (Elasticsearch + Kibana, no APM Server), the Agent Audit data
streams with strict mappings, the fail-open `UserPromptSubmit` + `PostToolUse` hooks, the
Elasticsearch MCP, and the Agent Audit data views + saved searches. Authored later, with the
human:

- **Prompt / tool-I/O sealing** — lab mode stores captured text in plaintext; an encrypted
  mode (null `text`, populated `encrypted_text`) is reserved in the schema but not built.

## Layout

```
claude-elastic-audit/
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
appliers that load them. The Claude Code agent component
(`../../components/agents/claude/`) owns only agent-runtime config — the single
audit-hook entry `hooks/agent-audit.{sh,ps1}` over its per-agent `hooks/lib/adapter.{sh,ps1}`
(the shared hook core lives once under `../../components/agents/shared/agent-audit/lib/`), the
hook delivery-config template, and the render scripts (`render-hook`, `render-agent-audit`,
`render-mcp`). `setup-config` registers the hooks in this directory's gitignored
`.claude/settings.local.json` (each command pointed at the absolute `agent-audit.conf` via
`--config`), renders the delivery config into `.claude/hooks/agent-audit.conf`, and writes
`.mcp.json`.
