# codex-elastic

> OpenAI **Codex CLI** → APM Server (Elastic-native OTLP) → Elasticsearch → Kibana.
> The second agent on the shared Elastic backend, alongside
> [`claude-elastic`](../claude-elastic/).

```
Codex CLI  ──OTLP/HTTP (+gRPC)──▶  APM Server  ──▶  Elasticsearch  ──▶  Kibana
(metrics + events + traces)        :8200            :9200                :5601
```

**APM Server** is the OTLP receiver — Elastic's native, fully-supported way to ingest
OpenTelemetry straight into Elasticsearch; Codex CLI points at it directly.

> 🚧 **Session wired; data views + curated saved searches in.** This stack stands up the
> composition, proves the OTLP path with the synthetic smoke test, points a real Codex CLI
> session at it, and ships the Codex data views, curated saved searches, and the
> cross-agent Adoption Overview dashboard. A **per-agent overview dashboard, ingest
> filtering, and normalized summary indices** remain deferred — see
> [What's deferred](#whats-deferred). For prompt / tool-call **audit**, see the sibling
> [`codex-elastic-audit`](../codex-elastic-audit/) stack.

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to `127.0.0.1`.
> Never expose this publicly. The events/traces channels can capture tool I/O (and prompt
> text if you flip `log_user_prompt = true`) — don't run a telemetry-enabled session
> containing secrets against this stack, and never commit captured telemetry into the repo.

> ⚠️ **Cannot run alongside the other Elastic stacks.** Reuses the fixed `aol-*` container
> names and host ports (`9200` / `5601` / `8200`). `docker compose down` the other stack
> first.

**Naming.** `codex` is the lab's human-facing name for the OpenAI Codex agent (as
`claude` is its own), disambiguating from Codex cloud / the IDE extension / the
legacy Codex model. The emitted `service.name` is **`codex_cli_rs`** (the Rust CLI), so Codex
traces are isolated into the per-agent data stream `traces-apm-agents_codex_cli_rs` (routed
by `setup.sh`), and its metrics/events land in `*-apm.app.codex_cli_rs-default` — matching
the per-agent isolation used for Claude Code.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl`, `jq`, and `base64` (used by the smoke test and `setup.sh`).
- Codex CLI (`codex`), to generate real telemetry. `metrics_exporter` is a recent addition
  — check `codex --version` if metrics don't appear (older builds hardwire metrics to
  Statsig).

## Quick Tour

The shortest path from clone to "I see Codex CLI telemetry in Elasticsearch."

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/codex-elastic
docker compose up -d
docker compose ps        # wait until all three services report healthy
# edit agent-config.toml if your endpoints aren't the localhost defaults, then:
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

Kibana is then at <http://localhost:5601>. The three backend services
(`aol-elasticsearch`, `aol-kibana`, `aol-apm-server`) are the same Elastic backend the
other stacks compose. `scripts/setup.sh` runs the post-up bootstrap in one shot — loads the
Elasticsearch assets (the APM `@custom` routers, the ingest pipelines that isolate Codex
spans into `traces-apm-agents_codex_cli_rs`, the per-agent ILM/templates), renders a Codex
`[otel]` config to `.codex/config.toml` in this directory (pointed at the `:8200` APM Server
OTLP endpoint) and links your `~/.codex/auth.json` into it, and imports the Codex Kibana
**data views** (Metrics / Events / Traces) and **saved searches**. Steps are idempotent /
create-if-absent, so re-run it any time. The config is split by reader: the backend
control plane (targets, per-stack groups, dependency edges) lives in the shared espalier
project at `../../components/backends/espalier.toml` — `scripts/provision.{sh,ps1}` just
runs `espalier apply --group codex-elastic` in the stack's compose network — and the
`agent-config` CLI reads the agent data plane (the APM OTLP `endpoint` under
`[telemetry.apm_server]`) from the TOML `agent-config.toml`, failing fast if a file is
missing or a key is empty rather than assuming localhost.

The demo APM Server has auth disabled, so no OTLP credential is needed. For a **secured**
endpoint, copy `agent-config.local.toml.example` to the gitignored `agent-config.local.toml`
(beside `agent-config.toml`; the `--local-conf <file>` CLI flag can point elsewhere) and set
`api_key` under `[telemetry.apm_server]` — `setup.sh` then adds `Authorization: ApiKey <key>`
to the agent's OTLP exports. Absent/empty ships no credential.

### 2. Point a Codex session at the stack

`scripts/setup.sh` (step 1) wrote a self-contained Codex home at
`stacks/codex-elastic/.codex/` (gitignored) whose `config.toml` carries the `[otel]`
telemetry block. Launch Codex with **`CODEX_HOME`** pointed at it:

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

For a **one-shot** run, add `exec` (same `CODEX_HOME`): `CODEX_HOME="$PWD/.codex" codex exec "list the files here"` — telemetry still flushes on exit.

Why `CODEX_HOME` and not a repo-local config: **Codex ignores `[otel]` keys in a
project-local `.codex/config.toml`** (telemetry is honoured only as *user-level* config) and
prints a startup warning. `CODEX_HOME=<dir>` relocates Codex's whole home so
`<dir>/config.toml` *is* the user-level config — the supported, non-invasive way to keep
telemetry config per-project without editing your real `~/.codex`.

> **Credentials under the relocated `CODEX_HOME`.** Because `CODEX_HOME` relocates the
> entire Codex home, Codex won't see your existing `~/.codex` login on its own.
> `local`-scope setup links your `~/.codex/auth.json` into this `.codex/` for you (symlink,
> or a copy with a staleness note) — so a normal `scripts/setup.sh` run leaves you logged
> in. If the link is absent (no source login), just `codex login` once under this
> `CODEX_HOME`. Everything Codex writes here — credentials, history, state — stays in the
> gitignored `.codex/`.

The rendered config sets `log_user_prompt = false` (prompt text is **not** logged) and
sends logs / traces / metrics to the APM Server (the `metrics_exporter` is set explicitly,
overriding Codex's default Statsig metrics destination). To register telemetry **globally**
instead, copy the `[otel]` block from `.codex/config.toml` into your own
`~/.codex/config.toml`. Then do a little work in the session; telemetry lands under
`service.name: codex_cli_rs`.

> **Entrypoint matters.** Interactive `codex` emits telemetry; at the time of writing
> `codex exec` emits no metrics and `codex mcp-server` emits none — use the interactive REPL
> to see signals flow.

> **Prompt / tool-call audit is a separate stack.** Capturing what a session did via
> fail-open hooks that write straight to Elasticsearch is the **audit** concern — it lives
> in the sibling [`codex-elastic-audit`](../codex-elastic-audit/) stack
> (Elasticsearch + Kibana, no APM Server). See [`../../SPEC/agent-audit.md`](../../SPEC/agent-audit.md).

#### Org enforcement via managed config (opt-in)

`CODEX_HOME` and a user `config.toml` are **user-level**; the way an administrator pushes
config onto a fleet is Codex's machine-global, highest-precedence managed layer. This stack
can place those files for you — **opt-in, always interactive, never destructive**. Two files
with **different power**:

| File | Power | Pins | Path (Linux/macOS · Windows) |
| --- | --- | --- | --- |
| `requirements.toml` | **ENFORCED** — a conflicting user value is dropped to a compatible one and the user is told | managed audit hooks (`allow_managed_hooks_only`, `[features].hooks = true`) + allowed sandbox / approval policies | `/etc/codex/requirements.toml` · `%ProgramData%\OpenAI\Codex\requirements.toml` (the only enforceable local layer) |
| `managed_config.toml` | managed **default**, *not* enforced — `[otel]` applies at launch but a user can change it in-session (reverts next start). **Codex cannot enforce `[otel]`** (unlike Claude's managed settings) | the `[otel]` telemetry block | `/etc/codex/managed_config.toml` · `~/.codex/managed_config.toml` (user-writable — a weak boundary) |

Placement **refuses to overwrite any file the lab did not place** (tracked by a sidecar
`.managed` marker — the path may already hold your real org's MDM-pushed config) and prompts
before writing. There is **no `--yes`**; a non-interactive shell aborts having changed
nothing, and permission errors fail loud with the privileged command to run by hand.

The managed audit hooks run the `agent-audit.{sh,ps1}` scripts from `managed_dir` with
`--config <managed_dir>/agent-audit.conf`. Codex validates that `managed_dir` exists but does
**not** distribute its contents — **delivering them is the operator's job**, which the
staged opt-in below has the CLI do for you.

Place it via `setup.sh --scope managed` (runs after the normal setup steps) or directly via
the `agent-config` CLI (requires a Rust toolchain; `cargo run` builds on first use):

```sh
cargo run -q --manifest-path ../../agent-config/Cargo.toml -- place --agent codex --config agent-config.toml --scope managed
```

**Staged opt-in — materialize the hooks into `managed_dir`.** Off by default: this stack's
`agent-config.toml` declares telemetry only, so managed placement writes `managed_config.toml` and
no `requirements.toml` (no hooks are pinned). Placing from a config that carries
`agent_audit.*` keys (as the sibling [`codex-elastic-audit`](../codex-elastic-audit/)
stack's does) **materializes**
the full bundle — scripts + shared core + adapter + a rendered `agent-audit.conf` — into the
host `managed_dir` — an owner-scoped `/etc/codex/hooks/agent-observability-lab`, or
`%ProgramData%\OpenAI\Codex\hooks\agent-observability-lab` on Windows — and points
`requirements.toml` there, so the enforced hooks are self-contained on the host, never
referencing this repo. The owner-scoped subdirectory keeps the bundle from colliding with
another distribution of the same tooling on a machine-global root.

> **Host-check gate — do this once before relying on managed hooks.** Confirm on a **real
> host** that the absolute managed hook command actually fires, and record the result. Until
> confirmed, keep managed telemetry-only (place from a config with no `agent_audit.*` keys).

Remove it (restores the host, removes only the lab-placed files + their markers — the CLI
enumerates every candidate target, including a materialized hook bundle, from the config on
its own):

```sh
cargo run -q --manifest-path ../../agent-config/Cargo.toml -- teardown --agent codex --config agent-config.toml --scope managed
```

**Deploy this config into another scope.** The `agent-config` CLI's `place` deploys the
same self-contained Codex `[otel]` bundle to a `(target, scope)`, and its `teardown`
subcommand removes it; details in
[`../../SPEC/config-deployment.md`](../../SPEC/config-deployment.md).

| Scope | `--target` | MCP | Codex auth-link | Interactive | Teardown |
| --- | --- | --- | --- | --- | --- |
| `local` (default) | rejected (stack dir) | yes | yes (links `~/.codex/auth.json`) | no | `teardown --scope local` |
| `project` | required | no | no | no | `teardown --scope project --target <dir>` |
| `managed` | n/a | no | no | yes | `teardown --scope managed` |

```sh
cargo run -q --manifest-path ../../agent-config/Cargo.toml -- place --agent codex --config agent-config.toml --scope project --target /path/to/your/project
```

`project` scope writes a self-contained `.codex/` into that directory (nothing pointing back
into this repo), deploying the telemetry config **only** — it does **not** register the
Elasticsearch MCP, keeping the foreign project's footprint minimal (the MCP is a
`local`-scope convenience). **Caveat:** this flows that project's prompts and tool I/O into
the lab's Elasticsearch — don't point secret-bearing work at it.

### 3. Verify the OTLP path (optional)

See [Verify the pipeline](#verify-the-pipeline) below.

### 4. See the telemetry

The Kibana saved objects — data views and curated saved searches for **both** agents,
plus the cross-agent **Agents — Adoption Overview** dashboard — are imported by
`scripts/setup.sh` (step 1). Open Discover, pick a data view from the selector or open a
saved search from the Open menu. The Adoption Overview dashboard places Codex (left) and
Claude (right) side by side; only Codex feeds data in this stack, so the Claude half shows
no results — expected, not a fault. (A per-agent overview dashboard is still deferred —
see [What's deferred](#whats-deferred); the Traces view and traces-based searches stay
empty until a Codex session emits spans after trace routing is installed.)

You can also look directly with a query:

```sh
# what service names have landed in the APM event stream
curl -s 'http://localhost:9200/logs-apm*/_search' \
  -H 'Content-Type: application/json' \
  -d '{"size":0,"aggs":{"svc":{"terms":{"field":"service.name"}}}}' | jq '.aggregations.svc.buckets'
