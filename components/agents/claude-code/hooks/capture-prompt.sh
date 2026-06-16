#!/usr/bin/env bash
#
# capture-prompt.sh — Claude Code UserPromptSubmit audit hook (POSIX/bash).
#
# Registered on the `UserPromptSubmit` event (see the stack README), this fires
# once per submitted prompt. Claude Code delivers the event as JSON on stdin:
#   { session_id, transcript_path, cwd, permission_mode, hook_event_name, prompt }
# The prompt is the FULL, unredacted text (the hook captures at the source,
# before any OTEL_LOG_USER_PROMPTS redaction/truncation applies).
#
# It builds a {ts, agent, user_email, organization, session_id, hostname, prompt}
# document ENTIRELY ON THE ENDPOINT and POSTs it straight to the `prompts-audit`
# Elasticsearch index — a path **independent of the OTLP analytics pipeline**
# (no APM Server / Collector). Building the document locally (rather than letting
# a server-side ingest pipeline reshape a raw payload) is what keeps the door
# open for **local sealing**: a later phase swaps the plaintext `prompt` for a
# `prompt_cipher` produced by `openssl cms` here, before anything leaves the box.
#
# ZERO EXTERNAL DEPENDENCIES beyond what ships with the OS — for fleet rollout to
# machines with "nothing installed": `curl` (transport) and `awk` (a POSIX base
# tool; used to lift JSON string values without jq). `cwd` is intentionally NOT
# captured — it is PII (paths leak project / client / user names); if location
# context is ever wanted it joins the sealed content, not the plaintext envelope.
#
# Identity is not in the hook payload, so it is resolved locally from
# ~/.claude.json (.oauthAccount.emailAddress / .organizationName). `session_id`
# equals the OTLP `session.id`, so an audit document joins back to that session's
# analytics telemetry.
#
# CONTRACT — must not disturb the session:
#   * Writes NOTHING to stdout. On UserPromptSubmit, stdout on exit 0 is injected
#     into the model's context; diagnostics go to stderr only.
#   * ALWAYS exits 0 (best-effort, fire-and-forget). ES down / missing tool /
#     parse miss all leave the user's prompt unblocked.
#   * curl uses a short --max-time so a stalled endpoint can't hang the prompt.
#
# Override the audit endpoint with PROMPTS_AUDIT_ES_URL (default below).
# NOTE: plaintext phase — the prompt is stored as searchable text. Local sealing
# (prompt -> prompt_cipher) is the next phase; don't run real-secret sessions
# against a shared store until then.

ES_URL=${PROMPTS_AUDIT_ES_URL:-http://localhost:9200}
INDEX=prompts-audit
CLAUDE_CONFIG=${CLAUDE_CONFIG:-$HOME/.claude.json}

log() { echo "[capture-prompt] $*" >&2; }
done0() { exit 0; } # every exit path is success — never block the prompt

# Dependencies: degrade gracefully rather than break the session.
command -v curl >/dev/null 2>&1 || {
  log "curl not found — skipping audit"
  done0
}
command -v awk >/dev/null 2>&1 || {
  log "awk not found — skipping audit"
  done0
}

# Lift one JSON string value VERBATIM (still JSON-escaped, so it can be dropped
# straight back into our output JSON) without jq. Robust to embedded escaped
# quotes/backslashes and multi-line values. Input JSON via $JSON, key via $KEY;
# both passed through the environment (not -v) so backslashes are not mangled.
AWK_GET='BEGIN{
  s=ENVIRON["JSON"]; k="\"" ENVIRON["KEY"] "\":";
  p=index(s,k); if(p==0) exit 0;
  i=p+length(k); n=length(s);
  while(i<=n){ c=substr(s,i,1);
    if(c=="\"") { i++; break }
    if(c!=" " && c!="\t" && c!="\n" && c!="\r") exit 0;   # value is not a string
    i++ }
  out="";
  while(i<=n){ c=substr(s,i,1);
    if(c=="\\") { out=out c substr(s,i+1,1); i+=2; continue }
    if(c=="\"") break;
    out=out c; i++ }
  printf "%s", out
}'
json_get() { JSON=$1 KEY=$2 awk "$AWK_GET"; }

payload=$(cat)

prompt=$(json_get "$payload" prompt)
session_id=$(json_get "$payload" session_id)

# Nothing to audit (no prompt text) — exit quietly.
[ -n "$prompt" ] || done0

# Identity from the local Claude Code account (best-effort; blank if absent).
user_email=""
organization=""
if [ -f "$CLAUDE_CONFIG" ]; then
  claude=$(cat "$CLAUDE_CONFIG" 2>/dev/null || true)
  user_email=$(json_get "$claude" emailAddress)
  organization=$(json_get "$claude" organizationName)
fi

hostname=$(hostname 2>/dev/null || echo "${HOSTNAME:-unknown}")
ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# All values are already JSON-escaped (lifted verbatim) or simple scalars, so the
# document is assembled with printf alone — no jq needed to build it.
doc=$(printf '{"@timestamp":"%s","agent":"claude-code","user_email":"%s","organization":"%s","session_id":"%s","hostname":"%s","prompt":"%s"}' \
  "$ts" "$user_email" "$organization" "$session_id" "$hostname" "$prompt")

if curl -s -m 5 -o /dev/null -X POST "$ES_URL/$INDEX/_doc" \
  -H 'Content-Type: application/json' --data "$doc"; then
  log "audited prompt for session ${session_id:-?} -> $ES_URL/$INDEX"
else
  log "POST to $ES_URL/$INDEX failed (rc=$?) — prompt proceeds unaudited"
fi

done0
