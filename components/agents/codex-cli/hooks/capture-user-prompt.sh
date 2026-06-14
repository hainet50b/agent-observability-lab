#!/usr/bin/env bash
#
# capture-user-prompt.sh — Codex CLI UserPromptSubmit characterization hook (POSIX/bash).
#
# PURPOSE — CHARACTERIZATION, NOT production audit. Registered on Codex's
# `UserPromptSubmit` event (see ../scripts/render-hooks.sh and the stack
# setup.sh/.ps1), this fires once per submitted prompt and appends the RAW stdin
# payload — plus a best-effort extracted `prompt` field — to a stack-local
# NDJSON file. The point is to discover the EXACT key names Codex delivers:
# the prompt text and any session / conversation / turn correlation fields,
# which a later production-audit increment will rely on. It does NOT POST
# anywhere, does NOT write to `prompts-audit`, and does NOT seal/encrypt.
# (Contrast the Claude Code capture-prompt.{sh,ps1}, which ships to Elasticsearch.)
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

mkdir -p "$(dirname -- "$capture_file")" 2>/dev/null \
  || { log "cannot create capture dir for $capture_file — skipping"; done0; }

ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# Happy path: jq embeds the raw payload as a parsed object and lifts the
# best-effort prompt, giving one self-describing NDJSON record per submit.
if command -v jq >/dev/null 2>&1 \
   && record=$(printf '%s' "$payload" \
        | jq -c --arg ts "$ts" \
            '{captured_at:$ts, hook:"codex.UserPromptSubmit", prompt:(.prompt // null), raw:.}' 2>/dev/null); then
  printf '%s\n' "$record" >> "$capture_file" \
    || { log "append failed: $capture_file"; done0; }
else
  # Degraded (no jq, or payload was not valid JSON): persist the raw payload
  # verbatim as one line — still captures the keys, just without the wrapper
  # or the extracted prompt.
  log "jq unavailable or payload not JSON — writing raw payload verbatim"
  printf '%s\n' "$payload" >> "$capture_file" \
    || { log "append failed: $capture_file"; done0; }
fi

log "captured 1 record -> $capture_file"
done0
