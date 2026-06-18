# Agent Audit

Direct agent-audit records, such as hook-captured user prompts, use dedicated Elasticsearch log data streams separate from OpenTelemetry/APM data streams. These data streams are agent-cross-cutting: the agent implementation is represented in document fields, not in the data stream name.

## Data streams

The prompt audit data stream is:

```text
logs-agent_audit.user_prompt-default
```

This follows Elastic's `<type>-<dataset>-<namespace>` convention:

- `type`: `logs`
- `dataset`: `agent_audit.user_prompt`
- `namespace`: `default`

Future audit streams should follow the same pattern, for example:

```text
logs-agent_audit.tool_call-default
```

`agent.*` is not used for AI-agent identity in direct audit documents. In ECS, `agent.*` primarily describes the software agent that collects or ships an event, so using it for Codex CLI / Claude Code risks semantic confusion. AI-agent identity belongs under the custom `agent_audit.*` namespace instead.

## Where this runs

The audit data streams are provisioned (strict templates + data streams) and viewed (cross-agent Kibana data views / saved searches) by the **`elastic-audit`** backend — Elasticsearch + Kibana, **no APM Server**, since audit is a direct hook → Elasticsearch write that never uses the OTLP / APM path. It is composed by `<agent>-elastic-audit` stacks (e.g. `codex-cli-elastic-audit`), separate from the telemetry backend (`elastic` / `codex-cli-elastic`): same local Elasticsearch technology, but a separate compose project, separate volumes, and a separate agent home (whose `.codex` carries `config.toml` — the inline `[hooks]` registrations plus the Elasticsearch MCP — and `agent-audit.conf`, but no `[otel]` config). The split keeps each stack's load-bearing set legible; the two stacks are alternatives, not run simultaneously.

## User prompt documents

User prompt audit documents in `logs-agent_audit.user_prompt-default` use this canonical shape:

```json
{
  "@timestamp": "...",
  "event": {
    "action": "user-prompt",
    "created": "...",
    "dataset": "agent_audit.user_prompt",
    "kind": "event"
  },
  "user": {
    "id": "...",
    "name": "..."
  },
  "host": {
    "name": "...",
    "hostname": "..."
  },
  "agent_audit": {
    "agent": {
      "provider": "openai",
      "name": "codex-cli",
      "account": {
        "id": "...",
        "name": "...",
        "email": "..."
      },
      "organization": {
        "id": "...",
        "name": "..."
      }
    },
    "conversation_id": "...",
    "turn_id": "...",
    "user_prompt": {
      "text": "...",
      "encrypted_text": null,
      "length": 123
    }
  }
}
```

Field ownership:

