#!/usr/bin/env bash
#
# capture-user-prompt.sh — Claude Code UserPromptSubmit audit hook (POSIX/bash).
#
# PURPOSE — deliver the canonical Agent Audit user-prompt document. Registered on
# Claude Code's `UserPromptSubmit` event (see ../scripts/render-hook.sh and the
# claude-code-elastic-audit stack setup), this fires once per submitted prompt,
# reshapes Claude's raw hook payload into the canonical `agent_audit.user_prompt`
# JSON document defined in SPEC/agent-audit.md, and POSTs it straight to the local
# Agent Audit data stream. Delivery is direct-to-Elasticsearch, independent of the
# OTLP/APM pipeline.
#
# ZERO EXTERNAL DEPENDENCIES — the hook ships to every employee workstation, so it
# uses only OS-base tools: `curl` (transport) and `awk` (lifts JSON string values
# without any external JSON CLI). There is NO external JSON CLI and NO TOML parser:
# the delivery config is the flat
# key=value `.claude/agent-audit.conf` (see ../agent-audit.template.conf and
# SPEC/agent-audit.md "Delivery and authorization"), read by a pure-shell cfg_get
# loop, and the canonical JSON document is assembled with printf from values lifted
# verbatim (already JSON-escaped) or escaped here.
#
# Delivery config (read at run time from agent-audit.conf, NOT hard-coded) — this
# hook reads only the `user_prompt` stream's keys:
#   capture.user_prompt.enabled   — false => skip this stream (fail-open, no delivery)
#   capture.user_prompt.content   — plaintext populates .text; redacted writes a
#                                    [REDACTED] marker (true .length kept); encrypted
#                                    leaves .text/.encrypted_text null (sealing not built)
#   elasticsearch.url / .api_key / .timeout_ms          — shared connection
#   elasticsearch.data_stream.user_prompt               — this stream's destination
# Config path is INJECTED, not discovered: the rendered hook command in
# settings.local.json passes `--config <abs path to agent-audit.conf>` (render-hook
# substitutes it). A shipped hook never infers its config from cwd / $HOME.
#
# Field mapping (Claude raw payload -> canonical document):
#   .session_id  -> agent_audit.conversation_id   (equals the OTLP session.id)
#   (no turn id)  -> agent_audit.turn_id = null    (Claude's payload carries none)
#   .prompt      -> agent_audit.user_prompt.text   (+ .length = its character count)
#   agent.provider/name are constants ("anthropic" / "claude-code").
#   user.* is the workstation login identity, best-effort: user.id is the
#   domain-qualified login from `whoami` (DOMAIN\user on Windows, the bare login on
#   POSIX) and user.name is the short login name (user.email is not used — not
#   consistently available cross-platform; access is restricted at the data stream
#   instead). agent_audit.agent.account.* (id/name/email) and the parallel
#   agent_audit.agent.organization.* (id/name) are the AI-agent PROVIDER account/org,
#   read locally (NO network) from ~/.claude.json's `oauthAccount` object — plain JSON,
#   no JWT to decode: account.id <- accountUuid, account.name <- displayName,
#   account.email <- emailAddress, organization.id <- organizationUuid,
#   organization.name <- organizationName. Any missing key/file leaves the field null
#   (API-key / unauthenticated sessions have no oauthAccount). host.name/host.hostname
#   are the runtime OS hostname (best-effort, both the same value). cwd /
#   transcript_path / permission_mode are intentionally dropped — not part of the
#   audit schema (and cwd is PII), and the mapping is strict, so stray fields must not
#   be emitted.
#
# CONTRACT — must never disturb the Claude session:
#   * Writes NOTHING to stdout. On UserPromptSubmit, stdout can be injected into
#     the model context or alter the prompt; ALL diagnostics go to stderr.
#   * ALWAYS exits 0 (best-effort, fail-open). A missing tool, missing config, an
#     unreachable Elasticsearch, or a parse miss must never block prompt
#     submission — a missing audit document is acceptable (SPEC/agent-audit.md
#     "Delivery and authorization"). The POST uses a very short timeout so an
#     unavailable destination does not noticeably delay agent usage.

set -u

log() { echo "[capture-user-prompt] $*" >&2; }
done0() { exit 0; } # every path is success — never block the prompt

STREAM=user_prompt
CLAUDE_CONFIG=${CLAUDE_CONFIG:-$HOME/.claude.json}

# Config path is INJECTED via --config (the rendered hook command supplies the
# absolute agent-audit.conf path). A shipped hook does NOT infer its config from
# cwd / $HOME — explicit injection only. A missing arg is a fail-open skip.
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

# Read a flat key=value from agent-audit.conf with a PURE-SHELL read loop — no
# subprocess parser. Splits on the FIRST `=` (so values may contain `=`); trims a
# trailing CR so a CRLF checkout does not corrupt values. First match wins.
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

# Lift one JSON string value VERBATIM (still JSON-escaped, so it drops straight back
# into our output JSON) without an external JSON CLI. Robust to embedded escaped quotes/backslashes.
# Input JSON via $JSON, key via $KEY (through the environment, not -v, so backslashes
# are not mangled). Empty when the key is absent or its value is not a string.
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

