# spring-boot caller

A minimal **Spring Boot 4** application that boots the container, **reads the active Micrometer
trace**, launches an agent (`claude` or `codex`) **once** with per-app attribution, and exits with the child's
code. A single `CommandLineRunner` does the whole job; the app is non-web, so the context closes as
soon as the run finishes. It runs Micrometer Tracing but configures **no exporter, so it emits no
telemetry of its own** — see [`../`](../) for the caller concept.

## What it demonstrates

- **Trace join** — opens a Micrometer span and passes its W3C `traceparent` to the agent, so the
  agent's spans become children of that trace. (Sampled at `1.0`, so the traceparent is marked
  sampled and the agent exports its children.)
- **Per-app attribution** — passes `OTEL_RESOURCE_ATTRIBUTES=caller.name=<name>`, which rides every
  agent metric / log / span as `labels.caller_name`. (A single run is identified by its `trace.id`.)

## Prerequisites

- JDK 25 (`java -version`).
- The matching telemetry stack **up** and the agent **logged in** — the caller runs the agent in
  that stack directory so its telemetry config is picked up:
  [`claude-elastic`](../../stacks/claude-elastic/) for `claude` (reads `.claude/settings.local.json`),
  [`codex-elastic`](../../stacks/codex-elastic/) for `codex` (reads `.codex/config.toml` via `CODEX_HOME`).

## Run

```sh
# defaults: caller.name=my-app, prompt "say hi in one word"
./mvnw spring-boot:run                        # .\mvnw.cmd on Windows

# choose the application name / prompt
./mvnw spring-boot:run -Dspring-boot.run.arguments="--caller.name=checkout-svc --caller.prompt=list the files here"
```

It prints the correlators for Elasticsearch:

```
correlate in Elasticsearch by  trace.id=<32hex> (this run)  and  labels.caller_name=<name> (this app)
```

## Verify (Elasticsearch)

```sh
# Claude's spans under the caller's trace
curl -s "http://localhost:9200/traces-apm-agents_claude_code*/_search" -H 'Content-Type: application/json' \
  --data '{"query":{"term":{"trace.id":"<traceId>"}}}'

# every Claude signal tagged with the launching app
curl -s "http://localhost:9200/logs-apm.app.claude_code*/_search" -H 'Content-Type: application/json' \
  --data '{"query":{"term":{"labels.caller_name":"<name>"}}}'
```

(For `codex`, query `traces-apm-agents_codex_*` and `logs-apm.app.codex_*` instead.)

## Configuration (`caller.*`, all overridable at launch)

| Key | Default | Meaning |
| --- | --- | --- |
| `caller.agent` | `claude` | which agent to launch (implemented: `claude`, `codex`) |
| `caller.name` | `my-app` | → `caller.name` attribute (no spaces / `,` / `=`) |
| `caller.prompt` | `say hi in one word` | prompt handed to the agent |
| `caller.command` | *(blank → agent default, e.g. `claude`)* | CLI executable, resolved on PATH |
| `caller.working-dir` | *(blank → agent's default stack dir)* | directory the agent runs in (must hold its telemetry config) |

The launch is **agent-agnostic** — the per-agent bits (argv, working dir, extra env) live in the
`Agent` enum: `claude` (`claude -p`) and `codex` (`codex exec`, plus a `CODEX_HOME` pointing at the
stack's `.codex`) are wired; a further agent is one more enum constant. Whether an agent actually
joins the trace / applies `caller.name` is agent-specific — `claude -p` reads `TRACEPARENT` per its
docs; for `codex` it is best-effort, so verify against the live stream.
