#!/usr/bin/env bash
# shellcheck disable=SC2154

set -u

LOG_TAG=$(basename -- "$0" .sh)
CLAUDE_CONFIG=${CLAUDE_CONFIG:-$HOME/.claude.json}

log() { echo "[$LOG_TAG] $*" >&2; }
done0() { exit 0; }

require_config_arg() {
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
}

require_tools() {
  command -v curl >/dev/null 2>&1 || {
    log "curl unavailable — cannot deliver audit document; skipping"
    done0
  }
  command -v awk >/dev/null 2>&1 || {
    log "awk unavailable — cannot shape audit document; skipping"
    done0
  }
}

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
json::string_field() { JSON=$1 KEY=$2 awk "$AWK_GET"; }

AWK_STRLEN='BEGIN{
  s=ENVIRON["ESC"]; n=length(s); i=1; c=0;
  while(i<=n){ ch=substr(s,i,1);
    if(ch=="\\"){ nx=substr(s,i+1,1); if(nx=="u"){i+=6}else{i+=2} c++; continue }
    i++; c++ }
  printf "%d", c
}'
json::char_count() { ESC=$1 awk "$AWK_STRLEN"; }

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
json::raw_value() { JSON=$1 KEY=$2 awk "$AWK_GET_RAW"; }

AWK_ESC='BEGIN{ s=ENVIRON["RAW"];
  gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s);
  gsub(/\n/,"\\n",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s);
  printf "%s", s }'
json::escape() { RAW=$1 awk "$AWK_ESC"; }

jv_esc() { if [ -n "$1" ]; then printf '"%s"' "$1"; else printf 'null'; fi; }
jv_raw() { if [ -n "$1" ]; then printf '"%s"' "$(json::escape "$1")"; else printf 'null'; fi; }

load_delivery_config() {
  [ -f "$config_file" ] || {
    log "no delivery config at $config_file — skipping (run setup.sh)"
    done0
  }
  enabled=$(cfg_get "capture.$stream.enabled")
  content=$(cfg_get "capture.$stream.content")
  es_url=$(cfg_get elasticsearch.url)
  api_key=$(cfg_get elasticsearch.api_key)
  timeout_ms=$(cfg_get elasticsearch.timeout_ms)
  data_stream=$(cfg_get "elasticsearch.data_stream.$stream")
  if [ -z "$es_url" ] || [ -z "$data_stream" ]; then
    log "config missing elasticsearch.url / data_stream.$stream — skipping"
    done0
  fi
  case "$timeout_ms" in '' | *[!0-9]*) timeout_ms=300 ;; esac
  max_time=$(printf '%d.%03d' "$((timeout_ms / 1000))" "$((timeout_ms % 1000))")
}

require_stream_enabled() {
  [ "$enabled" = false ] && {
    log "capture.$stream.enabled=false — skipping (stream disabled)"
    done0
  }
  return 0
}

read_hook_payload() {
  payload=$(cat)
  [ -n "$payload" ] || {
    log "empty stdin — nothing to capture"
    done0
  }
  if [ "$stream" = user_prompt ]; then
    prompt_esc=$(json::string_field "$payload" prompt)
    [ -n "$prompt_esc" ] || {
      log "no prompt in payload — nothing to capture"
      done0
    }
    session_esc=$(json::string_field "$payload" session_id)
    plen=$(json::char_count "$prompt_esc")
  else
    tool_name_esc=$(json::string_field "$payload" tool_name)
    call_id_esc=$(json::string_field "$payload" tool_use_id)
    session_esc=$(json::string_field "$payload" session_id)
    turn_esc=$(json::string_field "$payload" turn_id)
    in_raw=$(json::raw_value "$payload" tool_input)
    out_raw=$(json::raw_value "$payload" tool_response)
    in_len=${#in_raw}
    out_len=${#out_raw}
  fi
}

derive_runtime_identity() {
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

  user_name=${USER:-${USERNAME:-$(id -un 2>/dev/null || echo "")}}
  user_id=$(whoami 2>/dev/null || echo "")

  host_hostname=${HOSTNAME:-}
  [ -n "$host_hostname" ] || host_hostname=$(hostname 2>/dev/null || echo "")
  [ -n "$host_hostname" ] || host_hostname=${COMPUTERNAME:-}
  host_name=$host_hostname

  acct_id="" acct_email="" acct_name="" org_id="" org_name=""
  if [ -f "$CLAUDE_CONFIG" ]; then
    claude=$(cat "$CLAUDE_CONFIG" 2>/dev/null || echo "")
    oauth=$(json::raw_value "$claude" oauthAccount)
    if [ -n "$oauth" ]; then
      acct_id=$(json::string_field "$oauth" accountUuid)
      acct_name=$(json::string_field "$oauth" displayName)
      acct_email=$(json::string_field "$oauth" emailAddress)
      org_id=$(json::string_field "$oauth" organizationUuid)
      org_name=$(json::string_field "$oauth" organizationName)
    fi
  fi
}

build_user_prompt_record() {
  case "$content" in
  plaintext) text_field=$(jv_esc "$prompt_esc") ;;
  redacted) text_field='"[REDACTED]"' ;;
  *) text_field=null ;;
  esac

  record=$(printf '{"@timestamp":"%s","event":{"action":"user-prompt","created":"%s","dataset":"agent_audit.user_prompt","kind":"event"},"user":{"id":%s,"name":%s},"host":{"name":%s,"hostname":%s},"agent_audit":{"agent":{"provider":"anthropic","name":"claude-code","account":{"id":%s,"name":%s,"email":%s},"organization":{"id":%s,"name":%s}},"conversation_id":%s,"turn_id":null,"user_prompt":{"text":%s,"encrypted_text":null,"length":%s}}}' \
    "$ts" "$ts" \
    "$(jv_raw "$user_id")" "$(jv_raw "$user_name")" \
    "$(jv_raw "$host_name")" "$(jv_raw "$host_hostname")" \
    "$(jv_esc "$acct_id")" "$(jv_esc "$acct_name")" "$(jv_esc "$acct_email")" \
    "$(jv_esc "$org_id")" "$(jv_esc "$org_name")" \
    "$(jv_esc "$session_esc")" \
    "$text_field" "$plen")
}