```

The **APM UI** (<http://localhost:5601/app/apm>) also lists `codex_cli_rs` as a service once
telemetry arrives.

### 5. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe ingested telemetry
```

## Verify the pipeline

```sh
scripts/smoke-test.sh    # from anywhere — it locates its own stack directory
```

`scripts/smoke-test.sh` checks the full **OTLP → APM Server → Elasticsearch** path end to
end, following the 3A pattern: **Arrange** brings the stack up and waits for health; **Act**
POSTs a synthetic OTLP/protobuf metrics + logs + traces probe (tagged
`service.name = aol-smoke-test`) to the OTLP/HTTP endpoint on `:8200`; **Assert** confirms
the docs landed in the APM data streams. The probe is **agent-independent** — it proves the
shared path without needing a configured Codex session. Needs `docker` (running daemon),
`curl`, `jq`, `base64`; it **SKIPs** (exit 0) when the daemon is unreachable. Override
endpoints with `ES_URL` / `APM_OTLP_URL`.

> **The probe writes into the stack and is not cleaned up.** The metrics/logs documents
> create `*_aol_smoke_test-default` data streams that stay visible in Kibana, and the
> trace span lands in the shared `traces-apm-default` stream next to real agent traces.
> Don't run it against an environment you are inspecting by hand; `docker compose down -v`
> is the reset.

