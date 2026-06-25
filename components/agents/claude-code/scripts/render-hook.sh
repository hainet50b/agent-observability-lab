#!/usr/bin/env bash

set -euo pipefail

target=${1:-}
endpoint=${2:-}
if [ -z "$target" ] || [ -z "$endpoint" ]; then
  echo "usage: render-hook.sh <target-dir> <endpoint>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/templates/hook.template.json"
HOOKS_SRC="$COMPONENT_DIR/hooks"
CORE_SRC="$COMPONENT_DIR/../shared/agent-audit/lib"
out="$target/.claude/settings.local.json"
# shellcheck source=/dev/null
. "$COMPONENT_DIR/../shared/config-place/lib/config-place-core.sh"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

config_place::assert_ours_or_absent 'hook' "$endpoint" "$out" || true

mkdir -p "$target/.claude"
target_abs=$(cd -- "$target" && pwd)

hooks_dst="$target_abs/.claude/hooks"
mkdir -p "$hooks_dst/lib"
cp "$HOOKS_SRC/agent-audit.sh" "$HOOKS_SRC/agent-audit.ps1" "$hooks_dst/"
cp "$HOOKS_SRC/lib/adapter.sh" "$HOOKS_SRC/lib/adapter.ps1" "$hooks_dst/lib/"
cp "$CORE_SRC/agent-audit-core.sh" "$CORE_SRC/agent-audit-core.ps1" "$hooks_dst/lib/"
cp "$CORE_SRC/seal.sh" "$CORE_SRC/seal.ps1" "$hooks_dst/lib/"
chmod +x "$hooks_dst/agent-audit.sh"
ENTRY="$hooks_dst/agent-audit.sh"

conf="$target_abs/.claude/agent-audit.conf"
user_prompt_cmd="'$ENTRY' --stream user_prompt --config '$conf'"
tool_call_cmd="'$ENTRY' --stream tool_call --config '$conf'"

hooks_block=$(mktemp)
tmp=$(mktemp)
trap 'rm -f "$hooks_block" "$tmp"' EXIT
jq \
  --arg up "$user_prompt_cmd" \
  --arg tc "$tool_call_cmd" \
  '.hooks.UserPromptSubmit[0].hooks[0].command = $up
   | .hooks.PostToolUse[0].hooks[0].command = $tc
   | .hooks' "$TEMPLATE" >"$hooks_block"

# Merge our .hooks into the existing settings.local.json, preserving any other
# top-level keys (e.g. .env placed by the telemetry concern sharing this home).
base='{}'
[ -f "$out" ] && base=$(cat "$out")
printf '%s' "$base" | jq --slurpfile h "$hooks_block" '.hooks = $h[0]' >"$tmp"

config_place::place_file 'hook' 'claude-code' "$endpoint" "$tmp" "$out"
config_place::place_self_ignore 'claude-code' "$endpoint" "$target_abs/.claude"
