#!/usr/bin/env bash
# shellcheck disable=SC2154

set -u

default_timeout_ms=1000

stream=""
config_file=""

log() { printf '[agent-audit%s] %s\n' "${stream:+ $stream}" "$*" >&2; }
done0() { exit 0; }

parse_args() {
  config_file=""
  stream=""
  while [ "$#" -gt 0 ]; do
    case $1 in
    --config)
      if [ "$#" -ge 2 ]; then
        config_file=$2
        shift 2
      else
        shift
      fi
      ;;
    --stream)
      if [ "$#" -ge 2 ]; then
        stream=$2
        shift 2
      else
        shift
      fi
      ;;
    *) shift ;;
    esac
  done
}

require_stream() {
  case ${1:-} in
  user_prompt | tool_call) return 0 ;;
  *)
    log "no valid --stream <user_prompt|tool_call> provided — skipping"
    done0
    ;;
  esac
}

require_config() {
  [ -n "$config_file" ] || {
    log "no --config <path> provided — skipping"
    done0
  }
  [ -f "$config_file" ] || {
    log "no delivery config at $config_file — skipping"
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
  key=$1
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    case $_k in
    '#'*) continue ;;
    esac
    if [ "$_k" = "$key" ]; then
      printf '%s' "${_v%$'\r'}"
      return 0
    fi
  done <"$config_file"
  return 0
}

awk_get='BEGIN{
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
json::string_field() { JSON=$1 KEY=$2 awk "$awk_get"; }

awk_ord='function is_cont(ch,  v){ v=index(ord,ch); return (v>=128 && v<192) }
BEGIN{ ord=""; for(_k=1;_k<256;_k++) ord=ord sprintf("%c",_k); }'

awk_strlen=$awk_ord'
BEGIN{
  s=ENVIRON["ESC"]; n=length(s); i=1; c=0;
  while(i<=n){ ch=substr(s,i,1);
    if(ch=="\\"){ nx=substr(s,i+1,1); if(nx=="u"){i+=6}else{i+=2} c++; continue }
    i++;
    while(i<=n && is_cont(substr(s,i,1))) i++;
    c++ }
  printf "%d", c
}'
json::char_count() { ESC=$1 LC_ALL=C LANG=C awk "$awk_strlen" </dev/null; }

awk_codepoint=$awk_ord'
BEGIN{
  s=ENVIRON["RAW"]; n=length(s); c=0;
  for(i=1;i<=n;i++){ if(!is_cont(substr(s,i,1))) c++ }
  printf "%d", c
}'
json::codepoint_count() { RAW=$1 LC_ALL=C LANG=C awk "$awk_codepoint" </dev/null; }

awk_get_raw='BEGIN{
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
json::raw_value() { JSON=$1 KEY=$2 awk "$awk_get_raw"; }

awk_esc='BEGIN{ s=ENVIRON["RAW"];
  gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s);
  gsub(/\n/,"\\n",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s);
  printf "%s", s }'
json::escape() { RAW=$1 awk "$awk_esc"; }

jv_esc() { if [ -n "$1" ]; then printf '"%s"' "$1"; else printf 'null'; fi; }
jv_raw() { if [ -n "$1" ]; then printf '"%s"' "$(json::escape "$1")"; else printf 'null'; fi; }

load_delivery_config() {
  local stream=$1
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
  case "$timeout_ms" in '' | *[!0-9]*) timeout_ms=$default_timeout_ms ;; esac
  max_time=$(printf '%d.%03d' "$((timeout_ms / 1000))" "$((timeout_ms % 1000))")
}

require_stream_enabled() {
  local stream=$1
  [ "$enabled" = false ] && {
    log "capture.$stream.enabled=false — skipping (stream disabled)"
    done0
  }
  return 0
}

