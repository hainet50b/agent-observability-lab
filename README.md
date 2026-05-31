# Agent Observability Lab

> A runnable lab for seeing exactly what telemetry an AI coding agent emits, and how an observability backend ingests it.

> This `README.md` is for end users. Developers (including AI agents) should also read the files under `SPEC/` and `CONVENTIONS.md` before working on the codebase.

## Features

- **Self-contained stacks.** Each experiment lives under `stacks/<name>/` and runs on its own with `docker compose up` — no shared state between stacks.
- **`claude-code-elastic`.** Claude Code → APM Server (Elastic-native OTLP) → Elasticsearch → Kibana. Captures both **metrics** (sessions, tokens, cost, code edits, commits/PRs) and **events** (prompts, tool results, API requests), so you can inspect the real fields in Kibana.
- **Local-first and disposable.** Single-node, security-disabled demo posture — clone, bring it up, look at the data, tear it down.

## Quick Tour

> _Filled in once the `claude-code-elastic` stack is demonstrable end to end. It will be the shortest path from clone to "I see Claude Code telemetry in Kibana."_

## Install

> _Each stack documents its own `docker compose` workflow in `stacks/<name>/README.md`. See `stacks/claude-code-elastic/` (in progress)._

## Reference

### Stacks

| Stack | Agent | Backend | Status |
| --- | --- | --- | --- |
| [`claude-code-elastic`](stacks/claude-code-elastic/) | Claude Code | Elastic Stack (Elasticsearch + Kibana + APM Server) | In progress |

> ⚠️ These stacks run with security disabled for local demonstration only. Do not expose them publicly, and do not send confidential prompts/material through a telemetry-enabled session — the events channel can capture prompt and tool content.
