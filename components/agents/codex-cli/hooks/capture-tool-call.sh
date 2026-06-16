#!/usr/bin/env bash
#
# capture-tool-call.sh — Codex CLI PostToolUse characterization hook (POSIX/bash).
#
# PURPOSE — CHARACTERIZATION, NOT production audit. Registered on Codex's
# `PostToolUse` event (see ../scripts/render-hooks.sh and the stack
# setup.sh/.ps1), this fires once per completed tool call and appends the RAW
# stdin payload — plus best-effort extracted `tool_name` / `tool_use_id` /
# `tool_input` / `tool_response` fields — to a stack-local NDJSON file. The
# point is to discover the EXACT key names Codex delivers for a tool call:
# the tool identity, the call-correlation id, the input arguments, and the
# response/output, which a later production-audit increment (tool-result
# capture) will rely on. It does NOT POST anywhere, does NOT write to any audit
# stream, and does NOT seal/encrypt. (Contrast capture-user-prompt.{sh,ps1},
# the production UserPromptSubmit audit hook that ships to Elasticsearch.)
#
# CONTRACT — must never disturb the Codex session:
#   * Writes NOTHING to stdout. On a hook event, stdout can be injected into
#     the model context or alter behaviour; ALL diagnostics go to stderr.
#   * ALWAYS exits 0 (best-effort, fire-and-forget). A missing tool, an
#     unwritable path, or a parse miss must never block the tool call.
#
# Capture file: $CODEX_HOOK_CAPTURE_FILE, else
#   ${CODEX_HOME:-$HOME/.codex}/hook-captures/tool-call.ndjson
# Launching Codex as `CODEX_HOME=<stack>/.codex codex` (this stack's mechanism)
# makes that <stack>/.codex/hook-captures/tool-call.ndjson — the hook process
# inherits CODEX_HOME from the same environment that launched Codex.
#
# The four extracted keys are best-effort GUESSES (Codex may name them
# differently than Claude Code's PostToolUse); when a guess misses, the field is
# null and the truth is still in `raw`. That mismatch is exactly what this hook
# exists to surface — compare `raw` against the extracted fields after a real
# shell tool call and a real MCP tool call.

set -u

log()   { echo "[capture-tool-call] $*" >&2; }
done0() { exit 0; }   # every path is success — never block the tool call

capture_file=${CODEX_HOOK_CAPTURE_FILE:-${CODEX_HOME:-$HOME/.codex}/hook-captures/tool-call.ndjson}

payload=$(cat)
[ -n "$payload" ] || { log "empty stdin — nothing to capture"; done0; }

mkdir -p "$(dirname -- "$capture_file")" 2>/dev/null \
  || { log "cannot create capture dir for $capture_file — skipping"; done0; }

ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# Happy path: jq embeds the raw payload as a parsed object and lifts the
# best-effort tool fields, giving one self-describing NDJSON record per call.
if command -v jq >/dev/null 2>&1 \
   && record=$(printf '%s' "$payload" \
        | jq -c --arg ts "$ts" \
            '{captured_at:$ts, hook:"codex.PostToolUse", tool_name:(.tool_name // null), tool_use_id:(.tool_use_id // null), tool_input:(.tool_input // null), tool_response:(.tool_response // null), raw:.}' 2>/dev/null); then
  printf '%s\n' "$record" >> "$capture_file" \
    || { log "append failed: $capture_file"; done0; }
else
  # Degraded (no jq, or payload was not valid JSON): persist the raw payload
  # verbatim as one line — still captures the keys, just without the wrapper
  # or the extracted fields.
  log "jq unavailable or payload not JSON — writing raw payload verbatim"
  printf '%s\n' "$payload" >> "$capture_file" \
    || { log "append failed: $capture_file"; done0; }
fi

log "captured 1 record -> $capture_file"
done0
