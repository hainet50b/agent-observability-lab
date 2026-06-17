#!/usr/bin/env bash
#
# capture-tool-call.sh — Codex CLI PostToolUse audit hook (POSIX/bash).
#
# PURPOSE — deliver the canonical Agent Audit tool-call document. Registered on
# Codex's `PostToolUse` event (see ../scripts/render-hooks.sh and the stack
# setup.sh/.ps1), this fires once per completed tool call (the event carries both
# the tool input and its result), reshapes Codex's raw hook payload into the
# canonical `agent_audit.tool_call` JSON document defined in SPEC/agent-audit.md,
# and POSTs it straight to the local Agent Audit tool-call data stream. Delivery is
# direct-to-Elasticsearch, independent of the OTLP/APM pipeline.
# (Sibling of capture-user-prompt.{sh,ps1}, the UserPromptSubmit audit hook.)
#
# ZERO EXTERNAL DEPENDENCIES — the hook ships to every employee workstation, so it
# uses only OS-base tools: `curl` (transport), `awk` (extracts JSON values without
# jq), `base64` (decodes the auth.json JWT segment). There is NO `jq` and NO TOML
# parser: the delivery config is the flat key=value `.codex/agent-audit.conf` (see
# ../agent-audit.template.conf and SPEC/agent-audit.md "Delivery and authorization"),
# read by a pure-shell cfg_get loop, and the canonical JSON document is assembled
# with printf. If `base64` is absent only the provider identity degrades to null.
#
# Delivery config (read at run time from agent-audit.conf, NOT hard-coded) — this
# hook reads only the `tool_call` stream's keys:
#   capture.tool_call.enabled   — false => skip this stream (fail-open, no delivery)
#   capture.tool_call.content   — plaintext populates .text; encrypted leaves
#                                 .text/.encrypted_text null (sealing not built yet)
#   elasticsearch.url / .api_key / .timeout_ms        — shared connection
#   elasticsearch.data_stream.tool_call               — this stream's destination
# Config path is INJECTED, not discovered: the rendered hook command in config.toml
# passes `--config <abs path to agent-audit.conf>` (render-hooks substitutes it). A
# shipped hook never infers its config from cwd / CODEX_HOME / $HOME. (CODEX_HOME is
# still used below for auth.json — the agent's own credential store, not our config.)
# from the same environment that launched Codex, beside config.toml.
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
#                    tools), so its raw JSON value text is taken verbatim — one scalar,
#                    so the strict mapping never sees arbitrary nested keys.
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

STREAM=tool_call

# Config path is INJECTED via --config (the rendered hook command in config.toml
# supplies the absolute agent-audit.conf path). A shipped hook does NOT infer its
# config from cwd / CODEX_HOME / $HOME — explicit injection only. A missing arg is
# a fail-open skip (never block the tool call).
config_file=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --config ] && [ "$#" -ge 2 ]; then
    config_file=$2
    shift 2
  else
    shift
  fi
done
[ -n "$config_file" ] || {
  log "no --config <path> provided — skipping (the rendered hook command injects it)"
  done0
}

# Read a flat key=value from agent-audit.conf, with a PURE-SHELL read loop — no jq,
# no subprocess parser (the .conf is dotted-key key=value; comment lines start with
# `#`). Splits on the FIRST `=` (so values may contain `=`); trims a trailing CR so
# a CRLF checkout does not corrupt values. First match wins.
cfg_get() {
  _key=$1
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    case $_k in
    '#'*) continue ;;
    esac
    if [ "$_k" = "$_key" ]; then
      printf '%s' "${_v%$'\r'}"
      return 0
    fi
  done <"$config_file"
  return 0
}