- ECS fields: `@timestamp`, `event.action`, `event.created`, `event.dataset`, `event.kind`.
- ECS user fields: `user.id` and `user.name` identify the workstation/business login identity on a best-effort basis. `user.id` is the domain-qualified login (`whoami`: `DOMAIN\user` on Windows, the bare login on POSIX where no domain source exists) and `user.name` is the short login name. `user.email` is not used because it is not available consistently from local hook scripts across platforms. Access to the audit data stream is restricted instead. See [Identity derivation](#identity-derivation).
- ECS host fields: `host.name` and `host.hostname` are populated on a best-effort basis per runtime.
- Custom audit fields: `agent_audit.*`.
- `agent_audit.user_prompt.text` carries plaintext in the lab and is searchable. Production-oriented audit flows may set it to `null` and populate `agent_audit.user_prompt.encrypted_text` with application-encrypted prompt content instead.
- `agent_audit.agent.*` describes the AI agent application, not the ECS collecting agent.
- `agent_audit.agent.account.*` describes the AI agent provider account when available; it is read from the agent's local credential store (for Codex CLI, `$CODEX_HOME/auth.json` — see [Identity derivation](#identity-derivation)).
- `agent_audit.agent.organization.*` describes the AI agent provider organization / workspace / tenant context when available. It is parallel to `account`, not nested under it, and is read from the same local credential store (see [Identity derivation](#identity-derivation)).
- Standardized audit event names belong in `event.action`; user prompt submissions use `event.action: user-prompt`.
- Hook senders should construct near-final JSON documents before indexing. Ingest pipelines for audit streams should stay minimal: defaulting, validation, and routing are acceptable, but prompt redaction/encryption belongs in the sender.
- `logs-agent_audit.*` is access-controlled separately from OTel/APM telemetry indices. The intended production posture is that only audit-authorized users can read the audit data stream.

## Tool call documents

Tool call audit documents in `logs-agent_audit.tool_call-default` record one tool invocation each, captured from Codex's `PostToolUse` hook (which carries both the tool input and its result). Canonical shape:

```json
{
  "@timestamp": "...",
  "event": { "action": "tool-call", "created": "...", "dataset": "agent_audit.tool_call", "kind": "event" },
  "user": { "id": "...", "name": "..." },
  "host": { "name": "...", "hostname": "..." },
  "agent_audit": {
    "agent": {
      "provider": "openai", "name": "codex-cli",
      "account": { "id": "...", "name": "...", "email": "..." },
      "organization": { "id": "...", "name": "..." }
    },
    "conversation_id": "...",
    "turn_id": "...",
    "tool_call": {
      "tool":   { "name": "...", "call_id": "..." },
      "input":  { "text": "...", "encrypted_text": null, "length": 123 },
      "output": { "text": "...", "encrypted_text": null, "length": 456 }
    }
  }
}
```

`event.*`, `user.*`, `host.*`, `agent_audit.agent.*`, `conversation_id`, and `turn_id` carry the same meaning and identity derivation as user prompt documents. Tool-call-specific ownership:

- `event.action: tool-call`, `event.dataset: agent_audit.tool_call`.
- `agent_audit.tool_call.tool.name` ← Codex `tool_name`; `tool.call_id` ← `tool_use_id` (the per-call id; also the join key to the OTLP trace_safe `codex.tool_result` `call_id`).
- `agent_audit.tool_call.input` ← `tool_input`, `.output` ← `tool_response`. Both Codex fields are heterogeneous JSON (an object for MCP tools; a string or object for shell tools), so the sender **serializes each to a JSON string** into `.text`, with `.length` the character count. The strict mapping then sees one scalar per side, not the tool's arbitrary nested keys.
- `capture.tool_call.content = plaintext` populates `.text`; `redacted` writes a `[REDACTED]` marker; `encrypted` nulls it and reserves `.encrypted_text` — all keep the true `.length`, set per stream (the same gate as the prompt body — see [Delivery and authorization](#delivery-and-authorization)).
- No success / exit field — Codex's `tool_response` is opaque and not reliably parseable across tools.
- Source is Codex `PostToolUse` **only** (it fires after completion with input + output). `conversation_id` ← `session_id`, `turn_id` ← `turn_id`; `cwd` / `transcript_path` / `permission_mode` are dropped (not in the schema; the mapping is strict).

## Identity derivation

Identity fields are populated best-effort by the hook sender, **locally and with no network call** (the fail-open contract): any missing tool, file, or claim leaves the field `null` and never blocks the prompt.

- **`user.id` / `user.name`** — the workstation login identity. `user.id` is the domain-qualified login from `whoami` (`DOMAIN\user` on Windows; the bare login on POSIX, where no domain source exists); `user.name` is the short login name. `user.email` is not used.
- **`agent_audit.agent.account.*` / `agent_audit.agent.organization.*`** — the AI-agent *provider* identity, read from the agent's local credential store. For **Codex CLI** that is `$CODEX_HOME/auth.json` (ChatGPT auth mode):
  - `account.id` ← `.tokens.account_id` (equals the `id_token` `chatgpt_account_id` claim; available without decoding the token).
  - `account.email` ← the `id_token` `email` claim; `account.name` ← the `id_token` `name` claim (the authenticated person).
  - `organization.id` / `organization.name` ← the `is_default` entry (fallback: first) of the `id_token` `https://api.openai.com/auth` → `organizations` array, mapping `.id` → `organization.id` and **`.title`** → `organization.name` (the claim has no `name` key — the human-readable label is `title`).
  - The `id_token` is a JWT whose payload (second `.`-separated segment) is base64url-decoded and read as JSON claims; it is **not** signature-verified (a local, trusted file). In API-key auth mode (no `id_token` / `tokens`) these fields stay `null`.

  For **Claude Code** the store is `~/.claude.json` — its `oauthAccount` object, **plain JSON (no JWT to decode)**: `account.id` ← `accountUuid`, `account.name` ← `displayName`, `account.email` ← `emailAddress`, `organization.id` ← `organizationUuid`, `organization.name` ← `organizationName`. Any missing key leaves the field `null` (API-key / unauthenticated sessions have no `oauthAccount`). Claude's `UserPromptSubmit` hook payload carries **no turn id**, so `agent_audit.turn_id` is `null` (`conversation_id` ← `session_id` still links to the OTLP session); the payload also has no model (model reaches only `SessionStart` hooks), consistent with `agent_audit.agent.model` having been dropped from the schema.

## Mapping and lifecycle

- Audit data stream mappings are strict by default. Unexpected fields should fail indexing rather than silently expanding the audit schema.
- `user.id`, `user.name`, `host.name`, `host.hostname`, `event.*`, `agent_audit.agent.*`, `agent_audit.conversation_id`, and `agent_audit.turn_id` are mapped as `keyword` where applicable.
- `agent_audit.user_prompt.text` is mapped as searchable `text` in the lab.
- `agent_audit.user_prompt.encrypted_text` is mapped as `keyword` with `index: false`; encrypted prompt bodies are stored but not searchable.
- `agent_audit.user_prompt.length` is mapped as `long`.
- `agent_audit.tool_call.tool.name` and `.tool.call_id` are mapped as `keyword`.
- `agent_audit.tool_call.input.text` and `.output.text` are mapped as **`wildcard`**, not `keyword` (a tool output over Lucene's ~32 KB term limit would reject the whole document) and not `text` (the audit need is substring / regexp over machine-generated JSON, not word relevance). The prompt body stays `text` because it is natural language — mapping follows data nature, so the two streams differ deliberately.
- `agent_audit.tool_call.input.encrypted_text` and `.output.encrypted_text` are mapped as `keyword` with `index: false`.
- `agent_audit.tool_call.input.length` and `.output.length` are mapped as `long`.
- Tool-call volume far exceeds user prompts (many per turn) and bodies are larger; the lab retains full bodies for now (no truncation), with `length` always recorded so size is known even if a body is later sealed or capped.
- Audit data streams should have configurable retention. The lab default retention is one month, after which documents may be deleted.

## Delivery and authorization

- User experience is prioritized over audit completeness. The lab assumes a non-adversarial model, so missing audit documents are acceptable when the destination is unavailable. This hook-audit is an (A)-scoped **visibility** tool, not a tamper-proof control: it is bypassable, fail-open, and forgeable by the audited user. See [`threat-model.md`](threat-model.md) "The direct hook → Elasticsearch audit path" for the full bypass surface and why compliance evidence belongs to provider-side capture instead.
- Hook delivery is fail-open: audit indexing failures must not block the agent interaction.
- Hook senders index directly to Elasticsearch for the initial implementation.
- Senders should use a very short HTTP timeout so unavailable destinations do not noticeably delay agent usage.
- Write credentials distributed to agent workstations should be scoped to the audit data stream and limited to create-only document ingestion. Index template, data stream, mapping, and lifecycle setup is performed by stack/admin setup, not by end-user hook credentials.
- The preferred Elasticsearch privilege for hook ingestion is `create_doc` on the audit data streams (`logs-agent_audit.user_prompt-*` and `logs-agent_audit.tool_call-*`); setup credentials, not hook credentials, own template/data-stream creation and mapping changes.

Hook delivery configuration lives in a hook-specific file rather than Codex's native `config.toml`:

```text
.codex/agent-audit.conf
```

Unlike Codex's `config.toml` (which Codex itself parses, so it must be TOML), this file is read **only by the capture hook scripts**, which must run on every employee workstation with **zero external dependencies** — no `jq`, no TOML parser. So the format is a flat `key=value` file (`.conf`) that both consumers parse natively: POSIX shells with a pure-`read` loop and PowerShell with the built-in `ConvertFrom-StringData`. `#` comment lines are ignored by both, dotted keys carry the structure, and values are untyped strings the hook interprets. `render-agent-audit.{sh,ps1}` fills `elasticsearch.url` from the stack's Elasticsearch base URL.

```ini
# capture.<stream>: enabled (true|false), content (plaintext|redacted|encrypted)
capture.user_prompt.enabled=true
capture.user_prompt.content=plaintext
capture.tool_call.enabled=true
capture.tool_call.content=plaintext

# elasticsearch: url/api_key/timeout_ms shared; data_stream is per stream
elasticsearch.url=https://...
elasticsearch.api_key=
elasticsearch.timeout_ms=300
elasticsearch.data_stream.user_prompt=logs-agent_audit.user_prompt-default
elasticsearch.data_stream.tool_call=logs-agent_audit.tool_call-default
```

Two layers are kept distinct: `capture.<stream>.*` is the **backend-agnostic capture posture** (whether to capture the stream, and how its body is stored), while `elasticsearch.*` is the **backend** — a shared connection plus a per-stream `data_stream` mapping. `content` is a per-stream enum: `plaintext` populates the body's `.text`; `redacted` puts a fixed `[REDACTED]` marker in `.text` (the true `.length` is still recorded and `.encrypted_text` stays `null`) so the delivery path — identity, routing, strict mapping, landing — can be verified without exposing prompt / tool content; `encrypted` sets `.text` to `null` and populates `.encrypted_text` (encryption itself is not yet built). `plaintext` is the lab default; `enabled = false` skips capture for that stream entirely.

**The config path is injected, not discovered.** The capture hooks take the config location as an explicit `--config <abs path>` argument (`-Config` on Windows); `render-hooks` substitutes the stack's absolute `agent-audit.conf` path into the hook `command` it writes to `config.toml`. A shipped hook does **no** ambient discovery — it never infers its config from the working directory, `CODEX_HOME`, or `$HOME`. This keeps delivery deterministic regardless of how Codex was launched, and prevents a stray project-local `.codex/agent-audit.conf` from silently redirecting or disabling audit (discovery → injection; see [`threat-model.md`](threat-model.md)). With no `--config`, the hook fail-open-skips. (`CODEX_HOME` is still consulted for the agent's own `auth.json` — the provider-identity source — which is the agent's credential store, not our config.)

If delivery later grows structured (encryption parameters, lists of redaction patterns) or moves into a distributed helper binary, the format may move to a structured one (TOML/JSON) at that point — today's flat `.conf` is dictated solely by the zero-dependency shell-parsing constraint. Keep each hook's config read behind a small seam so a future format/parser swap stays local; the schema above is the format-agnostic source of truth.