## Data streams & assets

| Asset | Where | Notes |
| --- | --- | --- |
| `metrics-apm.app.codex_cli_rs-default` / `logs-apm.app.codex_cli_rs-default` | per-service data streams | emitted `service.name` is `codex_cli_rs` |
| `traces-apm-agents_codex_cli_rs` | per-agent trace data stream | spans isolated by the ingest pipelines |
| Data views | Codex — Metrics / Events / Traces | imported by `setup.sh` |
| Saved searches | curated Codex searches | exclude the per-delta `codex.websocket_event` wrappers at query time |
| APM service | `codex_cli_rs` | listed once telemetry arrives |

## What's deferred

Wired now: the composition, the OTLP-path smoke test, trace isolation, a real Codex
session's `[otel]` telemetry config, the three Codex **data views** (Metrics / Events /
Traces), and the curated Codex saved searches — all loaded by the shared Kibana importer,
modelled on `components/backends/services/kibana/claude/`. (Prompt / tool-call **audit**
is the sibling [`codex-elastic-audit`](../codex-elastic-audit/) stack.) Authored
later, with the human:

- **An overview dashboard** — a Lens dashboard over the Codex data views, the way Claude
  Code's Overview dashboard sits on its views.
- **Ingest filtering** — drop rules for the high-volume per-delta `codex.websocket_event`
  wrappers (the saved searches exclude them at query time) so they don't bloat the events
  stream.