# Lift one JSON string value VERBATIM (still JSON-escaped). Input via $JSON / $KEY.
# Empty when the key is absent or its value is not a string.
AWK_GET='BEGIN{
  s=ENVIRON["JSON"]; k="\"" ENVIRON["KEY"] "\":";
  p=index(s,k); if(p==0) exit 0;
  i=p+length(k); n=length(s);
  while(i<=n){ c=substr(s,i,1); if(c==" "||c=="\t"||c=="\n"||c=="\r"){i++} else break }
  if(i>n || substr(s,i,1)!="\"") exit 0;
  i++; start=i;
  while(i<=n){ ch=substr(s,i,1);
    if(ch=="\\"){ i+=2; continue }
    if(ch=="\""){ break }
    i++ }
  printf "%s", substr(s,start,i-start)
}'
json_get() { JSON=$1 KEY=$2 awk "$AWK_GET"; }

# Extract the raw JSON value of a key (any type) verbatim — used to serialize the
# heterogeneous tool_input / tool_response and to pull the organizations array from
# the auth.json claims. Balanced over strings/objects/arrays. Input via $JSON / $KEY.
AWK_GET_RAW='BEGIN{
  s=ENVIRON["JSON"]; k="\"" ENVIRON["KEY"] "\":";
  p=index(s,k); if(p==0) exit 0;
  i=p+length(k); n=length(s);
  while(i<=n){ c=substr(s,i,1); if(c==" "||c=="\t"||c=="\n"||c=="\r"){i++} else break }
  if(i>n) exit 0; start=i; c=substr(s,i,1);
  if(c=="\""){ i++;
    while(i<=n){ ch=substr(s,i,1);
      if(ch=="\\"){i+=2; continue}
      if(ch=="\""){i++; break}
      i++ }
    printf "%s", substr(s,start,i-start); exit 0 }
  if(c=="{"||c=="["){ depth=0; instr=0;
    while(i<=n){ ch=substr(s,i,1);
      if(instr){ if(ch=="\\"){i+=2; continue} if(ch=="\""){instr=0} i++; continue }
      if(ch=="\""){instr=1; i++; continue}
      if(ch=="{"||ch=="["){depth++; i++; continue}
      if(ch=="}"||ch=="]"){depth--; i++; if(depth==0) break; continue}
      i++ }
    printf "%s", substr(s,start,i-start); exit 0 }
  while(i<=n){ ch=substr(s,i,1);
    if(ch==","||ch=="}"||ch=="]"||ch==" "||ch=="\t"||ch=="\n"||ch=="\r") break; i++ }
  printf "%s", substr(s,start,i-start)
}'
json_get_raw() { JSON=$1 KEY=$2 awk "$AWK_GET_RAW"; }

# From an organizations array (raw JSON), pick the is_default entry (fallback: the
# first) and print its "id" then "title" (escaped) on two lines. Input via $ORGS.
AWK_ORG='function liftstr(str,key,   kk,p,ii,nn,c,out){
    kk="\"" key "\":\""; p=index(str,kk); if(p==0) return "";
    ii=p+length(kk); nn=length(str); out="";
    while(ii<=nn){ c=substr(str,ii,1);
      if(c=="\\"){ out=out c substr(str,ii+1,1); ii+=2; continue }
      if(c=="\"") break;
      out=out c; ii++ }
    return out }
  BEGIN{
    s=ENVIRON["ORGS"]; n=length(s);
    depth=0; instr=0; start=0; chosen=""; first="";
    for(i=1;i<=n;i++){ ch=substr(s,i,1);
      if(instr){ if(ch=="\\"){i++; continue} if(ch=="\""){instr=0} continue }
      if(ch=="\""){instr=1; continue}
      if(ch=="{"){ if(depth==0) start=i; depth++; continue }
      if(ch=="}"){ depth--; if(depth==0){ obj=substr(s,start,i-start+1);
          if(first=="") first=obj;
          if(chosen=="" && index(obj,"\"is_default\":true")>0) chosen=obj } continue } }
    obj=(chosen!="")?chosen:first;
    print liftstr(obj,"id");
    print liftstr(obj,"title") }'

# Escape a raw (unescaped) shell string into a JSON string body.
AWK_ESC='BEGIN{ s=ENVIRON["RAW"];
  gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s);
  gsub(/\n/,"\\n",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s);
  printf "%s", s }'
