# claude-code-elastic-audit

> **Claude Code** audit hook → Elasticsearch → Kibana. The **audit** counterpart
> to `claude-code-elastic`: a direct hook → Elasticsearch write with **no APM
> Server** and no OTLP telemetry.

```
Claude Code hooks               ──HTTP (direct)──▶  Elasticsearch  ──▶  Kibana
(UserPromptSubmit, PostToolUse)                     :9200               :5601
```

This stack captures **what a Claude session did** — each submitted prompt and
each completed tool call — by writing canonical audit documents straight to
Elasticsearch from fail-open Claude Code hooks. There is **no APM Server** here: audit is a direct
hook → Elasticsearch path that never traverses the OTLP / APM pipeline (see
[`../../SPEC/agent-audit.md`](../../SPEC/agent-audit.md)). For the OpenTelemetry
**telemetry** view (metrics / events / traces over APM Server), use the sibling
[`claude-code-elastic`](../claude-code-elastic/) stack instead.

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. Audit documents capture prompt text
> and tool I/O (plaintext in lab mode) — don't run a session containing secrets
> against this stack, and never commit captured audit data into the repo.

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
home (`.claude`) carries `settings.local.json` (the `UserPromptSubmit` +
`PostToolUse` audit-hook registrations — Claude registers hooks in settings, not a
separate file), `agent-audit.conf` (the hook delivery config), and `.mcp.json`
(the Elasticsearch MCP), with no telemetry `env`. The two stacks own separate
Compose projects, volumes, and agent homes. It reuses the `elastic-audit` backend
wholesale, adding only Claude Code's audit hooks. See
[`../../SPEC/agent-audit.md`](../../SPEC/agent-audit.md) "Where this runs".

## Data streams

Audit records are **agent-cross-cutting**: the AI agent (Claude Code / Codex CLI /
…) is a document field (`agent_audit.agent.*`), not a segment of the data-stream
name. The streams are provisioned by `scripts/setup.sh`:

- `logs-agent_audit.user_prompt-default` — one document per submitted prompt
  (the `UserPromptSubmit` hook).
- `logs-agent_audit.tool_call-default` — one document per completed tool call
  (the `PostToolUse` hook).

