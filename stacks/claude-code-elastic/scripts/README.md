# claude-code-elastic — scripts

## `smoke-test.sh`

End-to-end smoke / verification test for the stack. It follows the 3A pattern
(`CONVENTIONS.md`):

- **Arrange** — `docker compose up -d` and wait for Elasticsearch, Kibana, and
  APM Server to all report `healthy`.
- **Act** — POST one synthetic OTLP **metrics** payload and one synthetic OTLP
  **logs/event** payload to the APM Server OTLP/HTTP endpoint (`/v1/metrics`,
  `/v1/logs`), shaped like the two channels Claude Code emits and tagged with
  `service.name = cce-smoke-test`.
- **Assert** — query Elasticsearch and confirm those documents were ingested
  into the APM data streams, proving the **OTLP → APM Server → Elasticsearch**
  path works end to end.

It then prints a **DISCOVER** summary listing the `service.name` values present
in the APM metrics/logs data streams — so real Claude Code telemetry (from an
actual `claude` session) shows up alongside the synthetic probe.

### Run it

```sh
# from anywhere — the script locates its own stack directory
stacks/claude-code-elastic/scripts/smoke-test.sh
```

Prerequisites: `docker` (with a running daemon), `curl`, `jq`. If the Docker
daemon is not reachable the script **SKIPs** (exit 0) — there is nothing to
smoke-test without it. Override endpoints with `ES_URL` / `APM_OTLP_URL` if you
publish different ports.

A synthetic probe is used (instead of driving a real `claude` session) so the
Act step is self-contained and deterministic — no API key, no interactive
session — and can run as a gate. Real Claude Code telemetry travels the
identical pipeline; it simply lands under its own service name.

## Expected indices

APM Server, acting as the OTLP receiver, routes each OTLP signal to an Elastic
APM data stream named `<type>-apm.<dataset>-<namespace>` (namespace `default`).
Characters not allowed in a dataset name are replaced with `_`, so a service
name like `claude-code` becomes `claude_code`.

| Signal (OTLP) | Elasticsearch data stream | Example |
| --- | --- | --- |
| Metrics (`/v1/metrics`) | `metrics-apm.app.<service.name>-default` | `metrics-apm.app.claude_code-default` (probe: `metrics-apm.app.cce_smoke_test-default`) |
| Events / logs (`/v1/logs`) | `logs-apm.app.<service.name>-default` | `logs-apm.app.claude_code-default` (probe: `logs-apm.app.cce_smoke_test-default`) |
| APM Server internal metrics | `metrics-apm.internal-default` | — |

The smoke test queries the wildcard patterns `metrics-apm*` and `logs-apm*` and
filters on `service.name`, so it does not depend on the exact dataset spelling.

## Expected fields

Common to every document: `@timestamp`, `service.name`, and any OTLP attributes
— string attributes surface under `labels.*` and numeric ones under
`numeric_labels.*` (dots in attribute keys become `_`).

The metric / event **names** below are what Claude Code's telemetry documents at
the time of writing. They are listed as a guide, not gospel — per `SPEC/SPEC.md`
the point of this lab is to confirm what actually lands. The DISCOVER step above
and Kibana Discover are the source of truth for the version you are running.

**Metrics** (in `metrics-apm.app.claude_code-default`) — the value is stored in
a field named after the metric:

- `claude_code.session.count`
- `claude_code.token.usage` (attribute `type` = input | output | cacheRead | cacheCreation)
- `claude_code.cost.usage` (USD)
- `claude_code.lines_of_code.count` (attribute `type` = added | removed)
- `claude_code.commit.count`
- `claude_code.pull_request.count`
- `claude_code.code_edit_tool.decision`
- `claude_code.active_time.total`

**Events** (in `logs-apm.app.claude_code-default`) — identified by `event.name`
/ the record body, with attributes under `labels.*` / `numeric_labels.*` (model,
token counts, durations, decision/outcome):

- `claude_code.user_prompt`
- `claude_code.tool_result`
- `claude_code.api_request`
- `claude_code.api_error`
- `claude_code.tool_decision`
