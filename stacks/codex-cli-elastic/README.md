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

> 🚧 **Skeleton — agent not yet wired.** This stack stands up the composition and
> proves the **agent-independent OTLP path** (agent → APM Server → Elasticsearch)
> with the synthetic smoke test below. **Pointing a Codex CLI session at the
> stack** (its `OTEL_*` telemetry config) and the **Codex-specific Kibana views**
> (data views, saved searches, dashboards) are deliberately deferred to later
> increments — they depend on a live characterization of what Codex CLI actually
> emits. So there is intentionally **no `setup.{sh,ps1}`, no `config.toml`, and no
> Kibana NDJSON** here yet. See [What's not wired yet](#whats-not-wired-yet).

> ⚠️ **Demo posture only.** Single node, security disabled, ports bound to
> `127.0.0.1`. Never expose this publicly. Once a session is wired in a later
> increment, the events/traces channels can capture prompt text and tool I/O —
> don't run a telemetry-enabled session containing secrets against this stack, and
> never commit captured telemetry into the repo.

> ⚠️ **Cannot run alongside the other Elastic stacks.** This stack reuses the
> Elastic backend's fixed `aol-*` container names and host ports (`9200` /
> `5601` / `8200`), so it **cannot run at the same time** as `claude-code-elastic`
> or `claude-code-otelcol-elastic`. `docker compose down` the other stack before
> bringing this one up.

## Naming

`codex-cli` mirrors the `service.name: codex-cli` that Codex CLI emits (as
`claude-code` does its own) and disambiguates from Codex cloud / the IDE
extension / the legacy Codex model. Later increments use the trace namespace
`agents_codex_cli` (data stream `traces-apm-agents_codex_cli`) and the
per-service data streams `*-apm.app.codex_cli-default`, matching the per-agent
isolation already used for Claude Code.

## Prerequisites

- Docker with a running daemon (`docker compose`).
- `curl`, `jq`, and `base64` (used by the smoke test).

## Quick Tour

The shortest path from clone to "the OTLP pipeline works for this stack."

### 1. Bring the stack up

```sh
cd stacks/codex-cli-elastic
docker compose up -d
docker compose ps        # wait until all three services report healthy
```

Kibana is then at <http://localhost:5601>. The three backend services
(`aol-elasticsearch`, `aol-kibana`, `aol-apm-server`) are the same Elastic
backend the other stacks compose.

### 2. Verify the OTLP path

```sh
scripts/smoke-test.sh    # from anywhere — it locates its own stack directory
```

`scripts/smoke-test.sh` checks the full **OTLP → APM Server → Elasticsearch** path
end to end, following the 3A pattern: **Arrange** brings the stack up and waits
for health; **Act** POSTs a synthetic OTLP/protobuf metrics + logs + traces probe
(tagged `service.name = aol-smoke-test`) to the OTLP/HTTP endpoint on `:8200`;
**Assert** confirms the docs landed in the APM data streams, then prints the
`service.name` values present. The probe is **agent-independent**, so it proves
the shared path any agent will use without a configured agent. It needs `docker`
(running daemon), `curl`, `jq`, `base64`; it **SKIPs** (exit 0) when the daemon
is unreachable. Override endpoints with `ES_URL` / `APM_OTLP_URL`.

### 3. Tear down

```sh
docker compose down        # keep the Elasticsearch volume
docker compose down -v     # also wipe ingested telemetry
```

## What's not wired yet

This is the first increment for Codex CLI. Authored later, with the human, once
Codex's emitted telemetry is characterized live:

- **Pointing a Codex CLI session at the stack** — the `OTEL_*` exporter config
  (`config.toml` and/or environment) that makes `codex` export to `:8200`, plus
  the content-exposure caveats. (For Claude Code this is the `claude-code-elastic`
  README's "Point a session at the stack" step.)
- **Codex-specific Kibana assets** — data views, curated saved searches, and a
  dashboard scoped to Codex's `*-apm.app.codex_cli-default` and
  `traces-apm-agents_codex_cli` streams, with their own import script — modelled
  on `components/agents/claude-code/kibana/`.
- **Trace isolation** — the backend's `traces-apm@custom` reroute pipeline already
  routes `service.name: codex-cli` spans to `traces-apm-agents_codex_cli`, so
  Codex traces will land isolated as soon as a session emits them.

## Layout

```
codex-cli-elastic/
├─ docker-compose.yml                     # thin composition: `include:`s the Elastic backend component
└─ scripts/
   └─ smoke-test.sh                       # agent-independent OTLP-path verification (stack property)
```

The backend services, their config, the Kibana NDJSON, and the bootstrap scripts
all live in `../../components/backends/elastic/`. The Codex CLI agent component
(`components/agents/codex-cli/`) does not exist yet — it arrives with the
session-config and Kibana-asset increments above.
