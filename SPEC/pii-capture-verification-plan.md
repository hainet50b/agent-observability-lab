# PII capture paths — verification plan (temporary working document)

> **Status: planning.** This is a scratch plan owned by the spec layer, tracking
> a multi-pattern verification campaign. It will be folded into the permanent
> SPEC docs (and PRD tasks, where Ralph builds lab components) as each pattern
> gets verified. Delete this file when the campaign is done.

## Goal

The organization wants an audit record of **when, who, and what prompt** was
sent through coding agents (scope may widen to tool I/O and raw LLM API
bodies), stored as **encrypted files** — while the existing analytics path
(OTLP → Elastic: tokens, cost, events) keeps flowing untouched. The lab
verifies every candidate capture path side by side, budget concerns set aside.

Established constraints that shape the patterns:

- The OTLP content gates land in APM `labels.*` and get **truncated at 1024
  chars** (APM Server limit); `tool.output` misses MCP entirely and needs
  tracing; `RAW_API_BODIES` inline is a ~1 KB head fragment
  (see `claude-code-telemetry.md`, Content-exposure gates).
- Neither the otelcol file exporter nor Claude Code's file mode encrypts —
  encryption is always a separate step (encrypted volume, or public-key
  sealing with `age`: endpoints can seal but not open).
- Storage model under test: **plaintext envelope (ts / user / session) +
  ciphertext content** — searchable "who/when" with sealed "what", whether the
  store is a JSONL file or an Elasticsearch index.

## Pattern inventory

### P0 — gates straight into Elastic (baseline; verified)

`OTEL_LOG_USER_PROMPTS=1` → existing stack. Plaintext in `labels.prompt`,
1024-char truncation, access control only. **Fails the encryption requirement
by design** — kept as the comparison baseline. Nothing left to verify.

### P1 — agent hooks: capture at source, seal locally, ship to Elasticsearch

`UserPromptSubmit` (prompt), `PreToolUse`/`PostToolUse` (tool + MCP I/O —
hooks fire for `mcp__<server>__<tool>` names, closing the gate's MCP hole;
input and response arrive in the same payload, pre-joined), `Stop`/
`SubagentStop` (+ `transcript_path` for model output, indirectly). Hook script
builds `{ts, user, session_id, content}`, seals content with an `age` public
key, appends local JSONL and/or POSTs to a dedicated ES index
(envelope-plaintext / content-cipher). Zero extra processes; telemetry config
untouched; offline-tolerant (flush later).

Verify:

- [ ] `UserPromptSubmit` stdin payload shape — full prompt? `session_id`?
- [ ] Identity resolution — `user_email` is not in the hook env; OS user +
      hostname enough, or readable from the local `claude` auth config?
- [ ] `PostToolUse` `tool_response` size limits / truncation (probe with a
      huge `Read`)
- [ ] MCP tools observed live through `PreToolUse`/`PostToolUse`
- [ ] Subagent-internal tool calls — do hooks fire for them?
- [ ] Headless (`claude -p`, the Ralph shape) — do hooks fire?
- [ ] Transcript contents via `transcript_path` — assistant output? thinking
      blocks (present or redacted)?
- [ ] Per-tool-call hook overhead (latency measurement)
- [ ] ES ingest of the sealed record; Kibana usability of
      envelope-plaintext / content-cipher documents
- [ ] Enforcement story: hook forced via managed settings
      (`hook_source: policySettings`) and *observed* through the existing
      `hook_registered` / `hook_execution_complete` events — the current
      telemetry audits the audit

### P2 — OTel Collector gateway: fan-out, sanitize one branch, file the other

`OTEL_LOG_USER_PROMPTS=1` → OTLP → central gateway collector →
pipeline ① drops the `prompt` attribute → APM/Elastic (analytics unchanged);
pipeline ② filters `user_prompt` events → file exporter (JSONL, rotation) →
seal at rotation. No PII ever lands on endpoints; fleet config is one
endpoint env var; agent-agnostic (works for codex/opencode later). Weakness:
no offline tolerance (unreachable endpoint = lost telemetry).

Verify:

- [ ] Sanitization leak-check — `prompt` provably absent from every document
      reaching Elastic (events *and* anything else carrying it)
- [ ] File-branch fidelity — full prompt, no 1024-char truncation (this is
      where the APM label limit demonstrably does not apply)
- [ ] file exporter format / rotation / compression behavior
- [ ] Seal-at-rotation flow (age) — no plaintext left behind
- [ ] Filter precision — only `user_prompt` events on the file branch
- [ ] Lab shape: new `components/paths/otelcol-gateway` + stack

