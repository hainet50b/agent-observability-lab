#!/usr/bin/env bash
set -euo pipefail

target_dir=${1:-}

[ -n "$target_dir" ] || {
  echo "Usage: render-hooks.sh <target-dir>" >&2
  exit 2
}

config="$target_dir/.codex/config.toml"
agent_audit_conf="$target_dir/.codex/agent-audit.conf"

if [ -e "$config" ] && grep -qF '[[hooks.UserPromptSubmit]]' "$config"; then
  echo "Skipped: $config already has [[hooks.UserPromptSubmit]]"
  exit 0
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
hooks_src="$component_dir/hooks"
core_src="$component_dir/../shared/agent-audit/lib"
template="$component_dir/templates/hooks.template.toml"

for hook in "$hooks_src/agent-audit.sh" "$hooks_src/agent-audit.ps1"; do
  [ -f "$hook" ] || {
    echo "FAIL: hook not found: $hook" >&2
    exit 1
  }
done
[ -f "$template" ] || {
  echo "FAIL: template not found: $template" >&2
  exit 1
}

mkdir -p "$target_dir/.codex"
target_abs=$(cd -- "$target_dir" && pwd)
hooks_dst="$target_abs/.codex/hooks"
mkdir -p "$hooks_dst/lib"
cp "$hooks_src/agent-audit.sh" "$hooks_src/agent-audit.ps1" "$hooks_dst/"
cp "$hooks_src/lib/adapter.sh" "$hooks_src/lib/adapter.ps1" "$hooks_dst/lib/"
cp "$core_src/agent-audit-core.sh" "$core_src/agent-audit-core.ps1" "$hooks_dst/lib/"
chmod +x "$hooks_dst/agent-audit.sh"
agent_audit_sh="$hooks_dst/agent-audit.sh"
agent_audit_ps1="$hooks_dst/agent-audit.ps1"

block=$(sed \
  -e "s#@@AGENT_AUDIT_SH@@#$agent_audit_sh#" \
  -e "s#@@AGENT_AUDIT_PS1@@#$agent_audit_ps1#" \
  -e "s#@@AGENT_AUDIT_CONF@@#$agent_audit_conf#" \
  "$template")

[ -e "$config" ] && printf '\n' >>"$config"
printf '%s\n' "$block" >>"$config"
