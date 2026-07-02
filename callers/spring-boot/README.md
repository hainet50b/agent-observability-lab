# spring-boot caller

A minimal **Spring Boot 4** application that boots the container, **reads the active Micrometer
trace**, launches an agent (`claude`) **once** with per-app attribution, and exits with the child's
code. A single `CommandLineRunner` does the whole job; the app is non-web, so the context closes as
soon as the run finishes. It runs Micrometer Tracing but configures **no exporter, so it emits no
telemetry of its own** — see [`../`](../) for the caller concept.

## What it demonstrates

- **Trace join** — opens a Micrometer span and passes its W3C `traceparent` to the agent, so the
  agent's spans become children of that trace. (Sampled at `1.0`, so the traceparent is marked
  sampled and the agent exports its children.)
- **Per-app attribution** — passes `OTEL_RESOURCE_ATTRIBUTES=app.name=<name>`, which rides every
  Claude metric / log / span as `labels.app_name`. (A single run is identified by its `trace.id`.)

## Prerequisites

- JDK 25 (`java -version`).
- The [`claude-elastic`](../../stacks/claude-elastic/) stack **up** and `claude` **logged in** — the
  caller runs `claude` in that stack directory so its `.claude/settings.local.json` (telemetry env,
  traces beta) is picked up.

## Run

```sh
# defaults: app.name=my-app, prompt "say hi in one word"
./mvnw spring-boot:run                        # .\mvnw.cmd on Windows

# choose the application name / prompt
./mvnw spring-boot:run -Dspring-boot.run.arguments="--caller.app-name=checkout-svc --caller.prompt=list the files here"
```

It prints the correlators for Elasticsearch:

```
correlate in Elasticsearch by  trace.id=<32hex> (this run)  and  labels.app_name=<name> (this app)
```

## Verify (Elasticsearch)

```sh
# Claude's spans under the caller's trace
curl -s "http://localhost:9200/traces-apm-agents_claude_code*/_search" -H 'Content-Type: application/json' \
  --data '{"query":{"term":{"trace.id":"<traceId>"}}}'

# every Claude signal tagged with the launching app
curl -s "http://localhost:9200/logs-apm.app.claude_code*/_search" -H 'Content-Type: application/json' \
  --data '{"query":{"term":{"labels.app_name":"<name>"}}}'
```

## Configuration (`caller.*`, all overridable at launch)

| Key | Default | Meaning |
| --- | --- | --- |
| `caller.agent` | `claude` | which agent to launch (implemented: `claude`) |
| `caller.app-name` | `my-app` | → `app.name` attribute (no spaces / `,` / `=`) |
| `caller.prompt` | `say hi in one word` | prompt handed to the agent |
| `caller.command` | *(blank → agent default, e.g. `claude`)* | CLI executable, resolved on PATH |
| `caller.working-dir` | *(blank → agent's default stack dir)* | directory the agent runs in (must hold its telemetry config) |

The launch is **agent-agnostic** — the per-agent bits (argv, working dir, extra env) live in the
`Agent` enum. Only `claude` is wired today; a second agent (e.g. Codex, `codex exec` with a
`CODEX_HOME`) is a new enum constant.