### P3 — `OTEL_LOG_RAW_API_BODIES=file:<dir>` + sidecar filelog collection

Agent writes full request/response bodies to local files (the documented
escape from the inline ~1 KB fragment); a local collector (existing
`otelcol-sidecar` component + filelog receiver) collects and ships them
(destination to decide: quarantined ES index vs central file store). The only
**superset** pattern — covers system prompts, tool results incl. MCP, model
output, per-attempt bodies. Overkill for prompt audit; the insurance pattern
if scope widens to full-fidelity API bodies. Encryption point is central
(post-collection), and bodies sit **plaintext on the endpoint** — both are
comparison axes, not disqualifiers, for the lab.

Verify (the `file:<dir>` probe comes first — it gates the whole pattern):

- [x] `file:<dir>` behavior — **verified, recorded in
      `claude-code-telemetry.md` (`OTEL_LOG_RAW_API_BODIES` section)**: raw
      verbatim bodies per file (`<uuid>.request.json` /
      `req_<request_id>.response.json`), truncation chain fully lifted
      (~400 KB request files, `body_length` == file size), events switch from
      inline `body` to `body_ref` (pointer/cold-file model native), thinking
      `<REDACTED>` even on disk
- [x] Coverage — MCP traffic confirmed inside bodies (the `tool.output` gap
      does not exist here); response bodies captured with full `usage`
- [ ] Retry attempts as separate files? (needs a live failure window)
- [ ] filelog receiver collection — parsing, multiline/size handling
- [ ] Shipping destination trade-off — quarantined ES index vs central files
- [ ] Volume measurement (bodies are big; what does a working day produce?
      first data point: ~400 KB per request in a long session, one file per
      API call)

### P4 — LLM proxy / gateway (`ANTHROPIC_BASE_URL` → LiteLLM, mitmproxy, …)

Point the agent's API traffic through a proxy and record on the wire. The
only capture point that does **not depend on the agent's self-reporting** —
agent-agnostic by construction, full request/response fidelity, and the
enterprise-standard answer (LLM gateways). Costs: a network hop on every
request, TLS/auth passthrough complexity, and the proxy becomes the most
PII-dense component in the system.

Verify:

- [ ] Does `ANTHROPIC_BASE_URL` override work with this subscription's OAuth
      auth (not just API keys)? This gates the whole pattern
- [ ] Candidate tooling pass — LiteLLM proxy vs mitmproxy vs a thin custom
      relay; what each records and in what format
- [ ] Streaming (SSE) capture fidelity
- [ ] Latency overhead measurement
- [ ] Storage: envelope/cipher split applied to wire captures
- [ ] Failure posture — proxy down: does the agent fail closed (no work) or
      open (no audit)? Which do we want?

## Comparison axes (the final deliverable is this table, filled in)

| Axis | P0 | P1 | P2 | P3 | P4 |
| --- | --- | --- | --- | --- | --- |
| Capture scope | prompt | prompt + tool/MCP I/O + transcript | prompt (extensible) | full API bodies | full API bodies |
| PII at rest on endpoint | none (but plaintext in ES) | sealed | none | **plaintext** | none |
| Encryption point | — (fails req.) | endpoint (public key) | central (rotation) | central (post-collection) | central (proxy) |
| Extra infra | none | none | gateway | sidecar | proxy |
| Offline tolerance | n/a | yes | no | yes | no |
| Truncation | 1024 chars | none (verify) | none (verify) | lifted? (verify) | none |
| Agent-agnostic | gate names differ | ✗ (Claude hooks) | ◎ | △ (Claude file mode) | ◎ |
| Depends on agent self-reporting | yes | yes | yes | yes | **no** |

## Execution order

1. **`file:<dir>` probe** (P3 prerequisite; long-deferred) — cheap, and its
   outcome reshapes P3.
2. **P1** — zero infra, same-day verifiable with a temporary hook in a live
   session.
3. **P2** — first new component build (`otelcol-gateway`).
4. **P3 full** — extend the sidecar with filelog, decide the destination.
5. **P4** — gated on the `ANTHROPIC_BASE_URL`/OAuth check; do that check
   early (it is a five-minute experiment) even if the full pattern runs last.

Each pattern ends by filling its column in the comparison table and recording
durable findings in `claude-code-telemetry.md` (capture-path behavior) or a
new permanent SPEC doc (architecture comparison), then trimming this file.
