#!/usr/bin/env bash
#
# capture-tool-call.sh — Codex CLI PostToolUse audit hook (POSIX/bash).
#
# PURPOSE — deliver the canonical Agent Audit tool-call document. Registered on
# Codex's `PostToolUse` event (see ../scripts/render-hooks.sh and the stack
# setup.sh/.ps1), this fires once per completed tool call (the event carries both
# the tool input and its result), reshapes Codex's raw hook payload into the
# canonical `agent_audit.tool_call` JSON document defined in SPEC/agent-audit.md,
# and POSTs it straight to the local Agent Audit data stream
# `logs-agent_audit.tool_call-default`. Delivery is direct-to-Elasticsearch,
# independent of the OTLP/APM pipeline. It does NOT seal/encrypt: in the lab's
# `mode = "plaintext"` the tool input/output are captured in plaintext (a future
# encrypted mode nulls .text and populates .encrypted_text — reserved field).
# (Sibling of capture-user-prompt.{sh,ps1}, the UserPromptSubmit audit hook.)
#
# Delivery config (read at run time, NOT hard-coded): the [elasticsearch] / [audit]
# blocks of agent-audit.toml — `url`, `api_key`, `timeout_ms`, and `audit.mode`
# (see ../agent-audit.template.toml and SPEC/agent-audit.md). The data stream is
# NOT read from config: that key (`data_stream`) names the user_prompt stream, so
# the tool-call stream name is fixed in this script (DATA_STREAM below). Config path:
#   $CODEX_AGENT_AUDIT_CONFIG, else ${CODEX_HOME:-$HOME/.codex}/agent-audit.toml
# Launching Codex as `CODEX_HOME=<stack>/.codex codex` (this stack's mechanism)
# makes that <stack>/.codex/agent-audit.toml — the hook process inherits CODEX_HOME
# from the same environment that launched Codex, beside config.toml / hooks.json.
#
# Field mapping (Codex raw payload -> canonical document):
#   .session_id   -> agent_audit.conversation_id   (Codex's session is the convo)
#   .turn_id      -> agent_audit.turn_id
#   .model        -> agent_audit.agent.model
#   .tool_name    -> agent_audit.tool_call.tool.name
#   .tool_use_id  -> agent_audit.tool_call.tool.call_id  (per-call id; also the join
#                    key to the OTLP trace_safe codex.tool_result `call_id`)
#   .tool_input   -> agent_audit.tool_call.input  (serialized to a JSON STRING into
#                    .text, .length = its char count). Codex's tool_input is
#                    heterogeneous (object for MCP tools; string-or-object for shell
#                    tools), so it is serialized to one scalar — the strict mapping
#                    must not see arbitrary nested keys.
#   .tool_response-> agent_audit.tool_call.output (same serialize-to-.text treatment).
#   agent.provider/name are constants ("openai" / "codex-cli").
#   user.* / host.* / agent_audit.agent.account.* / organization.* are derived
#   exactly as capture-user-prompt.sh does (workstation login via whoami; provider
#   identity read LOCALLY, no network, from $CODEX_HOME/auth.json's id_token claims).
#   cwd / transcript_path / permission_mode are intentionally dropped — not part of
#   the audit schema (and cwd is PII), and the mapping is strict, so stray fields
#   must not be emitted. There is no success/exit field: Codex's tool_response is
#   opaque and not reliably parseable across tools.
#
# CONTRACT — must never disturb the Codex session:
#   * Writes NOTHING to stdout. On a hook event, stdout can be injected into the
#     model context or alter behaviour; ALL diagnostics go to stderr.
#   * ALWAYS exits 0 (best-effort, fail-open). A missing tool, missing config, an
#     unreachable Elasticsearch, or a parse miss must never block the tool call —
#     a missing audit document is acceptable (SPEC/agent-audit.md "Delivery and
#     authorization"). The POST uses a very short timeout so an unavailable
#     destination does not noticeably delay agent usage.

set -u

log() { echo "[capture-tool-call] $*" >&2; }
done0() { exit 0; } # every path is success — never block the tool call

# The tool-call audit stream is fixed here (the config's data_stream names the
# user_prompt stream — see header).
DATA_STREAM=logs-agent_audit.tool_call-default

config_file=${CODEX_AGENT_AUDIT_CONFIG:-${CODEX_HOME:-$HOME/.codex}/agent-audit.toml}

# Read a flat (non-array, non-inline-table) TOML scalar by key, unquoted. Keys in
# agent-audit.toml are unique across the [elasticsearch] / [audit] sections, so a
# section-agnostic lookup is unambiguous. Comments live on their own lines.
toml_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$config_file" 2> /dev/null \
    | head -n1 \
    | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# The canonical document is JSON; shaping arbitrary tool I/O safely needs jq.
command -v jq > /dev/null 2>&1 || {
  log "jq unavailable — cannot shape audit document; skipping"
  done0
}
command -v curl > /dev/null 2>&1 || {
  log "curl unavailable — cannot deliver audit document; skipping"
  done0
}

[ -f "$config_file" ] || {
  log "no delivery config at $config_file — skipping (run setup.sh)"
  done0
}

es_url=$(toml_get url)
api_key=$(toml_get api_key)
timeout_ms=$(toml_get timeout_ms)
mode=$(toml_get mode)

[ -n "$es_url" ] || {
  log "config missing url — skipping"
  done0
}

# timeout_ms (default 300) -> curl --max-time seconds, pure-shell (no awk/bc).
case "$timeout_ms" in '' | *[!0-9]*) timeout_ms=300 ;; esac
max_time=$(printf '%d.%03d' "$((timeout_ms / 1000))" "$((timeout_ms % 1000))")

