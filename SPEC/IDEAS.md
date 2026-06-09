# IDEAS — what we want and how we'd build it

> Free-form design notes. Companion to `SPEC/pii-capture-verification-plan.md`
> (the structured P0–P4 plan with verify checkboxes). This file holds the
> intent and the design decisions — not session/machine state. Fold into the
> permanent SPEC docs as things settle.

## What we're building

An audit trail of **when / who / what prompt** through coding agents, stored
**encrypted**, while the existing OTLP→Elastic analytics path keeps flowing
untouched. Manager's steer: "just encrypt the sensitive stuff to a file, don't
over-engineer, no sidecar talk." Scope locked to **prompts** as the must-have;
tool I/O and raw API bodies are nice-to-have (and P1 turns out to cover them).

Five capture patterns under lab evaluation (full detail + verify checkboxes in
`pii-capture-verification-plan.md`):

- **P0** gates → Elastic (baseline; verified; fails encryption req by design)
- **P1** agent hooks → seal locally → ship ← **current focus** (capture
  characterized; build phase next)
- **P2** OTel Collector gateway fan-out (sanitize one branch, file the other)
- **P3** `OTEL_LOG_RAW_API_BODIES=file:` + filelog collection (file-mode probe
  verified — truncation lifted, `body_ref` pointers, MCP covered, thinking
  still `<REDACTED>`)
- **P4** LLM proxy (`ANTHROPIC_BASE_URL` → LiteLLM/mitmproxy) — only
  agent-independent capture point; OAuth-override feasibility unchecked (a quick
  test gates the whole pattern)

## Key realization about keys

Sealing uses **public-key crypto**, so what ships to each endpoint is a
**public cert — not a secret**. Commit it, push it, distribute via managed
settings, whatever. The only secret is the **investigator's private key**, held
centrally in one place. So "key distribution" is a non-problem; the real
question is "what encryption works on Linux/macOS/Windows without heavy deps."

**Decision: use CMS (PKCS#7) enveloped-data, not age** — because it needs
**zero extra tooling** across all three OSes:
- Windows: `Protect-CmsMessage` (PowerShell 5+ built-in)
- macOS: `security cms -E`, or bundled `openssl smime/cms`
- Linux: `openssl cms -encrypt`
- All interoperate on one X.509 cert; central side decrypts with the private key.
- Fits the repo's existing `.sh`/`.ps1` per-OS script pattern: scripts are
  OS-specific, the cert + format are shared.

age remains the "simplest if you're willing to drop one static binary"
alternative; CMS wins on "install nothing."

Sketch:
```
keygen (central, once):  openssl req -x509 -newkey rsa:4096 -keyout audit-priv.pem -out audit-cert.pem -nodes
seal (endpoint, in hook): openssl cms -encrypt -aes256 -binary -outform PEM audit-cert.pem
open (investigation):     openssl cms -decrypt -inkey audit-priv.pem
```

**Order:** stand up the Elasticsearch ingest path first (plaintext prompt),
then layer CMS sealing on top (swap `prompt` → `prompt_cipher`).

## Lab structure — CONFIRMED

This feature is agent-non-specific store + Claude-specific capture, so it
splits cleanly and rides into BOTH existing stacks with no new stack:

```
components/
├── backends/elastic/                          ← the audit STORE (agent-agnostic)
│   ├── elasticsearch/prompt-audit.index.json     (index/mapping def)
│   └── scripts/setup-prompt-audit.sh / .ps1      (create it)
│       # exact precedent: trace-routing.pipeline.json + setup-trace-routing.sh
└── agents/claude-code/
    └── hooks/                                  ← NEW 3rd dir beside kibana/ scripts/
        └── capture-prompt.sh                      (UserPromptSubmit capture)
        # hook REGISTRATION is "agent config" → documented in stack READMEs
        # alongside the OTEL_* env block; NOT in docker-compose (no container)

stacks/claude-code-elastic/scripts/             ← add a setup-prompt-audit shim
stacks/claude-code-otelcol-elastic/scripts/     ← same (both stacks include both components)
```

Rationale: the `prompts-audit` index is where codex/opencode captures would
also land → backend's property. The capture script is bound to Claude Code's
`UserPromptSubmit` payload shape → agent's property. Both stacks already
include `backends/elastic` + `agents/claude-code`, so "works in both
simultaneously" is automatic.

Later (place reserved, not built): Kibana data view + saved search for
prompts-audit → `backends/elastic/kibana/`. CMS cert handling → keygen script
location TBD in the CMS phase (the public cert is a distributable artifact).

## prompts-audit index — proposed mapping

```json
{ "mappings": { "dynamic": "strict", "properties": {
  "@timestamp":    {"type":"date"},
  "user_email":    {"type":"keyword"},
  "session_id":    {"type":"keyword"},
  "cwd":           {"type":"keyword"},
  "hostname":      {"type":"keyword"},
  "prompt":        {"type":"text"},
  "prompt_cipher": {"type":"keyword","index":false,"doc_values":false,"ignore_above":32766}
}}}
```
- `dynamic: strict` — a hook bug should fail-loud, not grow stray fields.
- envelope = keyword (the searchable "who/when"); `prompt` = text (plaintext
  phase only); `prompt_cipher` defined up front (pure BLOB, index/doc_values
  off) so swapping to sealed storage needs no mapping change.
- prototype is a plain index; production → data stream + ILM (retention =
  deletion requirement).

## P1 capture characterization — what the hooks give us

- `UserPromptSubmit` payload: full unredacted `prompt`, `session_id` (== OTLP
  `session.id`), `transcript_path`, `cwd`, `permission_mode`. No identity.
- Identity is locally resolvable: `~/.claude.json` `.oauthAccount.emailAddress`
  (+ `organizationName`). The hook completes the envelope itself.
- `tool_response` over ~23 KB truncates inline but carries
  `persistedOutputPath`/`persistedOutputSize` → full content on disk (pointer
  model again).
- MCP tools fire Pre/PostToolUse (`mcp__server__tool`) — closes the
  `tool.output` MCP gap.
- Subagent-internal tools fire, enriched with `agent_id` + `agent_type`;
  `SubagentStop` adds `agent_transcript_path`. Background utility agents fire
  `SubagentStop` with `agent_type:""` → noise to filter.
- Headless `claude -p` fires hooks → Ralph sessions auditable.
- Thinking blocks: empty everywhere (transcript + API) → not capturable.
- `tool_use_id` is in payloads → DIRECT join to OTLP `tool_result` events (no
  ES|QL 2-hop needed). `Stop` carries `last_assistant_message`. Failed tools
  fire PreToolUse only → error capture needs a `PostToolUseFailure` hook.

## What's left

P1 build phase, plaintext-ingest-first then CMS. Rough order, use judgement:

- Stand up the `prompts-audit` index, then a capture script
  (`UserPromptSubmit` → envelope from `~/.claude.json` → ES doc + local JSONL).
- Layer CMS sealing on top (`prompt` → `prompt_cipher`); prove envelope stays
  searchable while ciphertext opens only with the private key.
- Once it works end-to-end, PRD-ify into the component layout above for Ralph.
- Independently: the P4 OAuth feasibility check, and PRD-ing the P2 gateway.
