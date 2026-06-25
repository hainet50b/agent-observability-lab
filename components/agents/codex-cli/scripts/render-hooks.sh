#!/usr/bin/env bash
set -euo pipefail

target_dir=${1:-}
endpoint=${2:-}

if [ -z "$target_dir" ] || [ -z "$endpoint" ]; then
  echo "Usage: render-hooks.sh <target-dir> <endpoint>" >&2
  exit 2
fi

config="$target_dir/.codex/config.toml"
agent_audit_conf="$target_dir/.codex/agent-audit.conf"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
hooks_src="$component_dir/hooks"
core_src="$component_dir/../shared/agent-audit/lib"
template="$component_dir/templates/hooks.template.toml"
# shellcheck source=/dev/null
. "$component_dir/../shared/config-place/lib/config-place-core.sh"

[ -f "$hooks_src/agent-audit.sh" ] || {
  echo "FAIL: hook not found: $hooks_src/agent-audit.sh" >&2
  exit 1
}
[ -f "$template" ] || {
  echo "FAIL: template not found: $template" >&2
  exit 1
}

config_place::assert_ours_or_absent 'hook' "$endpoint" "$config" || true

mkdir -p "$target_dir/.codex"
target_abs=$(cd -- "$target_dir" && pwd)
hooks_dst="$target_abs/.codex/hooks"
mkdir -p "$hooks_dst/lib"
cp "$hooks_src/agent-audit.sh" "$hooks_dst/"
cp "$hooks_src/lib/adapter.sh" "$hooks_dst/lib/"
cp "$core_src/agent-audit-core.sh" "$hooks_dst/lib/"
cp "$core_src/seal.sh" "$hooks_dst/lib/"
chmod +x "$hooks_dst/agent-audit.sh"
agent_audit_sh="$hooks_dst/agent-audit.sh"
agent_audit_ps1="$hooks_dst/agent-audit.ps1"

block=$(sed \
  -e "s#@@AGENT_AUDIT_SH@@#$agent_audit_sh#" \
  -e "s#@@AGENT_AUDIT_PS1@@#$agent_audit_ps1#" \
  -e "s#@@AGENT_AUDIT_CONF@@#$agent_audit_conf#" \
  "$template")

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$block" >"$tmp"

config_place::append_section 'hook' 'codex-cli' "$endpoint" "$tmp" "$config" '[[hooks.UserPromptSubmit]]'
config_place::place_self_ignore 'codex-cli' "$endpoint" "$target_abs/.codex"
