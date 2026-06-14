#!/usr/bin/env bash
#
# capture-user-prompt.sh — Codex CLI UserPromptSubmit audit hook (POSIX/bash).
#
# PURPOSE — emit the canonical Agent Audit user-prompt document. Registered on
# Codex's `UserPromptSubmit` event (see ../scripts/render-hooks.sh and the stack
# setup.sh/.ps1), this fires once per submitted prompt, reshapes Codex's raw hook
# payload into the canonical `agent_audit.user_prompt` JSON document defined in
# SPEC/agent-audit.md, and appends it (one per line) to a stack-local NDJSON file.
# This is the exact shape that lands in `logs-agent_audit.user_prompt-default`;
# a later increment reads delivery config and POSTs it to Elasticsearch. For now
# it ONLY writes the local file — it does NOT POST anywhere and does NOT seal/
# encrypt (prompt text is captured in plaintext, lab mode).
#
# Field mapping (Codex raw payload -> canonical document):
#   .session_id  -> agent_audit.conversation_id   (Codex's session is the convo)
#   .turn_id     -> agent_audit.turn_id
#   .model       -> agent_audit.agent.model
#   .prompt      -> agent_audit.prompt.text  (+ .length = its character count)
#   agent.provider/name are constants ("openai" / "codex-cli").
#   user.* is best-effort: Codex's hook payload carries no user identity, so only
#   the runtime OS username is available (user.name); user.id/email stay null
#   until a richer identity source is wired in. cwd / transcript_path /
#   permission_mode are intentionally dropped — not part of the audit schema (and
#   cwd is PII), and the mapping is strict, so stray fields must not be emitted.
#
# CONTRACT — must never disturb the Codex session:
#   * Writes NOTHING to stdout. On UserPromptSubmit, stdout can be injected into
#     the model context or alter the prompt; ALL diagnostics go to stderr.
#   * ALWAYS exits 0 (best-effort, fire-and-forget). A missing tool, an
#     unwritable path, or a parse miss must never block prompt submission.
#
# Capture file: $CODEX_HOOK_CAPTURE_FILE, else
#   ${CODEX_HOME:-$HOME/.codex}/hook-captures/user-prompt-submit.ndjson
# Launching Codex as `CODEX_HOME=<stack>/.codex codex` (this stack's mechanism)
# makes that <stack>/.codex/hook-captures/user-prompt-submit.ndjson — the hook
# process inherits CODEX_HOME from the same environment that launched Codex.

set -u

log()   { echo "[capture-user-prompt] $*" >&2; }
done0() { exit 0; }   # every path is success — never block the prompt

capture_file=${CODEX_HOOK_CAPTURE_FILE:-${CODEX_HOME:-$HOME/.codex}/hook-captures/user-prompt-submit.ndjson}

payload=$(cat)
[ -n "$payload" ] || { log "empty stdin — nothing to capture"; done0; }

# Canonical shaping requires jq (the repo's standard JSON tool). Without it we
# cannot safely reshape arbitrary prompt text into valid JSON, so we skip the
# write rather than append a non-canonical line to the audit file.
command -v jq >/dev/null 2>&1 || { log "jq unavailable — cannot shape audit document; skipping"; done0; }

mkdir -p "$(dirname -- "$capture_file")" 2>/dev/null \
  || { log "cannot create capture dir for $capture_file — skipping"; done0; }

ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# Best-effort runtime identity (Codex's payload has none).
user_name=${USER:-${USERNAME:-$(id -un 2>/dev/null || echo "")}}

# Reshape raw Codex payload -> canonical agent_audit.user_prompt document.
record=$(printf '%s' "$payload" \
  | jq -c --arg ts "$ts" --arg uname "$user_name" \
      '{
        "@timestamp": $ts,
        event: { action: "user-prompt", created: $ts, dataset: "agent_audit.user_prompt", kind: "event" },
        user: { id: null, name: (if ($uname | length) > 0 then $uname else null end), email: null },
        agent_audit: {
          agent: { provider: "openai", name: "codex-cli", model: (.model // null) },
          conversation_id: (.session_id // null),
          turn_id: (.turn_id // null),
          prompt: { text: (.prompt // null), encrypted_text: null, length: ((.prompt // "") | length) }
        }
      }' 2>/dev/null) \
  || { log "payload not valid JSON — cannot shape audit document; skipping"; done0; }

printf '%s\n' "$record" >> "$capture_file" \
  || { log "append failed: $capture_file"; done0; }

log "captured 1 audit document -> $capture_file"
done0
