# claude-code-elastic-audit

> **Claude Code** audit hook → Elasticsearch → Kibana. The **audit** counterpart
> to `claude-code-elastic`: a direct hook → Elasticsearch write with **no APM
> Server** and no OTLP telemetry.

```
Claude Code hook    ──HTTP (direct)──▶  Elasticsearch  ──▶  Kibana
(UserPromptSubmit)                      :9200               :5601
```

This stack captures **what a Claude session was asked to do** — each submitted
prompt — by writing canonical audit documents straight to Elasticsearch from a
fail-open Claude Code hook. There is **no APM Server** here: audit is a direct
hook → Elasticsearch path that never traverses the OTLP / APM pipeline (see
[`../../SPEC/agent-audit.md`](../../SPEC/agent-audit.md)). For the OpenTelemetry
**telemetry** view (metrics / events / traces over APM Server), use the sibling
[`claude-code-elastic`](../claude-code-elastic/) stack instead.

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. Audit documents capture prompt text
> (plaintext in lab mode) — don't run a session containing secrets against this
> stack, and never commit captured audit data into the repo.

> ⚠️ **Cannot run alongside the other Elastic stacks.** This stack reuses the
> Elastic backend's fixed `aol-*` container names and host ports (`9200` /
> `5601`), so it **cannot run at the same time** as `claude-code-elastic`,
> `claude-code-otelcol-elastic`, `codex-cli-elastic`, or `codex-cli-elastic-audit`.
> It is an **alternative** to the telemetry stack, not a co-run: `docker compose
> down` the other stack before bringing this one up.

## Why a separate stack

Telemetry and audit are composed as **separate stacks** — not for physical
isolation (the lab is single-node) but to keep each stack's load-bearing set
legible. This stack's compose visibly carries **no APM Server**, and its agent
home (`.claude`) carries `settings.local.json` (the `UserPromptSubmit` audit-hook
registration — Claude registers hooks in settings, not a separate file),
`agent-audit.conf` (the hook delivery config), and `.mcp.json` (the Elasticsearch
MCP), with no telemetry `env`. The two stacks own separate Compose projects,
volumes, and agent homes. It reuses the `elastic-audit` backend wholesale, adding
only Claude Code's audit hook. See
[`../../SPEC/agent-audit.md`](../../SPEC/agent-audit.md) "Where this runs".

## Data streams

Audit records are **agent-cross-cutting**: the AI agent (Claude Code / Codex CLI /
…) is a document field (`agent_audit.agent.*`), not a segment of the data-stream
name. The streams are provisioned by `scripts/setup.sh`:

- `logs-agent_audit.user_prompt-default` — one document per submitted prompt
  (the `UserPromptSubmit` hook). **This is the stream Claude Code writes to today.**
- `logs-agent_audit.tool_call-default` — provisioned by the shared backend script
  for the cross-agent schema; Claude Code does not capture tool calls yet.