jesc() { RAW=$1 awk "$AWK_ESC"; }

# Emit a JSON value: a quoted string for an already-escaped value, else null.
jv_esc() { if [ -n "$1" ]; then printf '"%s"' "$1"; else printf 'null'; fi; }
# Emit a JSON value: a quoted, freshly-escaped string for a raw value, else null.
jv_raw() { if [ -n "$1" ]; then printf '"%s"' "$(jesc "$1")"; else printf 'null'; fi; }

command -v curl >/dev/null 2>&1 || {
  log "curl unavailable — cannot deliver audit document; skipping"
  done0
}
command -v awk >/dev/null 2>&1 || {
  log "awk unavailable — cannot shape audit document; skipping"
  done0
}

[ -f "$config_file" ] || {
  log "no delivery config at $config_file — skipping (run setup.sh)"
  done0
}

enabled=$(cfg_get "capture.$STREAM.enabled")
[ "$enabled" = false ] && {
  log "capture.$STREAM.enabled=false — skipping (stream disabled)"
  done0
}
content=$(cfg_get "capture.$STREAM.content")
es_url=$(cfg_get elasticsearch.url)
api_key=$(cfg_get elasticsearch.api_key)
timeout_ms=$(cfg_get elasticsearch.timeout_ms)
data_stream=$(cfg_get "elasticsearch.data_stream.$STREAM")

if [ -z "$es_url" ] || [ -z "$data_stream" ]; then
  log "config missing elasticsearch.url / data_stream.$STREAM — skipping"
  done0
fi

# timeout_ms (default 300) -> curl --max-time seconds, pure-shell (no awk/bc).
case "$timeout_ms" in '' | *[!0-9]*) timeout_ms=300 ;; esac
max_time=$(printf '%d.%03d' "$((timeout_ms / 1000))" "$((timeout_ms % 1000))")

payload=$(cat)
[ -n "$payload" ] || {
  log "empty stdin — nothing to capture"
  done0
}

tool_name_esc=$(json_get "$payload" tool_name)
call_id_esc=$(json_get "$payload" tool_use_id)
session_esc=$(json_get "$payload" session_id)
turn_esc=$(json_get "$payload" turn_id)
model_esc=$(json_get "$payload" model)

