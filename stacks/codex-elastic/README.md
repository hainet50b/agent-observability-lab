# codex-elastic

> OpenAI **Codex CLI** → APM Server (Elastic-native OTLP) → Elasticsearch → Kibana.
> The second agent on the shared Elastic backend, alongside
> [`claude-elastic`](../claude-elastic/).

```
Codex CLI  ──OTLP/HTTP (+gRPC)──▶  APM Server  ──▶  Elasticsearch  ──▶  Kibana
(metrics + events + traces)        :8200            :9200                :5601
```

**APM Server** is the OTLP receiver — Elastic's native, fully-supported way to ingest
OpenTelemetry straight into Elasticsearch. Codex CLI points at it directly rather than
through an OpenTelemetry Collector (a Collector variant would be a separate stack,
mirroring [`claude-otelcol-elastic`](../claude-otelcol-elastic/)).

> 🚧 **Session wired; data views + curated saved searches in.** This stack stands up the
> composition, proves the OTLP path with the synthetic smoke test, points a real Codex CLI
> session at it, and ships the Codex data views plus curated saved searches. A
> **dashboard, ingest filtering, and normalized summary indices** remain deferred — see
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
# edit setup.conf if your endpoints aren't the localhost defaults, then:
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
create-if-absent, so re-run it any time. Both scripts read their target endpoints
(Elasticsearch, the APM OTLP endpoint, Kibana) from `setup.conf` at the stack root, or
another file you pass (`setup.sh <config>` / `setup.ps1 -Config <config>`); they fail fast
if the file is missing or a key is empty rather than assuming localhost.

