# Agent Observability Lab — PRD

This is the Product Requirements Document. It owns three things: the project's **What**, the project's **Why**, and the open and closed **Tasks**. End-user-facing surface lives in `README.md`; internal structure lives under `SPEC/`; coding style lives in `CONVENTIONS.md`.

## What

Agent Observability Lab is a hands-on environment for evaluating what telemetry an AI coding agent emits and how an observability backend ingests, stores, and visualizes it. It is organized as a collection of self-contained **stacks**, each living under `stacks/<name>/` and runnable on its own with `docker compose up`. The first stack is **`claude-code-elastic`**: Elasticsearch + Kibana + APM Server, receiving Claude Code's OpenTelemetry signals over Elastic's native OTLP endpoint and surfacing the collected **metrics** (sessions, tokens, cost, code edits, commits/PRs) and **events** (prompts, tool results, API requests) in Kibana. The lab is a reproducible demo and reference, not a production deployment.

## Why

AI coding agents are increasingly part of real workflows, and it is hard to reason about cost, audit, and behavior without seeing what is actually observable about them. Vendor docs describe the signals in the abstract; this lab makes them concrete — a stack anyone can `docker compose up` to watch real agent telemetry flow into a backend, inspect the exact fields, and judge what is useful, what is sensitive, and what is missing. Keeping each stack self-contained under `stacks/` lets new agent/backend combinations be added and compared over time without entangling them.

## Tasks

Each task is one concern. Tasks are processed in order subject to their dependencies. Completed tasks (`- [x]`) are immutable history — corrections become new tasks, never edits to old ones.

- [x] Establish the `claude-code-elastic` Elastic Stack base: `stacks/claude-code-elastic/docker-compose.yml` running Elasticsearch (single-node, security disabled) and Kibana, both with healthchecks, pinned to Elastic Stack **9.4.2** (all services share this version). `docker compose up -d` from the stack directory brings both to a healthy state and Kibana is reachable on its HTTP port. Record the chosen tech stack and the lint/test commands in `CONVENTIONS.md`.
- [x] Add APM Server to `stacks/claude-code-elastic/` as the Elastic-native OTLP receiver: a service that accepts OTLP/HTTP and OTLP/gRPC, writes to Elasticsearch, and is reachable on its OTLP port. Its config lives under `stacks/claude-code-elastic/config/`. Verify the OTLP endpoint responds.
- [x] Provide Claude Code telemetry configuration in `stacks/claude-code-elastic/`: a documented `.env.example` (and matching docs) that enables `CLAUDE_CODE_ENABLE_TELEMETRY` with the `OTEL_*` exporters for **both metrics and events**, pointed at the APM Server OTLP endpoint. Document exactly how to run a Claude Code session that emits into this stack.
- [x] Add a smoke/verification script under `stacks/claude-code-elastic/scripts/` that brings the stack up, waits for health, and asserts that Claude Code telemetry has landed by querying the relevant Elasticsearch indices. Document the expected indices/fields.
- [x] Add a Kibana view for `claude-code-elastic` (data views / saved objects as importable NDJSON, or documented Discover + APM UI steps) so a user can open Kibana and see the collected Claude Code metrics and events. Write the stack's `stacks/claude-code-elastic/README.md` Quick Tour against this working path.