Both use **strict** mappings (an unexpected field fails the index rather than
silently growing the audit schema) and a 30-day retention default.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl` and `jq` (used by `setup.sh` and the verify script).
- Claude Code (`claude`), to generate real audit records.

## Quick Tour

The shortest path from clone to "I see Claude prompts in Elasticsearch."

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/claude-code-elastic-audit
docker compose up -d
docker compose ps        # wait until both services report healthy
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

Kibana is then at <http://localhost:5601>. The two backend services
(`aol-elasticsearch`, `aol-kibana`) are the `elastic-audit` backend — the same
local Elasticsearch as the telemetry stack, **minus APM Server**. `scripts/setup.sh`
runs the post-up bootstrap in one shot — it provisions the Agent Audit data streams
and their strict index templates, registers the `UserPromptSubmit` hook in
`.claude/settings.local.json`, renders the hook delivery config to
`.claude/agent-audit.conf`, writes the Elasticsearch MCP to `.mcp.json` (all in this
directory), and imports the Agent Audit Kibana **data views** and **saved searches**.
Steps are idempotent / create-if-absent, so re-run it any time. Override the ES
endpoint with `ES_URL` (`-EsUrl` for the `.ps1`) and the Kibana URL with `KIBANA_URL`.

### 2. Point a Claude session at the stack

`scripts/setup.sh` wrote a self-contained Claude home at
`stacks/claude-code-elastic-audit/.claude/` (gitignored) carrying the audit
config — `settings.local.json` (the `UserPromptSubmit` hook registration, with the
hook command's `--config` pointing at the absolute `agent-audit.conf` path) and
`agent-audit.conf` (the hook's Elasticsearch delivery config) — plus a project
`.mcp.json` (the Elasticsearch MCP server). There is no telemetry `env` — this stack
does no telemetry. Because Claude Code loads project settings from the launch
directory, just run `claude` **from this stack directory**:

```sh
# bash / zsh / fish / PowerShell — from the stack directory
claude
```

The first launch prompts to trust the project-scoped Elasticsearch MCP server
(interactive approval — deliberately not pre-approved). Provider identity
(`agent_audit.agent.account.*` / `organization.*`) is read locally from your
`~/.claude.json` `oauthAccount`; without an OAuth session those fields stay `null`
(valid — the workstation `user.id` is still derived).

Then submit a prompt or two. Each prompt you submit is reshaped into a canonical
`agent_audit.user_prompt` document and POSTed (fail-open, short timeout) to the
local audit data stream. Lab mode stores the captured text in **plaintext** for
searchability; production-oriented deployments should use encrypted content and
restricted read access.

### 3. Verify the audit path (optional)

```sh
scripts/verify-agent-audit.sh        # UserPromptSubmit -> user_prompt stream
```

It follows the 3A pattern: **Arrange** brings the stack up and waits for
Elasticsearch health; **Act** feeds a synthetic Claude `UserPromptSubmit` payload
through the configured hook (injecting the delivery config via `--config`, exactly
as a real session invokes it); **Assert** confirms the canonical audit document
landed in `logs-agent_audit.user_prompt-default`; **Cleanup** deletes the synthetic
document. It needs `docker` (running daemon), `curl`, `jq`, and a completed
`setup.sh`; it **SKIPs** (exit 0) when the daemon is unreachable or setup has not
run. Override the ES endpoint with `ES_URL` (`-EsUrl` for the `.ps1`).

### 4. See the audit records

The Agent Audit **data views** — **Agent Audit — User Prompts** and **Agent Audit
— Tool Calls** — plus their curated saved searches are imported by `scripts/setup.sh`.
Open Discover, pick a data view from the selector or open a saved search from the
Open menu. These views are backed by `logs-agent_audit.*-*`, not by any APM data
stream.

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

## What's deferred

Wired now: the composition (Elasticsearch + Kibana, no APM Server), the Agent Audit
data streams with strict mappings, the fail-open `UserPromptSubmit` hook, the
Elasticsearch MCP, and the Agent Audit data views + saved searches. Authored later,
with the human:

- **Prompt sealing** — lab mode stores captured prompt text in plaintext; an
  encrypted mode (null `text`, populated `encrypted_text`) is reserved in the
  schema but not built.
- **Tool-call capture for Claude Code** — only `UserPromptSubmit` is captured today;
  a `PostToolUse` audit hook (writing `logs-agent_audit.tool_call-default`, as Codex
  CLI already does) is a later increment.

## Layout

```
claude-code-elastic-audit/
├─ docker-compose.yml                     # thin composition: `include:`s the elastic-audit backend component
├─ README.md                              # this Quick Tour
└─ scripts/
   ├─ setup.sh                            # bootstrap: audit streams + settings.local.json (hook) + agent-audit.conf + .mcp.json + Kibana import
   ├─ setup.ps1                           # PowerShell mirror of setup.sh
   ├─ verify-agent-audit.sh               # UserPromptSubmit -> user_prompt stream verification
   └─ verify-agent-audit.ps1              # PowerShell mirror
```

`setup.{sh,ps1}` calls the component bootstrap scripts directly. The backend
services, their config, the Agent Audit index templates, the Agent Audit Kibana
NDJSON, and the audit setup / import scripts live in
`../../components/backends/elastic-audit/`; the Claude Code agent's audit hook
(`hooks/capture-prompt.{sh,ps1}`), the hook delivery-config template, and the
render scripts (`render-hook`, `render-agent-audit`, `render-mcp`) live in
`../../components/agents/claude-code/`. `scripts/setup.sh` registers the hook in
this directory's gitignored `.claude/settings.local.json`, renders the delivery
config into `.claude/agent-audit.conf`, writes `.mcp.json`, provisions the audit
data streams, and imports those Kibana objects.
```
