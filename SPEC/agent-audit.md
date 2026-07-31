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

The audit data streams are provisioned (strict templates + data streams) and viewed (cross-agent Kibana data views / saved searches) by the **`elastic-audit`** backend — Elasticsearch + Kibana, **no APM Server**, since audit is a direct hook → Elasticsearch write that never uses the OTLP / APM path. It is composed by `<agent>-elastic-audit` stacks (e.g. `codex-elastic-audit`), separate from the telemetry backend (`elastic` / `codex-elastic`): same local Elasticsearch technology, but a separate compose project, separate volumes, and a separate agent home (whose `.codex` carries `config.toml` — the inline `[hooks]` registrations plus the Elasticsearch MCP — and `agent-audit.conf`, but no `[otel]` config). The split keeps each stack's load-bearing set legible; the two stacks are alternatives, not run simultaneously.

**Asset inventory** (cross-agent, per stream `<s>` ∈ {`user_prompt`, `tool_call`}). ES assets live in `backends/services/elasticsearch/agent-audit/`, Kibana assets in `backends/services/kibana/agent-audit/` — the service component of the runtime that consumes each (see `SPEC.md` "Placement rule"):

| Asset | File | Loaded into |
|---|---|---|
| ILM policy | `logs-agent_audit.<s>-policy.ilm.json` | `_ilm/policy/logs-agent_audit.<s>-policy` |
| lifecycle component template | `logs-agent_audit.<s>@lifecycle.component.json` | `_component_template/…@lifecycle` (sets `index.lifecycle.name` only) |
| mappings component template | `logs-agent_audit.<s>@mappings.component.json` | `_component_template/…@mappings` (strict mappings) |
| index template | `logs-agent_audit.<s>.template.json` | `_index_template/…` — thin `composed_of: [@mappings, @lifecycle]` |
| data views | `data-views.ndjson` | Kibana saved objects |
| saved searches | `saved-searches.ndjson` | Kibana saved objects |

