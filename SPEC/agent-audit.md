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
      "model": "gpt-5.5",
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
    "prompt": {
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
- `agent_audit.prompt.text` carries plaintext in the lab and is searchable. Production-oriented audit flows may set it to `null` and populate `agent_audit.prompt.encrypted_text` with application-encrypted prompt content instead.
- `agent_audit.agent.*` describes the AI agent application, not the ECS collecting agent.
- `agent_audit.agent.account.*` describes the AI agent provider account when available; it is read from the agent's local credential store (for Codex CLI, `$CODEX_HOME/auth.json` — see [Identity derivation](#identity-derivation)).
- `agent_audit.agent.organization.*` describes the AI agent provider organization / workspace / tenant context when available. It is parallel to `account`, not nested under it, and is read from the same local credential store (see [Identity derivation](#identity-derivation)).
- Standardized audit event names belong in `event.action`; user prompt submissions use `event.action: user-prompt`.
- Hook senders should construct near-final JSON documents before indexing. Ingest pipelines for audit streams should stay minimal: defaulting, validation, and routing are acceptable, but prompt redaction/encryption belongs in the sender.
- `logs-agent_audit.*` is access-controlled separately from OTel/APM telemetry indices. The intended production posture is that only audit-authorized users can read the audit data stream.

## Identity derivation

Identity fields are populated best-effort by the hook sender, **locally and with no network call** (the fail-open contract): any missing tool, file, or claim leaves the field `null` and never blocks the prompt.

- **`user.id` / `user.name`** — the workstation login identity. `user.id` is the domain-qualified login from `whoami` (`DOMAIN\user` on Windows; the bare login on POSIX, where no domain source exists); `user.name` is the short login name. `user.email` is not used.
- **`agent_audit.agent.account.*` / `agent_audit.agent.organization.*`** — the AI-agent *provider* identity, read from the agent's local credential store. For **Codex CLI** that is `$CODEX_HOME/auth.json` (ChatGPT auth mode):
  - `account.id` ← `.tokens.account_id` (equals the `id_token` `chatgpt_account_id` claim; available without decoding the token).
  - `account.email` ← the `id_token` `email` claim; `account.name` ← the `id_token` `name` claim (the authenticated person).
  - `organization.id` / `organization.name` ← the `is_default` entry (fallback: first) of the `id_token` `https://api.openai.com/auth` → `organizations` array, mapping `.id` → `organization.id` and **`.title`** → `organization.name` (the claim has no `name` key — the human-readable label is `title`).
  - The `id_token` is a JWT whose payload (second `.`-separated segment) is base64url-decoded and read as JSON claims; it is **not** signature-verified (a local, trusted file). In API-key auth mode (no `id_token` / `tokens`) these fields stay `null`.

## Mapping and lifecycle

- Audit data stream mappings are strict by default. Unexpected fields should fail indexing rather than silently expanding the audit schema.
- `user.id`, `user.name`, `host.name`, `host.hostname`, `event.*`, `agent_audit.agent.*`, `agent_audit.conversation_id`, and `agent_audit.turn_id` are mapped as `keyword` where applicable.
- `agent_audit.prompt.text` is mapped as searchable `text` in the lab.
- `agent_audit.prompt.encrypted_text` is mapped as `keyword` with `index: false`; encrypted prompt bodies are stored but not searchable.
- `agent_audit.prompt.length` is mapped as `long`.
- Audit data streams should have configurable retention. The lab default retention is one month, after which documents may be deleted.

## Delivery and authorization

- User experience is prioritized over audit completeness. The lab assumes a non-adversarial model, so missing audit documents are acceptable when the destination is unavailable.
- Hook delivery is fail-open: audit indexing failures must not block the agent interaction.
- Hook senders index directly to Elasticsearch for the initial implementation.
- Senders should use a very short HTTP timeout so unavailable destinations do not noticeably delay agent usage.
- Write credentials distributed to agent workstations should be scoped to the audit data stream and limited to create-only document ingestion. Index template, data stream, mapping, and lifecycle setup is performed by stack/admin setup, not by end-user hook credentials.
- The preferred Elasticsearch privilege for hook ingestion is `create_doc` on `logs-agent_audit.user_prompt-*`; setup credentials, not hook credentials, own template/data-stream creation and mapping changes.

Hook delivery configuration lives in a hook-specific file rather than Codex's native `config.toml`:

```text
.codex/agent-audit.toml
```

Initial configuration shape:

```toml
[elasticsearch]
url = "https://..."
data_stream = "logs-agent_audit.user_prompt-default"
api_key = "..."
timeout_ms = 300

[audit]
mode = "plaintext"
```

`audit.mode` controls prompt body handling. The lab starts with `plaintext`, which populates `agent_audit.prompt.text`. Production-oriented flows may add an encrypted mode that sets `agent_audit.prompt.text` to `null` and populates `agent_audit.prompt.encrypted_text`.
