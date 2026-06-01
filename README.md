# Agent Observability Lab

> A runnable lab for seeing exactly what telemetry an AI coding agent emits, and how an observability backend ingests it.

> This `README.md` is for end users. Developers (including AI agents) should also read the files under `SPEC/` and `CONVENTIONS.md` before working on the codebase.

## Features

- **Self-contained stacks.** Each experiment lives under `stacks/<name>/` and runs on its own with `docker compose up` — no shared state between stacks.
- **`claude-code-elastic`.** Claude Code → APM Server (Elastic-native OTLP) → Elasticsearch → Kibana. Captures both **metrics** (sessions, tokens, cost, code edits, commits/PRs) and **events** (prompts, tool results, API requests), so you can inspect the real fields in Kibana.
- **Local-first and disposable.** Single-node, security-disabled demo posture — clone, bring it up, look at the data, tear it down.

## Quick Tour

The fastest path is the **`claude-code-elastic`** stack: bring up Elasticsearch + Kibana + APM Server, point a telemetry-enabled Claude Code session at it, and inspect the real metrics and events in Kibana. Full step-by-step (start → import data views → see telemetry → tear down) lives in [`stacks/claude-code-elastic/README.md`](stacks/claude-code-elastic/README.md).

## Install

Each stack documents its own `docker compose` workflow in `stacks/<name>/README.md`. See [`stacks/claude-code-elastic/`](stacks/claude-code-elastic/) for a working end-to-end stack.

## Reference

### Stacks

| Stack | Agent | Backend | Status |
| --- | --- | --- | --- |
| [`claude-code-elastic`](stacks/claude-code-elastic/) | Claude Code | Elastic Stack (Elasticsearch + Kibana + APM Server) | Working — stack + data views + saved searches; dashboards next |

> ⚠️ These stacks run with security disabled for local demonstration only. Do not expose them publicly, and do not send confidential prompts/material through a telemetry-enabled session — the events channel can capture prompt and tool content.
