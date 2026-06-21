#!/usr/bin/env bash

set -euo pipefail

target=${1:-}
if [ -z "$target" ]; then
  echo "usage: render-hook.sh <target-dir>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/templates/hook.template.json"
HOOKS_SRC="$COMPONENT_DIR/hooks"
CORE_SRC="$COMPONENT_DIR/../shared/agent-audit/lib"
out="$target/.claude/settings.local.json"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

if [ -e "$out" ] && jq -e 'has("hooks")' "$out" >/dev/null 2>&1; then
  echo "kept existing hooks in $out (delete to regenerate)"
  exit 0
fi

mkdir -p "$target/.claude"
target_abs=$(cd -- "$target" && pwd)

hooks_dst="$target_abs/.claude/hooks"
mkdir -p "$hooks_dst/lib"
cp "$HOOKS_SRC/agent-audit.sh" "$HOOKS_SRC/agent-audit.ps1" "$hooks_dst/"
cp "$HOOKS_SRC/lib/adapter.sh" "$HOOKS_SRC/lib/adapter.ps1" "$hooks_dst/lib/"
cp "$CORE_SRC/agent-audit-core.sh" "$CORE_SRC/agent-audit-core.ps1" "$hooks_dst/lib/"
chmod +x "$hooks_dst/agent-audit.sh"
ENTRY="$hooks_dst/agent-audit.sh"

conf="$target_abs/.claude/agent-audit.conf"
user_prompt_cmd="$ENTRY --stream user_prompt --config $conf"
tool_call_cmd="$ENTRY --stream tool_call --config $conf"

hooks_json=$(jq \
  --arg up "$user_prompt_cmd" \
  --arg tc "$tool_call_cmd" \
  '.hooks.UserPromptSubmit[0].hooks[0].command = $up
   | .hooks.PostToolUse[0].hooks[0].command = $tc
   | .hooks' "$TEMPLATE")

if [ -e "$out" ]; then
  tmp=$(mktemp)
  jq --argjson hooks "$hooks_json" '.hooks = $hooks' "$out" >"$tmp"
  mv "$tmp" "$out"
  echo "added hooks to $out"
else
  jq -n --argjson hooks "$hooks_json" '{hooks: $hooks}' >"$out"
  echo "wrote $out"
fi