payload=$(cat)
[ -n "$payload" ] || {
  log "empty stdin — nothing to capture"
  done0
}

ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2> /dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# Best-effort runtime identity (Codex's payload has none).
user_name=${USER:-${USERNAME:-$(id -un 2> /dev/null || echo "")}}
# user.id is the domain-qualified workstation login (whoami: DOMAIN\user on
# Windows, the bare login on POSIX where no domain source exists). Empty -> null.
user_id=$(whoami 2> /dev/null || echo "")

# Best-effort runtime host (ECS host.hostname/host.name). Codex's payload has
# none; use the OS hostname. host.name and host.hostname are the same value here
# (best-effort — ECS permits it); a richer source could split FQDN vs short name.
host_hostname=${HOSTNAME:-}
[ -n "$host_hostname" ] || host_hostname=$(hostname 2> /dev/null || echo "")
[ -n "$host_hostname" ] || host_hostname=${COMPUTERNAME:-}
host_name=$host_hostname

# Best-effort AI-agent PROVIDER identity, read LOCALLY (no network) from
# $CODEX_HOME/auth.json (Codex's ChatGPT-auth credential store). account.id is
# .tokens.account_id; account.email/name and the organization come from the
# id_token JWT's claims (payload = 2nd dot-segment, base64url-decoded via jq's
# @base64d — NOT signature-verified, it is a local trusted file). Any missing
# file/claim leaves that field null; API-key auth has no id_token, so all null.
codex_home=${CODEX_HOME:-$HOME/.codex}
auth_file="$codex_home/auth.json"
identity='{"account_id":null,"account_email":null,"account_name":null,"org_id":null,"org_name":null}'
if [ -f "$auth_file" ]; then
  if parsed=$(jq -c '
      def b64urldec:
        (gsub("-";"+") | gsub("_";"/"))
        | (length % 4) as $m
        | (if $m > 0 then . + ("=" * (4 - $m)) else . end)
        | @base64d;
      (.tokens.account_id // null) as $acct
      | (.tokens.id_token // "") as $idt
      | ($idt | split(".")) as $parts
      | (if ($parts | length) >= 2 then (try ($parts[1] | b64urldec | fromjson) catch {}) else {} end) as $claims
      | (($claims["https://api.openai.com/auth"].organizations) // []) as $orgs
      | (([$orgs[] | select(.is_default == true)][0]) // $orgs[0] // {}) as $org
      | {
          account_id: $acct,
          account_email: ($claims.email // null),
          account_name: ($claims.name // null),
          org_id: ($org.id // null),
          org_name: ($org.title // null)
        }' "$auth_file" 2> /dev/null) && [ -n "$parsed" ]; then
    identity=$parsed
  else
    log "could not parse provider identity from $auth_file — account/organization stay null"
  fi
fi

# Reshape raw Codex payload -> canonical agent_audit.tool_call document. tool_input
# and tool_response are heterogeneous JSON, so each is serialized to a JSON STRING
# (jq `tojson`) into .text with .length its char count — one scalar per side, so the
# strict mapping never sees the tool's arbitrary nested keys. In plaintext mode .text
# carries the serialized content; any other mode nulls it (sealing into encrypted_text
# is a later increment) — .length is the true char count regardless, so the audit
# trail still records that a tool call of that size occurred.
record=$(printf '%s' "$payload" \
  | jq -c --arg ts "$ts" --arg uname "$user_name" --arg uid "$user_id" --arg mode "$mode" \
    --arg hname "$host_name" --arg hhost "$host_hostname" --argjson id "$identity" \
    '($mode == "plaintext") as $plain
       | (if (.tool_input // null)   == null then null else (.tool_input   | tojson) end) as $in
       | (if (.tool_response // null) == null then null else (.tool_response | tojson) end) as $out
       | {
        "@timestamp": $ts,
        event: { action: "tool-call", created: $ts, dataset: "agent_audit.tool_call", kind: "event" },
        user: { id: (if ($uid | length) > 0 then $uid else null end), name: (if ($uname | length) > 0 then $uname else null end) },
        host: { name: (if ($hname | length) > 0 then $hname else null end), hostname: (if ($hhost | length) > 0 then $hhost else null end) },
        agent_audit: {
          agent: { provider: "openai", name: "codex-cli", model: (.model // null), account: { id: $id.account_id, name: $id.account_name, email: $id.account_email }, organization: { id: $id.org_id, name: $id.org_name } },
          conversation_id: (.session_id // null),
          turn_id: (.turn_id // null),
          tool_call: {
            tool: { name: (.tool_name // null), call_id: (.tool_use_id // null) },
            input:  { text: (if $plain then $in  else null end), encrypted_text: null, length: (($in  // "") | length) },
            output: { text: (if $plain then $out else null end), encrypted_text: null, length: (($out // "") | length) }
          }
        }
      }' 2> /dev/null) \
  || {
    log "payload not valid JSON — cannot shape audit document; skipping"
    done0
  }

# POST to the data stream's _doc endpoint (auto op_type=create for data streams).
es_target="${es_url%/}/${DATA_STREAM}/_doc"
curl_args=(-s -o /dev/null -w '%{http_code}' --max-time "$max_time"
  -X POST "$es_target" -H 'Content-Type: application/json')
[ -n "$api_key" ] && curl_args+=(-H "Authorization: ApiKey $api_key")
curl_args+=(--data-binary @-)

http_code=$(printf '%s' "$record" | curl "${curl_args[@]}" 2> /dev/null) \
  || {
    log "POST to $es_target failed (curl error) — tool call proceeds uncaptured"
    done0
  }

case "$http_code" in
  2*) log "indexed 1 audit document -> $es_target (HTTP $http_code)" ;;
  *) log "index returned HTTP $http_code (audit doc not stored) — tool call unaffected" ;;
esac
done0
