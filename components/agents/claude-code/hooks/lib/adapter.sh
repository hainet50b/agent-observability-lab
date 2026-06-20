#!/usr/bin/env bash
# shellcheck disable=SC2034

provider='anthropic'
agent_name='claude-code'
user_prompt_turn_id_supported=false
CLAUDE_CONFIG=${CLAUDE_CONFIG:-$HOME/.claude.json}

derive_runtime_identity() {
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

  user_name=${USER:-${USERNAME:-$(id -un 2>/dev/null || echo "")}}
  user_id=$(whoami 2>/dev/null || echo "")

  host_hostname=${HOSTNAME:-}
  [ -n "$host_hostname" ] || host_hostname=$(hostname 2>/dev/null || echo "")
  [ -n "$host_hostname" ] || host_hostname=${COMPUTERNAME:-}
  host_name=$host_hostname

  account_id="" account_email="" account_name="" org_id="" org_name=""
  if [ -f "$CLAUDE_CONFIG" ]; then
    claude=$(cat "$CLAUDE_CONFIG" 2>/dev/null || echo "")
    oauth=$(json::raw_value "$claude" oauthAccount)
    if [ -n "$oauth" ]; then
      account_id=$(json::string_field "$oauth" accountUuid)
      account_name=$(json::string_field "$oauth" displayName)
      account_email=$(json::string_field "$oauth" emailAddress)
      org_id=$(json::string_field "$oauth" organizationUuid)
      org_name=$(json::string_field "$oauth" organizationName)
    fi
  fi
}