# tool_input / tool_response are heterogeneous JSON — take each value's raw JSON text
# verbatim as the serialized form (one scalar for the strict mapping). .length is the
# char count of that serialized text.
in_raw=$(json_get_raw "$payload" tool_input)
out_raw=$(json_get_raw "$payload" tool_response)
in_len=${#in_raw}
out_len=${#out_raw}

ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# Best-effort runtime identity (Codex's payload has none).
user_name=${USER:-${USERNAME:-$(id -un 2>/dev/null || echo "")}}
# user.id is the domain-qualified workstation login (whoami: DOMAIN\user on
# Windows, the bare login on POSIX where no domain source exists). Empty -> null.
user_id=$(whoami 2>/dev/null || echo "")

# Best-effort runtime host (ECS host.hostname/host.name). Codex's payload has none;
# use the OS hostname. host.name and host.hostname are the same value here.
host_hostname=${HOSTNAME:-}
[ -n "$host_hostname" ] || host_hostname=$(hostname 2>/dev/null || echo "")
[ -n "$host_hostname" ] || host_hostname=${COMPUTERNAME:-}
host_name=$host_hostname

# Best-effort AI-agent PROVIDER identity, read LOCALLY (no network) from
# $CODEX_HOME/auth.json (same derivation as capture-user-prompt.sh). Any missing
# file/claim/tool leaves that field empty -> null; API-key auth has no id_token.
codex_home=${CODEX_HOME:-$HOME/.codex}
auth_file="$codex_home/auth.json"
acct_id="" acct_email="" acct_name="" org_id="" org_name=""
if [ -f "$auth_file" ]; then
  auth=$(cat "$auth_file" 2>/dev/null || echo "")
  acct_id=$(json_get "$auth" account_id)
  id_token=$(json_get "$auth" id_token)
  if [ -n "$id_token" ] && command -v base64 >/dev/null 2>&1; then
    seg=$(printf '%s' "$id_token" | cut -d. -f2)
    b64=$(printf '%s' "$seg" | tr '_-' '/+')
    case $((${#b64} % 4)) in
    2) b64="${b64}==" ;;
    3) b64="${b64}=" ;;
    esac
    claims=$(printf '%s' "$b64" | base64 -d 2>/dev/null || echo "")
    if [ -n "$claims" ]; then
      acct_email=$(json_get "$claims" email)
      acct_name=$(json_get "$claims" name)
      orgs=$(json_get_raw "$claims" organizations)
      if [ -n "$orgs" ]; then
        {
          IFS= read -r org_id
          IFS= read -r org_name
        } <<EOF
$(ORGS="$orgs" awk "$AWK_ORG")
EOF
      fi
    fi
  fi
fi

# plaintext mode populates input/output .text; any other content (encrypted) leaves
# them null — sealing into encrypted_text is a later increment. .length is the true
# char count regardless, so the audit trail records that a tool call of that size occurred.
in_text=null
out_text=null
if [ "$content" = plaintext ]; then
  [ -n "$in_raw" ] && in_text=$(printf '"%s"' "$(jesc "$in_raw")")
  [ -n "$out_raw" ] && out_text=$(printf '"%s"' "$(jesc "$out_raw")")
fi

# Assemble the canonical agent_audit.tool_call document with printf (no jq). Lifted
# values are already JSON-escaped; shell-derived identity is escaped by jv_raw.
record=$(printf '{"@timestamp":"%s","event":{"action":"tool-call","created":"%s","dataset":"agent_audit.tool_call","kind":"event"},"user":{"id":%s,"name":%s},"host":{"name":%s,"hostname":%s},"agent_audit":{"agent":{"provider":"openai","name":"codex-cli","model":%s,"account":{"id":%s,"name":%s,"email":%s},"organization":{"id":%s,"name":%s}},"conversation_id":%s,"turn_id":%s,"tool_call":{"tool":{"name":%s,"call_id":%s},"input":{"text":%s,"encrypted_text":null,"length":%s},"output":{"text":%s,"encrypted_text":null,"length":%s}}}}' \
  "$ts" "$ts" \
  "$(jv_raw "$user_id")" "$(jv_raw "$user_name")" \
  "$(jv_raw "$host_name")" "$(jv_raw "$host_hostname")" \
  "$(jv_esc "$model_esc")" \
  "$(jv_esc "$acct_id")" "$(jv_esc "$acct_name")" "$(jv_esc "$acct_email")" \
  "$(jv_esc "$org_id")" "$(jv_esc "$org_name")" \
  "$(jv_esc "$session_esc")" "$(jv_esc "$turn_esc")" \
  "$(jv_esc "$tool_name_esc")" "$(jv_esc "$call_id_esc")" \
  "$in_text" "$in_len" \
  "$out_text" "$out_len")

# POST to the data stream's _doc endpoint (auto op_type=create for data streams).
es_target="${es_url%/}/${data_stream}/_doc"
curl_args=(-s -o /dev/null -w '%{http_code}' --max-time "$max_time"
  -X POST "$es_target" -H 'Content-Type: application/json')
[ -n "$api_key" ] && curl_args+=(-H "Authorization: ApiKey $api_key")
curl_args+=(--data-binary @-)

http_code=$(printf '%s' "$record" | curl "${curl_args[@]}" 2>/dev/null) ||
  {
    log "POST to $es_target failed (curl error) — tool call proceeds uncaptured"
    done0
  }

case "$http_code" in
2*) log "indexed 1 audit document -> $es_target (HTTP $http_code)" ;;
*) log "index returned HTTP $http_code (audit doc not stored) — tool call unaffected" ;;
esac
done0