Both use **strict** mappings (an unexpected field fails the index rather than
silently growing the audit schema) and a 3-day ILM retention default.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl` and `jq` (used by `setup.sh` and the verify scripts).
- Claude Code (`claude`), to generate real audit records.

## Quick Tour

The shortest path from clone to "I see Claude prompts in Elasticsearch."

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/claude-code-elastic-audit
docker compose up -d
docker compose ps        # wait until both services report healthy
# edit setup.conf if your endpoints aren't the localhost defaults, then:
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

Kibana is then at <http://localhost:5601>. The two backend services
(`aol-elasticsearch`, `aol-kibana`) are the `elastic-audit` backend — the same
local Elasticsearch as the telemetry stack, **minus APM Server**. `scripts/setup.sh`
runs the post-up bootstrap in one shot — it provisions the Agent Audit data streams
and their strict index templates, registers the `UserPromptSubmit` + `PostToolUse`
hooks in `.claude/settings.local.json`, renders the hook delivery config to
`.claude/agent-audit.conf`, writes the Elasticsearch MCP to `.mcp.json` (all in this
directory), and imports the Agent Audit Kibana **data views** and **saved searches**.
Steps are idempotent / create-if-absent, so re-run it any time. Both scripts read
their endpoints from `setup.conf` at the stack root, or another file you pass
(`setup.sh <config>` / `setup.ps1 -Config <config>`), and fail fast if the file is
missing or a required key is empty rather than assuming localhost. `setup.conf` is
two planes: a **control plane** (`elasticsearch.url`, `kibana.url` — backend +
Elasticsearch MCP) and an **agent data plane** — the audit hook's required
`agent_audit.*` keys (`agent_audit.elasticsearch.url`, `.timeout_ms`, and the four
`agent_audit.capture.{user_prompt,tool_call}.{enabled,content}` posture values; no
fallback to `elasticsearch.url`). The hook's Elasticsearch **API key** is a secret:
it lives only in a gitignored `setup.local.conf` (copy `setup.local.conf.example`);
absent → empty, which is fine for this security-disabled demo backend.

### 2. Point a Claude session at the stack

`scripts/setup.sh` wrote a self-contained Claude home at
`stacks/claude-code-elastic-audit/.claude/` (gitignored) carrying the audit
config — `settings.local.json` (the `UserPromptSubmit` + `PostToolUse` hook
registrations, with each hook command's `--config` pointing at the absolute
`agent-audit.conf` path) and `agent-audit.conf` (the hooks' Elasticsearch delivery
config) — plus a project
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

Then do a little work in the session. Each prompt you submit and each tool call
Claude completes is reshaped into a canonical `agent_audit.*` document and POSTed
(fail-open, short timeout) to the local audit data streams. Lab mode stores the
captured text in **plaintext** for searchability; production-oriented deployments
should use encrypted content and restricted read access.

#### Deploy this audit bundle into your own project (`--target`)

The audit bundle is a self-contained copy — hook entry, shared core, and adapter all
materialized — so you can deploy it into **any** directory (e.g. a real project) to
audit what your everyday work does, against this lab's Elasticsearch:

```sh
scripts/setup-config.sh --scope project --target /path/to/your/project
# PowerShell: scripts/setup-config.ps1 -Scope project -Target C:\path\to\your\project
```

The target gets its own `.claude/hooks/` (entry + core + adapter), with nothing pointing
back into this repo. `project` scope deploys the audit config only and does **not**
register the Elasticsearch MCP, keeping the foreign project's footprint minimal (the
MCP is a `local`-scope convenience). **Caveat:** this captures that project's prompts
and tool I/O into the lab's Elasticsearch — don't point secret-bearing work at it.

### 3. Verify the audit path (optional)

```sh
scripts/verify-agent-audit.sh        # UserPromptSubmit -> user_prompt stream
scripts/verify-tool-call-audit.sh    # PostToolUse      -> tool_call stream
```

Each follows the 3A pattern: **Arrange** brings the stack up and waits for
Elasticsearch health; **Act** feeds a synthetic Claude hook payload through the
**rendered** hook exactly as Claude spawns it (reading the command + `args[]` from
`settings.local.json`, with the delivery config already baked into `--config`);
**Assert** confirms the canonical audit document landed in the right stream;
**Cleanup** deletes the synthetic document. They need `docker` (running daemon),
`curl`, `jq`, and a completed `setup.sh`; they **SKIP** (exit 0) when the daemon is
unreachable or setup has not run. Override the ES endpoint with `ES_URL` (`-EsUrl`
for the `.ps1`).

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
data streams with strict mappings, the fail-open `UserPromptSubmit` + `PostToolUse`
hooks, the Elasticsearch MCP, and the Agent Audit data views + saved searches.
Authored later, with the human:

- **Prompt / tool-I/O sealing** — lab mode stores captured text in plaintext; an
  encrypted mode (null `text`, populated `encrypted_text`) is reserved in the
  schema but not built.

## Layout

```
claude-code-elastic-audit/
├─ docker-compose.yml                     # thin composition: `include:`s the elastic-audit backend component
├─ setup.conf                             # control plane (Elasticsearch / Kibana) + agent data plane (agent_audit.*)
├─ setup.local.conf.example               # template for the gitignored setup.local.conf (audit api_key secret)
├─ README.md                              # this Quick Tour
└─ scripts/
   ├─ setup.sh                            # bootstrap: audit streams + settings.local.json (hooks) + agent-audit.conf + .mcp.json + Kibana import
   ├─ setup.ps1                           # PowerShell mirror of setup.sh
   ├─ verify-agent-audit.sh               # UserPromptSubmit -> user_prompt stream verification
   ├─ verify-agent-audit.ps1              # PowerShell mirror
   ├─ verify-tool-call-audit.sh           # PostToolUse -> tool_call stream verification
   └─ verify-tool-call-audit.ps1          # PowerShell mirror
```

`setup.{sh,ps1}` calls the component bootstrap scripts directly. The
`elastic-audit` backend (`../../components/backends/elastic-audit/`) is a thin
`include:` of the `elasticsearch` / `kibana` service fragments plus a composition
script that selects its assets — it owns no asset files. The service fragments
under `../../components/backends/services/` own the service definitions and
config, the asset libraries (the Agent Audit data-stream index templates under
`elasticsearch/index-templates/`; the Agent Audit data views and saved searches
under `kibana/agent-audit/`), and the generic appliers that load them. The Claude
Code agent component (`../../components/agents/claude-code/`) owns only
agent-runtime config — the audit hooks (`hooks/capture-user-prompt.{sh,ps1}`,
`hooks/capture-tool-call.{sh,ps1}`), the hook delivery-config template, and the
render scripts (`render-hook`, `render-agent-audit`, `render-mcp`). `scripts/setup.sh`
registers the hooks in this directory's gitignored `.claude/settings.local.json`,
renders the delivery
config into `.claude/agent-audit.conf`, writes `.mcp.json`, provisions the audit
data streams, and imports those Kibana objects.
```