- **Normalized summary indices** — pre-aggregated per-turn / per-conversation rollups so the
  Conversations and Turns ES|QL views can be served from a compact index rather than
  recomputed over the raw streams.

## Layout

```
codex-elastic/
├─ docker-compose.yml                     # thin composition: `include:`s the Elastic backend component
├─ agent-config.toml                      # agent data plane the agent-config CLI reads: [telemetry.apm_server] endpoint (APM OTLP)
├─ agent-config.local.toml.example        # template for the gitignored agent-config.local.toml (optional [telemetry.apm_server] api_key)
└─ scripts/
   ├─ setup.sh / setup.ps1               # one-shot bootstrap = provision then agent-config place
   ├─ provision.sh / .ps1                # espalier apply --group codex-elastic (docker, in-network)
   ├─ provision-standalone.sh / .ps1     # generated by espalier render-script: curl-only, payloads embedded
   └─ smoke-test.sh                       # agent-independent OTLP-path verification (stack property)
```

`setup.{sh,ps1}` composes the two halves: the `provision` façade script, then the
`agent-config` CLI's `place` (`cargo run` against `../../agent-config/`).
The `elastic` backend
(`../../components/backends/elastic/`) is a thin `include:` of the `elasticsearch` / `kibana`
/ `apm-server` service fragments plus a composition script that selects its assets — it owns
no asset files. The service fragments under `../../components/backends/services/` own the
service definitions and config, the asset libraries (the `traces-apm@custom` /
`logs-apm.app@custom` ingest pipelines under `elasticsearch/`; the Codex data views and saved
searches under `kibana/codex/` — `data-views.ndjson`, `saved-searches.ndjson`), and the
generic appliers. The Codex agent component (`../../components/agents/codex/`) owns
only agent-runtime config — the `[otel]` config template; `setup.sh` (via the
`agent-config` CLI) renders it into this directory's gitignored `.codex/config.toml` and
imports the Codex Kibana objects. (The direct Agent Audit path — hooks writing straight to
Elasticsearch — is the sibling `codex-elastic-audit` stack.)