The ES importer applies by kind — **ilm → component templates → pipelines → index templates** — so composed/referenced objects exist first, then re-syncs the resolved composed mapping onto the live stream via `_simulate_index`. (Audit has no pipelines.) See `SPEC.md` "Lifecycle (ILM)".

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
      "name": "codex",
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
    "seal": { "key_id": null },
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
- `agent_audit.user_prompt.text` carries plaintext in the lab and is searchable; `content=encrypted` instead sets it to `[ENCRYPTED]` and seals the body into `agent_audit.user_prompt.encrypted_text` (see [Sealing](#sealing)).
- `agent_audit.agent.*` describes the AI agent application, not the ECS collecting agent.
- `agent_audit.agent.account.*` describes the AI agent provider account when available; it is read from the agent's local credential store (for Codex CLI, `$CODEX_HOME/auth.json` — see [Identity derivation](#identity-derivation)).
- `agent_audit.agent.organization.*` describes the AI agent provider organization / workspace / tenant context when available. It is parallel to `account`, not nested under it, and is read from the same local credential store (see [Identity derivation](#identity-derivation)).
- Standardized audit event names belong in `event.action`; user prompt submissions use `event.action: user-prompt`.
- Hook senders should construct near-final JSON documents before indexing. Ingest pipelines for audit streams should stay minimal: defaulting, validation, and routing are acceptable, but prompt redaction/encryption belongs in the sender.
- `logs-agent_audit.*` is access-controlled separately from OTel/APM telemetry indices. The intended production posture is that only audit-authorized users can read the audit data stream.

## Tool call documents

Tool call audit documents in `logs-agent_audit.tool_call-default` record one tool invocation each, captured from the agent's `PostToolUse` hook (which carries both the tool input and its result — Codex CLI and Claude Code both fire it). The canonical shape below shows the Codex provider constants; the only per-agent difference is `agent_audit.agent.provider` / `.name` (`openai` / `codex` for Codex, `anthropic` / `claude` for Claude Code):

```json
{
  "@timestamp": "...",
  "event": { "action": "tool-call", "created": "...", "dataset": "agent_audit.tool_call", "kind": "event" },
  "user": { "id": "...", "name": "..." },
  "host": { "name": "...", "hostname": "..." },
  "agent_audit": {
    "agent": {
      "provider": "openai", "name": "codex",
      "account": { "id": "...", "name": "...", "email": "..." },
      "organization": { "id": "...", "name": "..." }
    },
    "conversation_id": "...",
    "turn_id": "...",
    "seal": { "key_id": null },
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
- `agent_audit.tool_call.tool.name` ← the hook's `tool_name`; `tool.call_id` ← `tool_use_id` (the per-call id; also the join key to the OTLP tool-result span's `call_id` — `codex.tool_result` for Codex CLI).
- `agent_audit.tool_call.input` ← `tool_input`, `.output` ← `tool_response`. Both Codex fields are heterogeneous JSON (an object for MCP tools; a string or object for shell tools), so the sender **serializes each to a JSON string** into `.text`, with `.length` the character count. The strict mapping then sees one scalar per side, not the tool's arbitrary nested keys.
- `capture.tool_call.content = plaintext` populates `.text`; `redacted` writes a `[REDACTED]` marker; `encrypted` sets it to `[ENCRYPTED]` and seals the body into `.encrypted_text` (see [Sealing](#sealing)) — all keep the true `.length`, set per stream (the same gate as the prompt body — see [Delivery and authorization](#delivery-and-authorization)).
- No success / exit field — Codex's `tool_response` is opaque and not reliably parseable across tools.
- Source is the agent's `PostToolUse` hook **only** (it fires after completion with input + output). `conversation_id` ← `session_id`, `turn_id` ← `turn_id`; `cwd` / `transcript_path` / `permission_mode` are dropped (not in the schema; the mapping is strict). Both Codex CLI's and Claude Code's `PostToolUse` payloads carry `tool_use_id` and `turn_id`, so the tool-call document populates `tool.call_id` and `turn_id` for **both** agents — unlike Claude Code's turn-less `UserPromptSubmit`, whose user-prompt document always has `turn_id: null` (see [Identity derivation](#identity-derivation)).

## Identity derivation

Identity fields are populated best-effort by the hook sender, **locally and with no network call** (the fail-open contract): any missing tool, file, or claim leaves the field `null` and never blocks the prompt.

- **`user.id` / `user.name`** — the workstation login identity. `user.id` is the domain-qualified login from `whoami` (`DOMAIN\user` on Windows; the bare login on POSIX, where no domain source exists); `user.name` is the short login name. `user.email` is not used.
- **`agent_audit.agent.account.*` / `agent_audit.agent.organization.*`** — the AI-agent *provider* identity, read from the agent's local credential store. For **Codex CLI** that is `$CODEX_HOME/auth.json` (ChatGPT auth mode):
  - `account.id` ← `.tokens.account_id` (equals the `id_token` `chatgpt_account_id` claim; available without decoding the token).
  - `account.email` ← the `id_token` `email` claim; `account.name` ← the `id_token` `name` claim (the authenticated person).
  - `organization.id` / `organization.name` ← the `is_default` entry (fallback: first) of the `id_token` `https://api.openai.com/auth` → `organizations` array, mapping `.id` → `organization.id` and **`.title`** → `organization.name` (the claim has no `name` key — the human-readable label is `title`).
  - The `id_token` is a JWT whose payload (second `.`-separated segment) is base64url-decoded and read as JSON claims; it is **not** signature-verified (a local, trusted file). In API-key auth mode (no `id_token` / `tokens`) these fields stay `null`.

  For **Claude Code** the store is `~/.claude.json` — its `oauthAccount` object, **plain JSON (no JWT to decode)**: `account.id` ← `accountUuid`, `account.name` ← `displayName`, `account.email` ← `emailAddress`, `organization.id` ← `organizationUuid`, `organization.name` ← `organizationName`. Any missing key leaves the field `null` (API-key / unauthenticated sessions have no `oauthAccount`). Claude's `UserPromptSubmit` hook payload carries **no turn id**, so the user-prompt document's `agent_audit.turn_id` is `null` (`conversation_id` ← `session_id` still links to the OTLP session); the payload also has no model (model reaches only `SessionStart` hooks), consistent with `agent_audit.agent.model` having been dropped from the schema. This turn-less property is specific to `UserPromptSubmit`: Claude Code's `PostToolUse` payload **does** carry `turn_id` (and `tool_use_id`), so the tool-call document populates `agent_audit.turn_id` and `tool_call.tool.call_id` (see [Tool call documents](#tool-call-documents)).

## Mapping and lifecycle

Mappings are **strict** by default — an unexpected field fails indexing rather than silently expanding the audit schema. They are **not** inlined in the index template: each stream's strict mappings live in a dedicated `@mappings` **component template**, and the `logs-agent_audit.*` index template is a thin `composed_of: [<stream>@mappings, <stream>@lifecycle]`. This mirrors the telemetry side (per-agent templates compose APM's managed component templates) so *every* index template in the lab is a composition, never an inline blob.

| Field(s) | Type | Note |
|---|---|---|
| `user.id` / `.name`, `host.name` / `.hostname`, `event.*`, `agent_audit.agent.*`, `agent_audit.conversation_id` / `.turn_id`, `agent_audit.seal.key_id` | `keyword` | where applicable; `seal.key_id` is the recipient epoch or `null` |
| `agent_audit.user_prompt.text` | **`wildcard`** | holds the prompt, `[REDACTED]`, or `[ENCRYPTED]`; substring/regexp |
| `agent_audit.user_prompt.encrypted_text` | **`binary`** | base64 CMS; stored, not searchable |
| `agent_audit.user_prompt.length` | `long` | |
| `agent_audit.tool_call.tool.name` / `.call_id` | `keyword` | |
| `agent_audit.tool_call.input.text` / `.output.text` | **`wildcard`** | not `keyword` (a tool output over Lucene's ~32 KB term limit rejects the whole doc) and not `text` (the need is substring/regexp over machine-generated JSON, not word relevance) |
| `agent_audit.tool_call.input.encrypted_text` / `.output.encrypted_text` | **`binary`** | base64 CMS; stored, not searchable |
| `agent_audit.tool_call.input.length` / `.output.length` | `long` | |

Both `.text` body fields are `wildcard` — substring/regexp over machine-generated tool JSON, and a prompt body that may be large or carry an `[ENCRYPTED]` / `[REDACTED]` marker, each indexed without risking Lucene's ~32 KB term limit; the sealed bodies are `binary` (opaque base64 CMS, not searchable). Tool-call volume far exceeds user prompts (many per turn) and bodies are larger; the lab retains full bodies for now (no truncation), with `length` always recorded so size is known even if a body is sealed or capped.

Audit data streams are retained by **ILM**, not DSL: each template carries no `data_retention` and attaches its own lifecycle component template via `composed_of`, so production can add warm/cold/frozen + searchable-snapshot phases without re-plumbing. **`user_prompt` and `tool_call` get separate policies** (so the higher-volume tool-call stream can age differently); both default to **hot → delete at 3 days**. See `SPEC.md` "Lifecycle (ILM)".

## Delivery and authorization

- User experience is prioritized over audit completeness. The lab assumes a non-adversarial model, so missing audit documents are acceptable when the destination is unavailable. This hook-audit is an (A)-scoped **visibility** tool, not a tamper-proof control: it is bypassable, fail-open, and forgeable by the audited user. See [`threat-model.md`](threat-model.md) "The direct hook → Elasticsearch audit path" for the full bypass surface and why compliance evidence belongs to provider-side capture instead.
- Hook delivery is fail-open: audit indexing failures must not block the agent interaction.
- Hook senders index directly to Elasticsearch for the initial implementation.
- Senders should use a very short HTTP timeout so unavailable destinations do not noticeably delay agent usage.
- Write credentials distributed to agent workstations should be scoped to the audit data stream and limited to create-only document ingestion. Index template, data stream, mapping, and lifecycle setup is performed by stack/admin setup, not by end-user hook credentials.
- The preferred Elasticsearch privilege for hook ingestion is `create_doc` on the audit data streams (`logs-agent_audit.user_prompt-*` and `logs-agent_audit.tool_call-*`); setup credentials, not hook credentials, own template/data-stream creation and mapping changes.

**Managed (org-enforced) deployment of the audit hooks is available.** Beyond the per-project `local`/`project` scopes, the audit stacks' `agent-config place --scope managed` enforces the hooks host-globally (their conf carries only `agent_audit.*` keys — an audit-only managed deploy). It materializes the hook bundle to a stable host location and pins it (Claude: an owner-scoped `hooks/<tool>/` dir under the managed root, pinned by the `managed-settings.d/10-<tool>.json` fragment whose only content is the `hooks` block — no telemetry `env`; Codex: the first-class `managed_dir`, pointed at the same owner-scoped dir and pinned by `requirements.toml` with no `managed_config.toml`). Placement is **host-global, interactive, and marker-aware** (the same deploy-only, never-overwrite, sidecar-marker model as telemetry managed; teardown is `agent-config teardown --scope managed`). Because there is no OTLP logs endpoint, the marker/ownership keys on the audit ES url. **Caveat:** confirm on a real host that an absolute hook `command` path works under the host managed root — the macOS space (`/Library/Application Support/ClaudeCode`) and Windows `Program Files` paths. See [`config-deployment.md`](config-deployment.md) "Managed materialize".

Hook delivery configuration lives in a hook-specific file rather than Codex's native `config.toml`:

```text
.codex/hooks/agent-audit.conf
```

Unlike Codex's `config.toml` (which Codex itself parses, so it must be TOML), this file is read **only by the capture hook scripts**, which must run on every employee workstation with **zero external dependencies** — no `jq`, no TOML parser. So the format is a flat `key=value` file (`.conf`) that both consumers parse natively: POSIX shells with a pure-`read` loop and PowerShell with the built-in `ConvertFrom-StringData`. `#` comment lines are ignored by both, dotted keys carry the structure, and values are untyped strings the hook interprets. The rendered values come from the stack's `setup.conf` (see below), substituted into the template by `agent-config`.

```ini
# capture.<stream>: enabled (true|false), content (plaintext|redacted|encrypted)
capture.user_prompt.enabled=true
capture.user_prompt.content=plaintext
capture.tool_call.enabled=true
capture.tool_call.content=plaintext

# seal: applies when content=encrypted (empty recipients_file = off)
seal.recipients_file=
seal.key_id=
seal.compress_min_bytes=512

# elasticsearch: url/api_key/timeout_ms shared; data_stream is per stream
elasticsearch.url=https://...
elasticsearch.api_key=
elasticsearch.timeout_ms=2000
elasticsearch.data_stream.user_prompt=logs-agent_audit.user_prompt-default
elasticsearch.data_stream.tool_call=logs-agent_audit.tool_call-default
```

The rendered values have a single source of truth in the stack's `setup.conf` (see [`config-deployment.md`](config-deployment.md)). The **audit posture, delivery endpoint, and timeout** are **required** `agent_audit.*` keys there — `agent_audit.elasticsearch.url`, `agent_audit.elasticsearch.timeout_ms`, and `agent_audit.capture.{user_prompt,tool_call}.{enabled,content}` — read fail-fast by `agent-config` (missing or empty → the run aborts; there is **no** fallback to the control-plane `elasticsearch.url`, so the audit delivery endpoint is configured independently of the MCP/backend endpoint). The **`elasticsearch.api_key`** is a secret and is the one rendered value that is **not** in `setup.conf`: it is read from a gitignored `setup.local.conf` (copied from the committed `setup.local.conf.example`) if present, and is **empty with no error** when that file or the key is absent — the local demo backend has security disabled, so an empty key is the working default. The `elasticsearch.data_stream.*` lines are **not** `setup.conf` keys: they are backend-coupled and stay **fixed in the template**.

Two layers are kept distinct: `capture.<stream>.*` is the **backend-agnostic capture posture** (whether to capture the stream, and how its body is stored), while `elasticsearch.*` is the **backend** — a shared connection plus a per-stream `data_stream` mapping. `content` is a per-stream enum: `plaintext` populates the body's `.text`; `redacted` puts a fixed `[REDACTED]` marker in `.text` (the true `.length` is still recorded and `.encrypted_text` stays `null`) so the delivery path — identity, routing, strict mapping, landing — can be verified without exposing prompt / tool content; `encrypted` sets `.text` to `[ENCRYPTED]` and seals the body into `.encrypted_text` (the reserved, `index:false` body field) — see [Sealing](#sealing). `plaintext` is the lab default; `enabled = false` skips capture for that stream entirely. Edge sealing is opt-in via **optional** `setup.conf` keys — `agent_audit.seal.epoch`, plus `agent_audit.seal.recipients_root` (where epochs live) and `agent_audit.seal.recipients_file` (a full-path override) as overrides; absent/empty = off.

**The config path is injected, not discovered.** The capture hooks take the config location as an explicit `--config <abs path>` argument (`-Config` on Windows); the rendered hook registration bakes the stack's absolute `agent-audit.conf` path into the hook `command` written to `config.toml`. A shipped hook does **no** ambient discovery — it never infers its config from the working directory, `CODEX_HOME`, or `$HOME`. This keeps delivery deterministic regardless of how Codex was launched, and prevents a stray project-local `.codex/agent-audit.conf` from silently redirecting or disabling audit (discovery → injection; see [`threat-model.md`](threat-model.md)). With no `--config`, the hook fail-open-skips. (`CODEX_HOME` is still consulted for the agent's own `auth.json` — the provider-identity source — which is the agent's credential store, not our config.)

If delivery later grows structured (encryption parameters, lists of redaction patterns) or moves into a distributed helper binary, the format may move to a structured one (TOML/JSON) at that point — today's flat `.conf` is dictated solely by the zero-dependency shell-parsing constraint. Keep each hook's config read behind a small seam so a future format/parser swap stays local; the schema above is the format-agnostic source of truth.

## Sealing

When a stream's `content=encrypted`, the hook seals the body (the user prompt text, or each tool-call input/output) with **CMS / PKCS#7 enveloped-data** before it leaves the edge, so Elasticsearch holds only ciphertext plus cleartext metadata. Each message gets a fresh AES-256 content key RSA-wrapped to the recipient's public cert; a 1-byte framing tag *inside* the sealed payload records the body encoding (`0x00` raw, `0x01` gzip — gzip applied when the body reaches `seal.compress_min_bytes`), and the DER output is base64'd into `encrypted_text`. `agent_audit.seal.key_id` carries the recipient **epoch** when a body was sealed and is `null` otherwise; the record shape is constant across all content modes (the `seal.key_id` field is always present, `encrypted_text` always reserved).

**Central key lifecycle.** The only secret is the recipient **private key**, held centrally — it never ships. `sealing/scripts/new-recipient.sh` issues an epoch keypair (`recipients/<epoch>/recipient.pem` public, `private/<epoch>/private.key` secret; both gitignored), and only the public `recipient.pem` is distributed into edge bundles; `sealing/scripts/decrypt.sh` recovers a body centrally (by epoch, or trying all private keys). The cert CN encodes the epoch (`CN=agent-audit-recipient-<epoch>`), and the same PEM is read by both crypto backends: `openssl cms` on Linux/macOS, .NET `System.Security.Cryptography.Pkcs.EnvelopedCms` on Windows (built into stock PowerShell incl. 5.1 — **not** `Protect-CmsMessage`, which cannot seal binary without a plaintext temp file). Both produce interoperable CMS that `decrypt.sh` opens.

**Opt-in resolution.** At setup `agent-config` resolves `seal.epoch` to its public cert (`src/seal.rs`) — `<recipients_root>/<epoch>/recipient.pem`, or the `seal.recipients_file` override (a public `.pem`, rejected if under `sealing/private/`). All three seal paths resolve **relative to the `setup.conf` that names them** (never the invoker's cwd or the tool's own location); `recipients_root` defaults to `sealing/recipients` beside the conf, and the lab's audit stacks set it to `../../sealing/recipients` (the repo root's sealing area). The tool then verifies the cert CN equals the epoch and materializes it into the bundle as `recipient.pem`; the rendered conf's `seal.recipients_file` points at the placed cert (POSIX path for the `.sh` runtime, `C:/`-style forward-slash for the `.ps1` runtime) and `seal.key_id` is the epoch. `content=encrypted` with no epoch is a hard setup failure. The same resolved `(cert, key_id)` flows to every scope, and every scope uses the **same `hooks/`-relative bundle layout**: the conf (`agent-audit.conf`) and the cert (`recipient.pem`) sit **inside the `hooks/` dir** alongside the hook entry and its `lib/`, never at the agent-home / managed root — local/project place that `hooks/` into the agent home (`.claude/hooks/`, `.codex/hooks/`), managed stages it under an owner-scoped dir beneath the host root (`/etc/claude-code/hooks/<tool>/`, `/etc/codex/hooks/<tool>/`) — the extra level exists only for managed, where the root is machine-global and shared with other owners. Only the agent's own settings file lives at the root (`settings.local.json` / Codex `config.toml`; for Claude managed, the fragment sits one level down in `managed-settings.d/`). Wherever the conf lands, its absolute path is what the rendered hook registration injects as `--config`, and the placed cert's absolute path is what the rendered conf's `seal.recipients_file` points at.

**Confidentiality fails closed (invariant).** Under `content=encrypted` the body's `.text` is set to `[ENCRYPTED]` *before* any sealing is attempted, so a seal failure degrades to **metadata-only** (`encrypted_text` and `seal.key_id` `null`) — plaintext is never emitted to Elasticsearch, logs, or stderr, and the hook still exits 0 (fail-open delivery). At runtime, once per invocation, the hook verifies the bundled cert's CN epoch equals the configured `seal.key_id`; a mismatch (a cert that drifted or was swapped after deploy) is treated as untrusted and also degrades to metadata-only, so a body is only ever sealed to the configured recipient or not at all. Empty epoch is off: no cert ships, the seal fields stay empty, and the crypto path is inert (the record keeps its constant shape with `seal.key_id` `null`).

**OS bundle.** Each edge bundle ships only the runtime OS's hook scripts (`.sh` on Linux/macOS, `.ps1` on Windows); the non-matching shell's scripts are not copied. Codex's `config.toml` still lists both `command`/`commandWindows`, but its platform dispatch runs only the OS-matching one, so the other points at an absent-but-never-invoked path.

**Body canonicalization.** For `tool_call`, the sealed bytes are not byte-identical across shells — the POSIX hook seals the raw captured JSON substring, while PowerShell seals a re-serialized (compacted) form. Both decrypt to equivalent JSON; the difference is inherited from how the plaintext `.text` is populated and predates sealing. `user_prompt` has no such difference (both seal the raw unescaped prompt text).

## Hook implementation contract

The capture hooks are the lab's real ship artifact, so they are written as **humble entry scripts over a shared library** — not monolithic scripts. The explanation that would otherwise be inline comments lives here, so the scripts carry **no narrative comments** (tool directives like `# shellcheck` aside), and names — functions *and* variables — are spelled out in full (`escaped_prompt`, `account_id`, `prompt_length`, `input_raw`); only loop variables stay terse.

- **Humble entry, one per agent.** Each agent has a **single** `agent-audit.{sh,ps1}` entry (not one file per stream) that holds no implementation: the sourced library and a top-to-bottom sequence of verb-named calls that reads as the procedure itself — `parse_args`, `require_stream`, `require_config`, `require_tools`, `load_delivery_config`, `require_stream_enabled`, `read_hook_payload`, `build_audit_document`, `deliver_document` (PowerShell uses the parallel `Verb-Noun` form). The stream is selected at the **process boundary** by `--stream <user_prompt|tool_call>` (alongside the injected `--config`); `parse_args` only parses, and all validation lives in the `require_*` guards — `require_stream` (valid value), `require_config` (provided **and** the file exists). The stream is then **passed explicitly** to the steps that need it (`load_delivery_config "$stream"`, …), so each step's dependency is visible at the call site, and `load_delivery_config` is a pure reader (it only checks the *contents* — a missing `elasticsearch.url` / `data_stream`). The `--stream` token matches the `agent-audit.conf` keys and the dataset name (`user_prompt` / `tool_call`, underscore), so no translation layer is needed; the log tag carries the stream (`[agent-audit user_prompt]`).
- **Shared core + per-agent adapter.** The library is split: a **single shared core** (config parsing, the JSON helpers, document assembly, delivery, the fail-open harness) lives once in the repo, and a **thin per-agent adapter** supplies only what varies — the `provider` / `agent_name` constants and `derive_runtime_identity`. The core reads payload fields **uniformly** and an absent field becomes `null` (so Claude's `UserPromptSubmit`, which carries no `turn_id`, yields `turn_id: null` with no special-casing), so the core holds **no** agent-specific knowledge. The entry sources both; the core is not duplicated per agent. (If a future agent's payload used different field *names*, a field map would move to the adapter — not needed today, since both agents share `prompt` / `session_id` / `tool_name` / `tool_use_id` / `tool_input` / `tool_response` / `turn_id`.)
- **Shared location & shipping.** The core lives once under a non-agent shared area (`components/agents/shared/agent-audit/lib/`); each agent's `hooks/lib/` holds only its adapter, and the agent's `hooks/agent-audit.{sh,ps1}` entry sources both by a path relative to itself. The rendered hook registration points **both** hook events at that single entry, differing only by the `--stream` argument it injects (`UserPromptSubmit` → `--stream user_prompt`, `PostToolUse` → `--stream tool_call`). The agent is the ownership/deployment boundary: a fleet deploy unit is the agent's `hooks/` plus the shared core it sources (a packaging concern).
- **Zero external dependencies.** POSIX builds the document with `awk` JSON helpers (`json::string_field`, `json::raw_value`, `json::escape`, `json::char_count` — no `jq`); PowerShell uses the built-in `ConvertFrom-Json` / `ConvertTo-Json`. The per-shell asymmetry is contained inside the core.
- **Session-safety invariants (non-negotiable).** The hook must never disturb the agent session: it writes **nothing to stdout** (UserPromptSubmit stdout can be injected into model context — all diagnostics go to stderr), **always exits 0** (a missing tool / missing config / unreachable Elasticsearch / parse miss / **unknown stream** is a fail-open skip, never a block — the stream dispatch is an explicit `user_prompt` / `tool_call` / else-skip, not a binary fallthrough), and POSTs with a **very short timeout** (its default is a single named constant kept in step with the shipped `agent-audit.conf` value; `elasticsearch.url` / `data_stream` have no sane default and skip when absent). Guards short-circuit to a logged exit-0 skip from inside the core.
- **Two independent timeouts; only one of them is a latency dial.** `elasticsearch.timeout_ms` bounds the POST and is what keeps the typical path fast; the **harness hook timeout** (Claude's `hooks[].timeout`, Codex's `timeout`) kills the hook process and drops that delivery. What dominates a hook run is not the POST but process start plus shell/.NET init — a *successful* Windows PowerShell 5.1 delivery to a loopback endpoint measures **~1.1 s**, of which ~640 ms is cold `Invoke-RestMethod` client init and only ~40 ms the request itself, against a **~3.7 s** median observed under real session load (concurrent `PostToolUse` hooks, AV scanning, disk/CPU contention). A *failing* delivery additionally spends the whole `elasticsearch.timeout_ms`, putting the same host's failure path near **~2.9 s** idle and correspondingly worse under load — that spread is what the harness value has to absorb. `pwsh` is *slower* to start than `powershell`, so the shell is not the lever. The harness value is therefore set as a **generous safety net for OS-level stalls, not tuned near the median**: a run that finishes fast costs nothing, so headroom is nearly free, while a value close to the median silently drops most deliveries. Both agents' templates use **10 s**.
- **`elasticsearch.timeout_ms` is 2 s, and it is the dial that is actually paid.** It bounds the whole HTTP request — connect included — and is spent in full, once per prompt and once per tool call, whenever the destination does not answer. **Do not assume an unreachable port fails fast:** on the measured Windows host a closed *loopback* port returns `ConnectionRefused` only after **~2.0 s** (endpoint-protection software delaying the RST — an open port connects in 18 ms), so the ordinary *lab stack is down* case pays the timeout in full instead of erroring immediately. Moving 1 s → 2 s therefore costs a real **+1 s per prompt and per tool call** on such a host whenever the backend is down; this dial is chosen deliberately, not generously. What it buys is invisible from loopback: one process per hook means no connection or TLS-session reuse, so a remote Elasticsearch pays a full handshake plus RTT on *every* POST, and a loaded cluster can stall on ingest backpressure past a second. The success path needs none of it — the request against loopback is 30–40 ms, and PowerShell's ~640 ms of cold `Invoke-RestMethod` client init falls **outside** the timeout window (a POST with `-TimeoutSec 0.3` succeeds while wall-clock is ~680 ms, because `HttpWebRequest.Timeout` covers only request/response). Payload size is not a factor either: a 500 KB body costs the same as a 100-byte one (~640 ms cold, ~40 ms warm), so untruncated `tool_call` bodies are not an argument for a longer timeout. A deployment on a fast local backend can safely halve it — the `setup.conf` key exists so this stays a per-deployment call. **The shipped `agent-audit.conf` value and the `default_timeout_ms` / `$DefaultTimeoutMs` constant in both cores move together.** (For scale: the POSIX flavor's entire cold `curl` process **and** request is 128–191 ms, ~4x cheaper than PowerShell's client init alone.)
