# Agent Observability Lab

A runnable lab for seeing exactly what an AI coding agent emits, and how an
observability backend ingests it. From clone to "I can see what my agent is
doing": one backend, your choice of agent and concern, one workbench.

```mermaid
flowchart LR
  subgraph your machine
    C[Claude Code]
    X[Codex CLI]
  end
  subgraph backends/elastic — docker
    A[APM Server :8200] --> E[(Elasticsearch :9200)]
    E --> K[Kibana :5601]
  end
  C -- OTLP · telemetry --> A
  X -- OTLP · telemetry --> A
  C -- hooks · audit --> E
  X -- hooks · audit --> E
```

Two concerns flow through it:

- **Telemetry** — the agent's OpenTelemetry metrics / events / traces over
  OTLP: sessions, tokens, cost, code edits, prompts, tool results, API
  requests.
- **Audit** — a record of what a session *did* (each prompt, each tool call),
  written straight to Elasticsearch by fail-open agent hooks. No OTLP, no APM.

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. Telemetry events and audit
> documents can carry your prompt text and tool I/O — don't run sessions
> containing secrets against it, and never commit captured data into the repo.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- A Rust toolchain (`cargo` — the `agent-config` CLI builds on first use).
- Claude Code and/or Codex CLI, to generate real signals. (Codex:
  `metrics_exporter` is a recent addition — check `codex --version` if metrics
  don't appear.)
- `curl` for the optional command-line checks.

## 1. Bring the backend up

```sh
docker compose -f backends/elastic/docker-compose.yml up -d
docker compose -f backends/elastic/docker-compose.yml ps   # wait for healthy
backends/elastic/provision.sh                              # .ps1 on Windows
```

Kibana is then at <http://localhost:5601>. `provision` loads every
Elasticsearch and Kibana asset the lab owns — ingest pipelines, ILM,
templates, audit data streams, data views, saved searches, the cross-agent
dashboard — in one idempotent pass. This step is the same whatever you choose
below: assets for agents or concerns you don't exercise just sit idle, and
re-running it any time is safe.

## 2. Make a workbench and wire an agent to the backend

There is nothing exotic about how an agent gets wired: Claude Code and Codex
are configured through **their own native config files** —
`.claude/settings.local.json` for Claude Code, `.codex/config.toml` for Codex
— and "wired to the backend" just means those files carry the right telemetry
destinations and hook registrations. You could write them by hand; the lab
instead ships **`agent-config`**, a small CLI whose whole job is to render
those native config files and put them in place (and later remove exactly
what it placed).

What `agent-config` needs from you is one input: the backend's **connection
file**, [`backends/elastic/agent-config.toml`](backends/elastic/agent-config.toml),
committed beside the backend it describes. This is what it says:

```toml
[telemetry.apm_server]
endpoint = "http://localhost:8200"

[agent_audit.elasticsearch]
url = "http://localhost:9200"
timeout_ms = 2000

[agent_audit.capture.user_prompt]
enabled = true
content = "plaintext"

[agent_audit.capture.tool_call]
enabled = true
content = "plaintext"
```

`[telemetry.*]` is one concern, `[agent_audit.*]` is the other — the file
declares **both**, pointed at the backend you just started. A **workbench** is
any directory holding a copy of it: the copy is that workbench's own config
(edit it to change posture — e.g. `content = "redacted"` to audit without
storing prompt text), and the agent config gets deployed next to it.

```sh
mkdir -p workbench/mine
cp backends/elastic/agent-config.toml workbench/mine/

cargo run -q --manifest-path agent-config/Cargo.toml -- \
  place --agent claude --config workbench/mine/agent-config.toml
```

`place` is where you pick your combination:

- **which agents** — `--agent claude`, `--agent codex`, or both at once:
  `--agent claude,codex`;
- **which concerns** — everything the file declares (both, recommended: you
  can then line a session's audit trail up against its telemetry), or
  narrowed with `--concern telemetry` / `--concern audit`.

What lands (per agent): the settings file (`.claude/settings.local.json` /
`.codex/config.toml`) carrying the telemetry env and/or hook registrations,
the audit hook scripts and their delivery config, and the Elasticsearch MCP
registration. Every placed file gets a `.managed` provenance sidecar naming
this repo as its executor — `place` refuses to touch any file it doesn't own,
and re-running it converges the workbench to the current config. The
counterpart removes exactly what was placed:

```sh
cargo run -q --manifest-path agent-config/Cargo.toml -- \
  teardown --agent claude --config workbench/mine/agent-config.toml
```

For a **secured** backend, put `api_key` values in a gitignored
`agent-config.local.toml` beside the copy.

## 3. Launch the agent from the workbench

Project-scoped agent config loads only from the launch directory, so launch
there:

```sh
# Claude Code
cd workbench/mine && claude
```

```sh
# Codex CLI — relocate its home so the wired config.toml is user-level
cd workbench/mine
CODEX_HOME="$PWD/.codex" codex            # PowerShell: $env:CODEX_HOME = "$PWD\.codex"; codex
```

(Codex: `place` links your `~/.codex/auth.json` into the workbench so you stay
logged in; if absent, `codex login` once under this `CODEX_HOME`.)

> **Entrypoint matters for Codex.** Interactive `codex` emits telemetry; at the
> time of writing `codex exec` emits no metrics and `codex mcp-server` emits
> nothing — use the interactive REPL to see signals flow. The rendered config
> sets `log_user_prompt = false`, so telemetry carries no prompt text; prompt
> capture is the audit concern's job, per your connection-file posture.

Do a little work — ask a question, let it read or edit a file. Telemetry
flushes on its export interval and hooks write per event, so data lands within
~10–30 s.

## 4. See it in Kibana

- **Discover** — pick a data view (`Claude Code — Metrics` / `Events`, the
  Codex equivalents, or `Agent Audit`) and open the curated saved searches
  from the **Open** menu: Event Overview, API Requests, Tool Results, prompt
  and tool-call audit trails.
- **Dashboards** — **Agents — Adoption Overview** shows Codex and Claude side
  by side; each half fills as soon as that agent has emitted. Everything lands
  in one Elasticsearch, so combinations compose — wire both agents and the
  dashboard fills whole.
- **APM UI** (<http://localhost:5601/app/apm>) — telemetry-wired agents
  register as APM services (`claude-code`, `codex_cli_rs`).

Or from the command line:

```sh
curl -s "http://localhost:9200/logs-agent_audit.tool_call-default/_search?size=1&sort=@timestamp:desc" | jq .
```

## 5. Tear down

```sh
cargo run -q --manifest-path agent-config/Cargo.toml -- \
  teardown --agent claude --config workbench/mine/agent-config.toml
rm -rf workbench/mine

docker compose -f backends/elastic/docker-compose.yml down     # keep the data
docker compose -f backends/elastic/docker-compose.yml down -v  # wipe it
```

## Beyond the workbench — the three scopes

The workbench flow above is `place`'s default scope (`local`). The same bundle
deploys to two more scopes:

| Scope | Where it lands | What differs |
| --- | --- | --- |
| `local` (default) | beside the `--config` copy — the workbench | full bundle, including the Elasticsearch MCP |
| `project` | `--target <dir>` — your real project | no MCP; the placed agent home ignores itself so your repo stays clean |
| `managed` | fixed machine-global system paths (below) | org enforcement — highest precedence, interactive placement |

**`project` — wire your real project.** To see what your everyday sessions
would emit:

```sh
cargo run -q --manifest-path agent-config/Cargo.toml -- \
  place --agent claude --config workbench/mine/agent-config.toml --scope project --target /path/to/project
```

Same teardown (with the same `--target`). Remember that project's prompts and
tool I/O then flow into this Elasticsearch.

**`managed` — org-enforced placement. Handle with care: this changes your
machine, not a directory.** The managed tier is how an organization forces
agent config onto a fleet — for Claude Code it can *enforce* telemetry
(highest precedence; the user cannot turn it off or change the endpoint),
while Codex's managed `[otel]` is a default, not enforced. Placement is
opt-in and always interactive (each file confirmed, no `--yes`; a
non-interactive shell aborts having changed nothing), never overwrites a file
it did not place, and has a matching teardown:

```sh
cargo run -q --manifest-path agent-config/Cargo.toml -- \
  place    --agent claude --config workbench/mine/agent-config.toml --scope managed
cargo run -q --manifest-path agent-config/Cargo.toml -- \
  teardown --agent claude --config workbench/mine/agent-config.toml --scope managed
```

The admin-owned roots it writes into (the lab's own files sit beside any
policy your real organization may already deploy there — check the directory
before placing):

| Agent | OS | Managed root |
| --- | --- | --- |
| Claude Code | Linux / WSL | `/etc/claude-code/` |
| Claude Code | macOS | `/Library/Application Support/ClaudeCode/` |
| Claude Code | Windows | `C:\Program Files\ClaudeCode\` |
| Codex | Linux / macOS | `/etc/codex/` |
| Codex | Windows | `C:\ProgramData\OpenAI\Codex\` (defaults additionally at `%USERPROFILE%\.codex\managed_config.toml`) |

Everything the lab places there is named after its executor
(`10-agent-observability-lab.json`, `hooks/agent-observability-lab/`, ...) and
carries a provenance marker, so teardown removes exactly the lab's files and
nothing else.
