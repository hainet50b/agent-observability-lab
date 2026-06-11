# codex-cli-elastic

> OpenAI **Codex CLI** → APM Server (Elastic-native OTLP) → Elasticsearch →
> Kibana. The second agent on the shared Elastic backend, alongside
> `claude-code-elastic`.

```
Codex CLI  ──OTLP/HTTP (+gRPC)──▶  APM Server  ──▶  Elasticsearch  ──▶  Kibana
(metrics + events + traces)        :8200            :9200                :5601
```

**APM Server** is the OTLP receiver here — Elastic's native, fully-supported way
to ingest OpenTelemetry straight into Elasticsearch. Codex CLI points at it
directly rather than through an OpenTelemetry Collector (a Collector-based
variant would be a separate stack, mirroring `claude-code-otelcol-elastic`).

> 🚧 **Session wired; data views + curated saved searches in.** This stack stands
> up the composition, proves the OTLP path with the synthetic smoke test, points a
> real Codex CLI session at it, **and** ships the three Codex data views plus four
> curated ES|QL saved searches (Conversations, Turns, Turn Timeline (Traces), and
> the deprecated Turn Timeline (Events)): `scripts/setup.sh` installs trace
> routing, renders a Codex `[otel]` telemetry config (see
> [Point a Codex session](#2-point-a-codex-session-at-the-stack)), and imports the
> Kibana data views (Metrics / Events / Traces) and saved searches. A **dashboard,
> ingest filtering, TTFT integration, and normalized summary indices** remain
> deferred. See [What's deferred](#whats-deferred).

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. The events/traces channels can capture
> tool I/O (and prompt text if you flip `log_user_prompt = true`) — don't run a
> telemetry-enabled session containing secrets against this stack, and never
> commit captured telemetry into the repo.

> ⚠️ **Cannot run alongside the other Elastic stacks.** This stack reuses the
> Elastic backend's fixed `aol-*` container names and host ports (`9200` /
> `5601` / `8200`), so it **cannot run at the same time** as `claude-code-elastic`
> or `claude-code-otelcol-elastic`. `docker compose down` the other stack before
> bringing this one up.

## Naming

`codex-cli` mirrors the `service.name: codex-cli` that Codex CLI emits (as
`claude-code` does its own) and disambiguates from Codex cloud / the IDE
extension / the legacy Codex model. Codex traces are isolated into the per-agent
data stream `traces-apm-agents_codex_cli` (routed by `scripts/setup.sh`, step 1),
and its metrics/events land in the per-service data streams
`*-apm.app.codex_cli-default` — matching the per-agent isolation already used for
Claude Code.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl`, `jq`, and `base64` (used by the smoke test and `setup.sh`).
- Codex CLI (`codex`), to generate real telemetry. `metrics_exporter` is a recent
  addition — check `codex --version` if metrics don't appear (older builds hardwire
  metrics to Statsig).

## Quick Tour

The shortest path from clone to "I see Codex CLI telemetry in Elasticsearch."

### 1. Bring the stack up and bootstrap it

```sh
cd stacks/codex-cli-elastic
docker compose up -d
docker compose ps        # wait until all three services report healthy
scripts/setup.sh         # bash/zsh/sh  (or ./setup.ps1 on Windows)
```

Kibana is then at <http://localhost:5601>. The three backend services
(`aol-elasticsearch`, `aol-kibana`, `aol-apm-server`) are the same Elastic
backend the other stacks compose. `scripts/setup.sh` runs the post-up bootstrap
in one shot — it installs the trace-routing ingest pipeline (isolates Codex's
spans into a dedicated per-agent trace stream), renders a Codex `[otel]` config
to `.codex/config.toml` in this directory (pointed at the APM Server OTLP
endpoint on `:8200`), and imports the Codex Kibana **data views** (Metrics /
Events / Traces) and **saved searches**, plus the shared cross-agent **AI Agents —
Traces** view. Steps are idempotent / create-if-absent, so re-run it any time.
Override the ES endpoint with `ES_URL` (`-EsUrl` for the `.ps1`) and the Kibana
URL with `KIBANA_URL`.

### 2. Point a Codex session at the stack

`scripts/setup.sh` (Quick Tour step 1 above) wrote a self-contained Codex home at
`stacks/codex-cli-elastic/.codex/` (gitignored) whose `config.toml` carries the
`[otel]` telemetry block. Launch Codex with **`CODEX_HOME`** pointed at it:

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

Why `CODEX_HOME` and not a repo-local config: **Codex ignores `[otel]` keys in a
project-local `.codex/config.toml`** (telemetry is honoured only as *user-level*
config) and prints a startup warning. `CODEX_HOME=<dir>` relocates Codex's whole
home so `<dir>/config.toml` *is* the user-level config — the supported,
non-invasive way to keep telemetry config per-project without editing your real
`~/.codex`.

> **First run under a fresh `CODEX_HOME` has no credentials.** Because
> `CODEX_HOME` relocates the entire Codex home, Codex won't see your existing
> `~/.codex` login. Either `codex login` once under this `CODEX_HOME`, or copy
> your `~/.codex/auth.json` into `stacks/codex-cli-elastic/.codex/`. (Everything
> Codex writes here — credentials, history, state — stays in the gitignored
> `.codex/`.)

The rendered config sets `log_user_prompt = false` (prompt text is **not**
logged) and sends logs / traces / metrics to the APM Server (the `metrics_exporter`
is set explicitly, overriding Codex's default Statsig metrics destination). To
register telemetry **globally** instead, copy the `[otel]` block from
`.codex/config.toml` into your own `~/.codex/config.toml`. Then do a little work
in the session; telemetry lands in Elasticsearch under `service.name: codex-cli`.

> **Entrypoint matters.** Interactive `codex` emits telemetry; at the time of
> writing `codex exec` emits no metrics and `codex mcp-server` emits none — so use
> the interactive REPL to see signals flow.

### 3. Verify the OTLP path (optional)

```sh
scripts/smoke-test.sh    # from anywhere — it locates its own stack directory
```

`scripts/smoke-test.sh` checks the full **OTLP → APM Server → Elasticsearch** path
end to end, following the 3A pattern: **Arrange** brings the stack up and waits
for health; **Act** POSTs a synthetic OTLP/protobuf metrics + logs + traces probe
(tagged `service.name = aol-smoke-test`) to the OTLP/HTTP endpoint on `:8200`;
**Assert** confirms the docs landed in the APM data streams. The probe is
**agent-independent** — it proves the shared path without needing a configured
Codex session. It needs `docker` (running daemon), `curl`, `jq`, `base64`; it
**SKIPs** (exit 0) when the daemon is unreachable. Override endpoints with
`ES_URL` / `APM_OTLP_URL`.

### 4. See the telemetry

The three Codex **data views** — **Codex CLI — Metrics**, **Codex CLI — Events**,
and **Codex CLI — Traces** — and four curated ES|QL **saved searches** — **Codex
CLI — Conversations** (logs-based usage summary), **Codex CLI — Turns**
(traces-based turn summary), **Codex CLI — Turn Timeline (Traces)** (the primary
execution timeline), and **Codex CLI — Turn Timeline (Events) (Deprecated)** (its
logs-stream predecessor, kept for reference) — are imported by `scripts/setup.sh`
(Quick Tour step 1). Open Discover, pick a data view from the selector or open a
saved search from the Open menu. (A dashboard is still deferred — see
[What's deferred](#whats-deferred); the Traces view and the traces-based searches
stay empty until a Codex session emits spans after trace routing is installed.)

You can also look directly with a query:

```sh
# what service names have landed in the APM event stream
curl -s 'http://localhost:9200/logs-apm*/_search' \
  -H 'Content-Type: application/json' \
  -d '{"size":0,"aggs":{"svc":{"terms":{"field":"service.name"}}}}' | jq '.aggregations.svc.buckets'
```

The **APM UI** (<http://localhost:5601/app/apm>) also lists `codex-cli` as a
service once telemetry arrives.

### 5. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe ingested telemetry
```

## What's deferred

Wired now: the composition, the OTLP-path smoke test, trace isolation, a real
Codex session's `[otel]` telemetry config, the three Codex **data views**
(Metrics / Events / Traces), and four curated ES|QL **saved searches**
(Conversations, Turns, Turn Timeline (Traces), and the deprecated Turn Timeline
(Events)), all with their own import script — modelled on
`components/agents/claude-code/kibana/`. (The shared cross-agent **AI Agents —
Traces** view, `traces-apm-agents_*`, already includes Codex's spans.) Authored
later, with the human:

- **An overview dashboard** — a Lens dashboard over the Codex data views, the way
  Claude Code's Overview dashboard sits on its views.
- **Ingest filtering** — drop rules for the high-volume per-delta
  `codex.websocket_event` wrappers (the saved searches exclude them at query time)
  so they don't bloat the events stream.
- **TTFT integration** — surfacing time-to-first-token alongside the turn / LLM
  metrics once that signal is characterized.
- **Normalized summary indices** — pre-aggregated per-turn / per-conversation
  rollups so the Conversations and Turns ES|QL views can be served from a compact
  index rather than recomputed over the raw streams.
- **Prompt-audit hook** — the `prompts-audit` index + capture hook are
  Claude-Code-specific (a `UserPromptSubmit` hook). A Codex equivalent, if Codex
  exposes a comparable hook, is a later increment; `setup.sh` deliberately does
  not create the audit store here.

## Layout

```
codex-cli-elastic/
├─ docker-compose.yml                     # thin composition: `include:`s the Elastic backend component
└─ scripts/
   ├─ setup.sh                            # one-shot bootstrap: trace-routing + render .codex/config.toml
   ├─ setup.ps1                           # PowerShell mirror of setup.sh
   └─ smoke-test.sh                       # agent-independent OTLP-path verification (stack property)
```

`setup.{sh,ps1}` calls the component bootstrap scripts directly. The backend
services, their config, the cross-agent data view, the `traces-apm@custom`
pipeline body, and the Backend bootstrap scripts live in
`../../components/backends/elastic/`; the Codex CLI agent's `[otel]` config
template, its render scripts, its Kibana data views and saved searches
(`kibana/data-views.ndjson`, `kibana/saved-searches.ndjson`), and its Kibana
import script (`scripts/import-kibana-objects.{sh,ps1}`) live in
`../../components/agents/codex-cli/`. `scripts/setup.sh` renders that template
into this directory's gitignored `.codex/config.toml` and imports those Kibana
objects.
