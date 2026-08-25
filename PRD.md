# Agent Observability Lab — PRD

This is the Product Requirements Document. It owns three things: the project's **What**, the project's **Why**, and the open and closed **Tasks**. End-user-facing surface lives in `README.md`; internal structure lives under `SPEC/`; coding style lives in `CONVENTIONS.md`.

## What

Agent Observability Lab wires coding agents (Claude Code, Codex) to observability backends: telemetry over OTLP/APM and tool-call audit over hooks → Elasticsearch.

## Why

To see exactly what an AI coding agent emits, and how an observability backend ingests it — from clone to "I can see what my agent is doing."

## Tasks

Each task is one concern and carries a stable id — `- [ ] T<n>: …`, where `<n>` is the next unused number at append time. Ids are never reused or renumbered. An open task may be amended until a run claims it (`ls .ralph/claims`); from then on it is frozen — changes become new tasks — and completed tasks (`- [x]`) are immutable history. Tasks are processed in order subject to their dependencies.

One blank line separates tasks, including before a newly appended one, so that concurrent checkoffs and appends merge without git conflicts.

No open tasks yet — add the first one in conversation before kicking `./ralph.sh`.
