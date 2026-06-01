# Agent Observability Lab

A runnable lab for seeing exactly what telemetry an AI coding agent emits, and how an observability backend ingests it.

## Features

- **Self-contained stacks.** Each experiment lives under `stacks/<name>/` and runs on its own with `docker compose up` — no shared state between stacks.
- **Real signals, not vendor docs.** Each stack pipes an AI coding agent's telemetry into a real backend, so you inspect the actual **metrics** (sessions, tokens, cost, …) and **events** (prompts, tool results, API requests) it emits — the exact fields, not an abstract list.
- **Local-first and disposable.** Single-node, security-disabled demo posture — clone, bring it up, look at the data, tear it down.

## Stacks

Every stack is self-contained — pick one below and follow its README: bring it up with `docker compose up`, point an AI coding agent at it, and inspect the telemetry that lands in the backend.

| Stack | Agent | Backend |
| --- | --- | --- |
| [`claude-code-elastic`](stacks/claude-code-elastic/) | Claude Code | Elastic Stack (Elasticsearch + Kibana + APM Server) |