read_hook_payload() {
  local stream=$1
  payload=$(cat)
  [ -n "$payload" ] || {
    log "empty stdin — nothing to capture"
    done0
  }
  case $stream in
  user_prompt)
    escaped_prompt=$(json::string_field "$payload" prompt)
    [ -n "$escaped_prompt" ] || {
      log "no prompt in payload — nothing to capture"
      done0
    }
    session_id=$(json::string_field "$payload" session_id)
    turn_id=$(json::string_field "$payload" turn_id)
    prompt_length=$(json::char_count "$escaped_prompt")
    ;;
  tool_call)
    tool_name=$(json::string_field "$payload" tool_name)
    call_id=$(json::string_field "$payload" tool_use_id)
    session_id=$(json::string_field "$payload" session_id)
    turn_id=$(json::string_field "$payload" turn_id)
    input_raw=$(json::raw_value "$payload" tool_input)
    output_raw=$(json::raw_value "$payload" tool_response)
    input_length=$(json::codepoint_count "$input_raw")
    output_length=$(json::codepoint_count "$output_raw")
    ;;
  *)
    log "unknown stream '$stream' — skipping"
    done0
    ;;
  esac
}

build_user_prompt_record() {
  case "$content" in
  plaintext) prompt_text=$(jv_esc "$escaped_prompt") ;;
  redacted) prompt_text='"[REDACTED]"' ;;
  *) prompt_text=null ;;
  esac

  record=$(printf '{"@timestamp":"%s","event":{"action":"user-prompt","created":"%s","dataset":"agent_audit.user_prompt","kind":"event"},"user":{"id":%s,"name":%s},"host":{"name":%s,"hostname":%s},"agent_audit":{"agent":{"provider":"%s","name":"%s","account":{"id":%s,"name":%s,"email":%s},"organization":{"id":%s,"name":%s}},"conversation_id":%s,"turn_id":%s,"user_prompt":{"text":%s,"encrypted_text":null,"length":%s}}}' \
    "$ts" "$ts" \
    "$(jv_raw "$user_id")" "$(jv_raw "$user_name")" \
    "$(jv_raw "$host_name")" "$(jv_raw "$host_hostname")" \
    "$provider" "$agent_name" \
    "$(jv_esc "$account_id")" "$(jv_esc "$account_name")" "$(jv_esc "$account_email")" \
    "$(jv_esc "$organization_id")" "$(jv_esc "$organization_name")" \
    "$(jv_esc "$session_id")" "$(jv_esc "$turn_id")" \
    "$prompt_text" "$prompt_length")
}

build_tool_call_record() {
  input_text=null
  output_text=null
  case "$content" in
  plaintext)
    [ -n "$input_raw" ] && input_text=$(printf '"%s"' "$(json::escape "$input_raw")")
    [ -n "$output_raw" ] && output_text=$(printf '"%s"' "$(json::escape "$output_raw")")
    ;;
  redacted)
    [ -n "$input_raw" ] && input_text='"[REDACTED]"'
    [ -n "$output_raw" ] && output_text='"[REDACTED]"'
    ;;
  esac

  record=$(printf '{"@timestamp":"%s","event":{"action":"tool-call","created":"%s","dataset":"agent_audit.tool_call","kind":"event"},"user":{"id":%s,"name":%s},"host":{"name":%s,"hostname":%s},"agent_audit":{"agent":{"provider":"%s","name":"%s","account":{"id":%s,"name":%s,"email":%s},"organization":{"id":%s,"name":%s}},"conversation_id":%s,"turn_id":%s,"tool_call":{"tool":{"name":%s,"call_id":%s},"input":{"text":%s,"encrypted_text":null,"length":%s},"output":{"text":%s,"encrypted_text":null,"length":%s}}}}' \
    "$ts" "$ts" \
    "$(jv_raw "$user_id")" "$(jv_raw "$user_name")" \
    "$(jv_raw "$host_name")" "$(jv_raw "$host_hostname")" \
    "$provider" "$agent_name" \
    "$(jv_esc "$account_id")" "$(jv_esc "$account_name")" "$(jv_esc "$account_email")" \
    "$(jv_esc "$organization_id")" "$(jv_esc "$organization_name")" \
    "$(jv_esc "$session_id")" "$(jv_esc "$turn_id")" \
    "$(jv_esc "$tool_name")" "$(jv_esc "$call_id")" \
    "$input_text" "$input_length" \
    "$output_text" "$output_length")
}

build_audit_document() {
  local stream=$1
  derive_runtime_identity
  case $stream in
  user_prompt) build_user_prompt_record ;;
  tool_call) build_tool_call_record ;;
  *)
    log "unknown stream '$stream' — skipping"
    done0
    ;;
  esac
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