build_tool_call_record() {
  in_text=null
  out_text=null
  case "$content" in
  plaintext)
    [ -n "$in_raw" ] && in_text=$(printf '"%s"' "$(json::escape "$in_raw")")
    [ -n "$out_raw" ] && out_text=$(printf '"%s"' "$(json::escape "$out_raw")")
    ;;
  redacted)
    [ -n "$in_raw" ] && in_text='"[REDACTED]"'
    [ -n "$out_raw" ] && out_text='"[REDACTED]"'
    ;;
  esac

  record=$(printf '{"@timestamp":"%s","event":{"action":"tool-call","created":"%s","dataset":"agent_audit.tool_call","kind":"event"},"user":{"id":%s,"name":%s},"host":{"name":%s,"hostname":%s},"agent_audit":{"agent":{"provider":"anthropic","name":"claude-code","account":{"id":%s,"name":%s,"email":%s},"organization":{"id":%s,"name":%s}},"conversation_id":%s,"turn_id":%s,"tool_call":{"tool":{"name":%s,"call_id":%s},"input":{"text":%s,"encrypted_text":null,"length":%s},"output":{"text":%s,"encrypted_text":null,"length":%s}}}}' \
    "$ts" "$ts" \
    "$(jv_raw "$user_id")" "$(jv_raw "$user_name")" \
    "$(jv_raw "$host_name")" "$(jv_raw "$host_hostname")" \
    "$(jv_esc "$acct_id")" "$(jv_esc "$acct_name")" "$(jv_esc "$acct_email")" \
    "$(jv_esc "$org_id")" "$(jv_esc "$org_name")" \
    "$(jv_esc "$session_esc")" "$(jv_esc "$turn_esc")" \
    "$(jv_esc "$tool_name_esc")" "$(jv_esc "$call_id_esc")" \
    "$in_text" "$in_len" \
    "$out_text" "$out_len")
}

build_audit_document() {
  derive_runtime_identity
  if [ "$stream" = user_prompt ]; then
    build_user_prompt_record
  else
    build_tool_call_record
  fi
}

deliver_document() {
  es_target="${es_url%/}/${data_stream}/_doc"
  curl_args=(-s -o /dev/null -w '%{http_code}' --max-time "$max_time"
    -X POST "$es_target" -H 'Content-Type: application/json')
  [ -n "$api_key" ] && curl_args+=(-H "Authorization: ApiKey $api_key")
  curl_args+=(--data-binary @-)

  http_code=$(printf '%s' "$record" | curl "${curl_args[@]}" 2>/dev/null) ||
    {
      log "POST to $es_target failed (curl error) — session proceeds uncaptured"
      done0
    }

  case "$http_code" in
  2*) log "indexed 1 audit document -> $es_target (HTTP $http_code)" ;;
  *) log "index returned HTTP $http_code (audit doc not stored) — session unaffected" ;;
  esac
  done0
}
