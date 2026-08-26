#!/usr/bin/env bash
# shellcheck disable=SC2034

provider='anthropic'
agent_name='claude'
CLAUDE_CONFIG=${CLAUDE_CONFIG:-$HOME/.claude.json}

# Relative-path candidates for config-provenance runtime_hash (T8), mirroring
# the render-time entries in agent-config/src/agents/claude.rs. `home_dir` is
# the local/project agent home (".claude"); `target_root` is its parent,
# where the Local-scope ".mcp.json" sibling lands.
audit_provenance_local_pairs() {
  home_dir=$1
  target_root=$2
  provenance_abs+=("$home_dir/.gitignore")
  provenance_rel+=(".claude/.gitignore")
  provenance_abs+=("$home_dir/hooks/agent-audit.conf")
  provenance_rel+=(".claude/hooks/agent-audit.conf")
  provenance_abs+=("$home_dir/hooks/agent-audit.sh")
  provenance_rel+=(".claude/hooks/agent-audit.sh")
  provenance_abs+=("$home_dir/hooks/lib/adapter.sh")
  provenance_rel+=(".claude/hooks/lib/adapter.sh")
  provenance_abs+=("$home_dir/hooks/lib/agent-audit-core.sh")
  provenance_rel+=(".claude/hooks/lib/agent-audit-core.sh")
  provenance_abs+=("$home_dir/hooks/lib/seal.sh")
  provenance_rel+=(".claude/hooks/lib/seal.sh")
  provenance_abs+=("$home_dir/hooks/recipient.pem")
  provenance_rel+=(".claude/hooks/recipient.pem")
  provenance_abs+=("$home_dir/settings.local.json")
  provenance_rel+=(".claude/settings.local.json")
  provenance_abs+=("$target_root/.mcp.json")
  provenance_rel+=(".mcp.json")
}

# Same, for a managed cell: `managed_root` is the host managed root
# (agent-config/src/agents/claude.rs managed_root), `executor` is the owning
# config's executor (the hook's own directory name under managed_root/hooks).
audit_provenance_managed_pairs() {
  executor=$1
  managed_root=$2
  root_rel=${managed_root#/}
  provenance_abs+=("$managed_root/hooks/$executor/agent-audit.conf")
  provenance_rel+=("$root_rel/hooks/$executor/agent-audit.conf")
  provenance_abs+=("$managed_root/hooks/$executor/agent-audit.sh")
  provenance_rel+=("$root_rel/hooks/$executor/agent-audit.sh")
  provenance_abs+=("$managed_root/hooks/$executor/lib/adapter.sh")
  provenance_rel+=("$root_rel/hooks/$executor/lib/adapter.sh")
  provenance_abs+=("$managed_root/hooks/$executor/lib/agent-audit-core.sh")
  provenance_rel+=("$root_rel/hooks/$executor/lib/agent-audit-core.sh")
  provenance_abs+=("$managed_root/hooks/$executor/lib/seal.sh")
  provenance_rel+=("$root_rel/hooks/$executor/lib/seal.sh")
  provenance_abs+=("$managed_root/hooks/$executor/recipient.pem")
  provenance_rel+=("$root_rel/hooks/$executor/recipient.pem")
  provenance_abs+=("$managed_root/managed-settings.d/10-$executor.json")
  provenance_rel+=("$root_rel/managed-settings.d/10-$executor.json")
}

derive_runtime_identity() {
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _ms=$(date -u +%3N 2>/dev/null)
  case $_ms in
  [0-9][0-9][0-9]) ts="${ts%Z}.${_ms}Z" ;;
  esac

  user_name=${USER:-${USERNAME:-$(id -un 2>/dev/null || echo "")}}
  user_id=$(whoami 2>/dev/null || echo "")

  host_hostname=${HOSTNAME:-}
  [ -n "$host_hostname" ] || host_hostname=$(hostname 2>/dev/null || echo "")
  [ -n "$host_hostname" ] || host_hostname=${COMPUTERNAME:-}
  host_name=$host_hostname

  account_id="" account_name="" account_email="" organization_id="" organization_name=""
  if [ -f "$CLAUDE_CONFIG" ]; then
    claude=$(cat "$CLAUDE_CONFIG" 2>/dev/null || echo "")
    oauth=$(json::raw_value "$claude" oauthAccount)
    if [ -n "$oauth" ]; then
      account_id=$(json::string_field "$oauth" accountUuid)
      account_name=$(json::string_field "$oauth" displayName)
      account_email=$(json::string_field "$oauth" emailAddress)
      organization_id=$(json::string_field "$oauth" organizationUuid)
      organization_name=$(json::string_field "$oauth" organizationName)
    fi
  fi
}
