# Agent Observability Lab — PRD

This is the Product Requirements Document. It owns three things: the project's **What**, the project's **Why**, and the open and closed **Tasks**. End-user-facing surface lives in `README.md`; internal structure lives under `SPEC/`; coding style lives in `CONVENTIONS.md`.

## What

Agent Observability Lab wires coding agents (Claude Code, Codex) to observability backends: telemetry over OTLP/APM and tool-call audit over hooks → Elasticsearch.

## Why

To see exactly what an AI coding agent emits, and how an observability backend ingests it — from clone to "I can see what my agent is doing."

## Tasks

Each task is one concern and carries a stable id — `- [ ] T<n>: …`, where `<n>` is the next unused number at append time. Ids are never reused or renumbered. An open task may be amended until a run claims it (`ls .ralph/claims`); from then on it is frozen — changes become new tasks — and completed tasks (`- [x]`) are immutable history. Tasks are processed in order subject to their dependencies.

One blank line separates tasks, including before a newly appended one, so that concurrent checkoffs and appends merge without git conflicts.

- [x] T1: `agent-config bundle` also writes a `<executor>.sha256` sidecar into each cell, alongside the existing `<executor>.version` (same placement rule: managed root for managed cells, agent home for user-scope cells — mirror `version_file_rel` in `agent-config/src/bundle.rs`). Content is one `sha256(bytes)  relpath` line per rendered file (`sha256sum -c` compatible), reusing the per-file manifest that `cell_hash` already builds internally rather than recomputing it — the ledger hash and the sidecar's content must derive from the same computation. Both the `.version` file and the `.sha256` file itself are excluded from what the sidecar covers, for the same self-reference reason `.version` is already excluded (see `cell_hash` and [`config-deployment.md`](SPEC/config-deployment.md) §Bundles). Update that SPEC section's Bundles paragraph to document the new sidecar in the same change.