The demo APM Server has auth disabled, so no OTLP credential is needed. For a **secured**
endpoint, copy `setup.local.conf.example` to the gitignored `setup.local.conf` and set
`telemetry.apm_server.api_key=<key>` — `setup.sh` then adds `Authorization: ApiKey <key>`
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
| `managed_config.toml` | managed **default**, *not* enforced — `[otel]` applies at launch but a user can change it in-session (reverts next start). **Codex cannot enforce `[otel]`** (unlike Claude's `managed-settings.json`) | the `[otel]` telemetry block | `/etc/codex/managed_config.toml` · `~/.codex/managed_config.toml` (user-writable — a weak boundary) |

Placement **refuses to overwrite any file the lab did not place** (tracked by a sidecar
`.managed` marker — the path may already hold your real org's MDM-pushed config) and prompts
before writing. There is **no `--yes`**; a non-interactive shell aborts having changed
nothing, and permission errors fail loud with the privileged command to run by hand.

The managed audit hooks run the `agent-audit.{sh,ps1}` scripts from `managed_dir` (the lab
points it at its repo `components/agents/codex/hooks/`) with
`--config <managed_dir>/agent-audit.conf`. Codex validates that `managed_dir` exists but does
**not** distribute its contents — **delivering them is the operator's job**. The lab ships
the two scripts there but **not** an `agent-audit.conf` (that file carries the Elasticsearch
URL and is rendered per-deployment by `render-agent-audit.sh`). So for the enforced hook to
find its config you must render an `agent-audit.conf` and place it beside the scripts in
`managed_dir`; without it the audit hook fails open with no config. (The `--with-hooks`
staged opt-in below removes this caveat.)

Place it via `setup.sh --scope managed` (runs after the normal setup steps) or directly:

```sh
../../components/agents/codex/scripts/setup-managed.sh \
  --logs-endpoint http://localhost:8200/v1/logs \
  --traces-endpoint http://localhost:8200/v1/traces \
  --metrics-endpoint http://localhost:8200/v1/metrics
```

```powershell
..\..\components\agents\codex\scripts\setup-managed.ps1 `
  -LogsEndpoint http://localhost:8200/v1/logs `
  -TracesEndpoint http://localhost:8200/v1/traces `
  -MetricsEndpoint http://localhost:8200/v1/metrics
```

**Staged opt-in — materialize the hooks into `managed_dir` (`--with-hooks`).** By default
`requirements.toml` points `managed_dir` at this repo's `components/agents/codex/hooks/`
(demo — you must hand-place an `agent-audit.conf` there, as noted above). Adding
`--with-hooks --es-url <es>` (sh) / `-WithHooks -EsUrl <es>` (ps1) instead **materializes**
the full bundle — scripts + shared core + adapter + a rendered `agent-audit.conf` — into the
host `managed_dir` (`/etc/codex/hooks`, or `%ProgramData%\OpenAI\Codex\hooks` on Windows) and
points `requirements.toml` there, so the enforced hooks are self-contained and the conf
caveat no longer applies.

> **Host-check gate — do this once before relying on `--with-hooks`.** Confirm on a **real
> host** that the absolute managed hook command actually fires, and record the result. Until
> confirmed, leave `--with-hooks` off.

Remove it (restores the host, removes only the lab-placed files + their markers; add
`--with-hooks` / `-WithHooks` to also remove a materialized hook bundle) — either
`setup-config.sh --scope managed --teardown [--with-hooks]` (the `-Teardown` / `-WithHooks`
switches on `.ps1`) or directly:

```sh
../../components/agents/codex/scripts/teardown-managed.sh
```

```powershell
..\..\components\agents\codex\scripts\teardown-managed.ps1
```

**Deploy this config into another scope.** `setup-config` deploys the same self-contained
Codex `[otel]` bundle to a `(target, scope)`; details in
[`../../SPEC/config-deployment.md`](../../SPEC/config-deployment.md).

| Scope | `--target` | MCP | Codex auth-link | Interactive | Teardown |
| --- | --- | --- | --- | --- | --- |
| `local` (default) | rejected (stack dir) | yes | yes (links `~/.codex/auth.json`) | no | `--scope local --teardown` |
| `project` | required | no | no | no | `--scope project --target <dir> --teardown` |
| `managed` | n/a | no | no | yes | `--scope managed --teardown [--with-hooks]` |

```sh
scripts/setup-config.sh --scope project --target /path/to/your/project
# PowerShell: scripts/setup-config.ps1 -Scope project -Target C:\path\to\your\project
```

`project` scope writes a self-contained `.codex/` into that directory (nothing pointing back
into this repo), deploying the telemetry config **only** — it does **not** register the
Elasticsearch MCP, keeping the foreign project's footprint minimal (the MCP is a
`local`-scope convenience). **Caveat:** this flows that project's prompts and tool I/O into
the lab's Elasticsearch — don't point secret-bearing work at it.

### 3. Verify the OTLP path (optional)

See [Verify the pipeline](#verify-the-pipeline) below.

### 4. See the telemetry

The Codex **data views** — **Codex — Metrics**, **Codex — Events**, and **Codex —
Traces** — plus the curated saved searches are imported by `scripts/setup.sh` (step 1).
Open Discover, pick a data view from the selector or open a saved search from the Open menu.
(A dashboard is still deferred — see [What's deferred](#whats-deferred); the Traces view and
traces-based searches stay empty until a Codex session emits spans after trace routing is
installed.)

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
├─ setup.conf                             # endpoints setup.{sh,ps1} target: elasticsearch.url / kibana.url + telemetry.apm_server.endpoint (APM OTLP)
├─ setup.local.conf.example               # template for the gitignored setup.local.conf (optional telemetry.apm_server.api_key)
└─ scripts/
   ├─ setup.sh / setup.ps1               # one-shot bootstrap = setup-backend then setup-config
   ├─ setup-backend.sh / .ps1            # wait for health, load ES + Kibana assets
   ├─ setup-config.sh / .ps1             # render the [otel] config + link auth.json (--scope local|project|managed)
   └─ smoke-test.sh                       # agent-independent OTLP-path verification (stack property)
```

`setup.{sh,ps1}` composes the two halves (`setup-backend` then `setup-config`), each calling
the component façade scripts directly. The `elastic` backend
(`../../components/backends/elastic/`) is a thin `include:` of the `elasticsearch` / `kibana`
/ `apm-server` service fragments plus a composition script that selects its assets — it owns
no asset files. The service fragments under `../../components/backends/services/` own the
service definitions and config, the asset libraries (the `traces-apm@custom` /
`logs-apm.app@custom` ingest pipelines under `elasticsearch/`; the Codex data views and saved
searches under `kibana/codex/` — `data-views.ndjson`, `saved-searches.ndjson`), and the
generic appliers. The Codex agent component (`../../components/agents/codex/`) owns
only agent-runtime config — the `[otel]` config template and render scripts; `setup.sh`
renders the telemetry template into this directory's gitignored `.codex/config.toml` and
imports the Codex Kibana objects. (The direct Agent Audit path — hooks writing straight to
Elasticsearch — is the sibling `codex-elastic-audit` stack.)
