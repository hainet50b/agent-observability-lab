# callers

Applications that **drive an agent** (`claude -p`, `codex exec`) as a subprocess, to exercise its
telemetry from the caller's side. A caller is the counterpart to a `stacks/` composition from the
other end of the wire: it stands up no backend and **emits no telemetry of its own** — the lab
observes the *agent's* signals — it only shapes how that telemetry is **traced** and **attributed**.

| Concern | Mechanism | Where it shows up |
| --- | --- | --- |
| **Join** the agent's run into the caller's distributed trace | pass `TRACEPARENT` into the child env (`claude -p` and the Agent SDK read it; the interactive REPL ignores it) | agent spans share the caller's `trace.id` (`traces-apm-agents_*`) |
| **Attribute** agent usage per launching application | pass `OTEL_RESOURCE_ATTRIBUTES=app.name=…` | `labels.app_name` on every agent metric / log / span (a single run is identified by its `trace.id`) |

The agent's `service.name` is never changed, so the standard pipelines, templates, and Kibana views
apply unchanged. Point a caller at an already-running telemetry stack (e.g.
[`../stacks/claude-elastic`](../stacks/claude-elastic/)).

## Callers

- [`spring-boot/`](spring-boot/) — a Spring Boot 4 one-shot (`./mvnw spring-boot:run`): boots the
  container, issues a W3C trace id, launches an agent (`claude` today) with a chosen `app.name`,
  exits. Agent-agnostic by design (`caller.agent`); a second agent is one `Agent` enum constant.
