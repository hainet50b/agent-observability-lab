#!/usr/bin/env bash
#
# render-hook.sh — register the Claude Code audit hooks in
# <target>/.claude/settings.local.json (POSIX/bash).
#
# Claude Code registers hooks in settings (not a separate hooks file). This merges
# the `hooks` block from the agent-owned template ../hook.template.json into the
# target's settings.local.json, substituting @@USER_PROMPT_COMMAND@@ /
# @@TOOL_CALL_COMMAND@@ with THIS platform's capture-user-prompt.sh /
# capture-tool-call.sh absolute paths plus `--config <abs>/.claude/agent-audit.conf`.
# UserPromptSubmit fires capture-user-prompt; PostToolUse fires capture-tool-call.
# The config path is INJECTED into each hook command (SPEC/agent-audit.md "Delivery
# and authorization") — a shipped hook never discovers its own config.
#
# JSON key-merge, create-if-absent: writes { "hooks": {…} } when the file is
# absent; adds `hooks` to an existing file only if it has none; never clobbers an
# existing `hooks` (your edits survive). Re-running is a no-op. `jq` is fine here —
# render is setup tooling, not the fleet hook.
#
# Usage: render-hook.sh <target-dir>

set -euo pipefail

target=${1:-}
if [ -z "$target" ]; then
  echo "usage: render-hook.sh <target-dir>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/hook.template.json"
USER_PROMPT_CAPTURE="$COMPONENT_DIR/hooks/capture-user-prompt.sh"
TOOL_CALL_CAPTURE="$COMPONENT_DIR/hooks/capture-tool-call.sh"
out="$target/.claude/settings.local.json"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

# Never clobber an existing hooks block (create-if-absent).
if [ -e "$out" ] && jq -e 'has("hooks")' "$out" >/dev/null 2>&1; then
  echo "kept existing hooks in $out (delete to regenerate)"
  exit 0
fi

mkdir -p "$target/.claude"
target_abs=$(cd -- "$target" && pwd)
conf="$target_abs/.claude/agent-audit.conf"
user_prompt_cmd="$USER_PROMPT_CAPTURE --config $conf"
tool_call_cmd="$TOOL_CALL_CAPTURE --config $conf"

# Substitute each event's command placeholder, then take the `hooks` block
# (this also drops the template's _comment).
hooks_json=$(jq \
  --arg up "$user_prompt_cmd" \
  --arg tc "$tool_call_cmd" \
  '.hooks.UserPromptSubmit[0].hooks[0].command = $up
   | .hooks.PostToolUse[0].hooks[0].command = $tc
   | .hooks' "$TEMPLATE")

if [ -e "$out" ]; then
  # File exists but has no hooks — add `hooks` only, leave everything else intact.
  tmp=$(mktemp)
  jq --argjson hooks "$hooks_json" '.hooks = $hooks' "$out" >"$tmp"
  mv "$tmp" "$out"
  echo "added hooks to $out"
else
  jq -n --argjson hooks "$hooks_json" '{hooks: $hooks}' >"$out"
  echo "wrote $out"
fi