# Count the logical characters of an already-escaped JSON string body (\uXXXX and
# \X count as one), so .length is the decoded prompt's char count, not the escaped
# byte count. Input via $ESC.
AWK_STRLEN='BEGIN{
  s=ENVIRON["ESC"]; n=length(s); i=1; c=0;
  while(i<=n){ ch=substr(s,i,1);
    if(ch=="\\"){ nx=substr(s,i+1,1); if(nx=="u"){i+=6}else{i+=2} c++; continue }
    i++; c++ }
  printf "%d", c
}'
strlen_esc() { ESC=$1 awk "$AWK_STRLEN"; }

# Extract the raw JSON value of a key (any type) — used to pull the oauthAccount
# object out of ~/.claude.json so its keys are lifted from that object only, not from
# a stray same-named key elsewhere in the file. Balanced over strings/objects/arrays.
# Input via $JSON / $KEY. Empty when the key is absent.
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

prompt_esc=$(json_get "$payload" prompt)
[ -n "$prompt_esc" ] || {
  log "no prompt in payload — nothing to capture"
  done0
}
session_esc=$(json_get "$payload" session_id)
plen=$(strlen_esc "$prompt_esc")

ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# Best-effort runtime identity (Claude's payload has none).
user_name=${USER:-${USERNAME:-$(id -un 2>/dev/null || echo "")}}
# user.id is the domain-qualified workstation login (whoami: DOMAIN\user on
# Windows, the bare login on POSIX where no domain source exists). Empty -> null.
user_id=$(whoami 2>/dev/null || echo "")

# Best-effort runtime host (ECS host.hostname/host.name). Claude's payload has none;
# use the OS hostname. host.name and host.hostname are the same value here.
host_hostname=${HOSTNAME:-}
[ -n "$host_hostname" ] || host_hostname=$(hostname 2>/dev/null || echo "")
[ -n "$host_hostname" ] || host_hostname=${COMPUTERNAME:-}
host_name=$host_hostname

# Best-effort AI-agent PROVIDER identity, read LOCALLY (no network) from
# ~/.claude.json's `oauthAccount` object (plain JSON — no JWT to decode). The
# oauthAccount object is isolated first so its keys are not confused with same-named
# keys elsewhere in the (large) config. Any missing file/key leaves the field empty
# -> null; API-key / unauthenticated sessions have no oauthAccount.
acct_id="" acct_email="" acct_name="" org_id="" org_name=""
if [ -f "$CLAUDE_CONFIG" ]; then
  claude=$(cat "$CLAUDE_CONFIG" 2>/dev/null || echo "")
  oauth=$(json_get_raw "$claude" oauthAccount)
  if [ -n "$oauth" ]; then
    acct_id=$(json_get "$oauth" accountUuid)
    acct_name=$(json_get "$oauth" displayName)
    acct_email=$(json_get "$oauth" emailAddress)
    org_id=$(json_get "$oauth" organizationUuid)
    org_name=$(json_get "$oauth" organizationName)
  fi
fi

# Body form by capture.user_prompt.content: plaintext stores the real prompt; redacted
# stores a fixed [REDACTED] marker (verifies the delivery path — identity, routing,
# strict mapping, landing — without exposing the prompt); encrypted (or anything else)
# leaves .text null — sealing into encrypted_text is a later increment. .length is the
# true char count regardless, so the audit trail still records a prompt of that size.
case "$content" in
plaintext) text_field=$(jv_esc "$prompt_esc") ;;
redacted) text_field='"[REDACTED]"' ;;
*) text_field=null ;;
esac

# Assemble the canonical agent_audit.user_prompt document with printf (no JSON CLI). Lifted
# values (prompt/session, provider claims) are already JSON-escaped; the shell-derived
# identity (user/host) is escaped by jv_raw. turn_id is null — Claude's payload has no
# turn id (conversation_id still links to the OTLP session).
record=$(printf '{"@timestamp":"%s","event":{"action":"user-prompt","created":"%s","dataset":"agent_audit.user_prompt","kind":"event"},"user":{"id":%s,"name":%s},"host":{"name":%s,"hostname":%s},"agent_audit":{"agent":{"provider":"anthropic","name":"claude-code","account":{"id":%s,"name":%s,"email":%s},"organization":{"id":%s,"name":%s}},"conversation_id":%s,"turn_id":null,"user_prompt":{"text":%s,"encrypted_text":null,"length":%s}}}' \
  "$ts" "$ts" \
  "$(jv_raw "$user_id")" "$(jv_raw "$user_name")" \
  "$(jv_raw "$host_name")" "$(jv_raw "$host_hostname")" \
  "$(jv_esc "$acct_id")" "$(jv_esc "$acct_name")" "$(jv_esc "$acct_email")" \
  "$(jv_esc "$org_id")" "$(jv_esc "$org_name")" \
  "$(jv_esc "$session_esc")" \
  "$text_field" "$plen")

# POST to the data stream's _doc endpoint (auto op_type=create for data streams).
es_target="${es_url%/}/${data_stream}/_doc"
curl_args=(-s -o /dev/null -w '%{http_code}' --max-time "$max_time"
  -X POST "$es_target" -H 'Content-Type: application/json')
[ -n "$api_key" ] && curl_args+=(-H "Authorization: ApiKey $api_key")
curl_args+=(--data-binary @-)

http_code=$(printf '%s' "$record" | curl "${curl_args[@]}" 2>/dev/null) ||
  {
    log "POST to $es_target failed (curl error) — prompt proceeds uncaptured"
    done0
  }

case "$http_code" in
2*) log "indexed 1 audit document -> $es_target (HTTP $http_code)" ;;
*) log "index returned HTTP $http_code (audit doc not stored) — prompt unaffected" ;;
esac
done0
