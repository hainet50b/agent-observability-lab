#!/usr/bin/env bash
#
# render-hooks.sh — write the Codex CLI agent's stack-local .codex/hooks.json.
#
# Registers two hooks into <target>/.codex/hooks.json, so a Codex session
# launched with CODEX_HOME=<target>/.codex picks them up as user-level hooks
# config — coexisting with the [otel] config.toml that render-config writes
# (Codex reads hooks.json and config.toml side by side under CODEX_HOME):
#   * UserPromptSubmit -> hooks/capture-user-prompt.{sh,ps1} — the production
#     Agent Audit hook; at run time it delivers each submitted prompt to the
#     local Agent Audit data stream using the delivery config in
#     .codex/agent-audit.toml (see render-agent-audit.sh).
#   * PostToolUse -> hooks/capture-tool-call.{sh,ps1} — the production Agent
#     Audit tool-call hook; at run time it delivers each completed tool call to
#     the local Agent Audit data stream `logs-agent_audit.tool_call-default`
#     using the same .codex/agent-audit.toml delivery config (see
#     render-agent-audit.sh).
#
# The hook scripts are referenced by ABSOLUTE path (resolved from this
# component): `command` for POSIX hosts and `commandWindows` (pwsh) for Windows.
# hooks.json is written under .codex/, which is gitignored — it carries
# machine-specific absolute paths.
#
# create-if-absent: an existing hooks.json is left untouched (delete to
# regenerate — e.g. after the repo moves and the absolute paths go stale).
#
# Usage: render-hooks.sh <target-dir>

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
HOOKS_DIR="$COMPONENT_DIR/hooks"
HOOK_SH="$HOOKS_DIR/capture-user-prompt.sh"
HOOK_PS1="$HOOKS_DIR/capture-user-prompt.ps1"
TOOL_SH="$HOOKS_DIR/capture-tool-call.sh"
TOOL_PS1="$HOOKS_DIR/capture-tool-call.ps1"

target=${1:-}
[ -n "$target" ] || {
  echo "usage: render-hooks.sh <target-dir>" >&2
  exit 2
}

[ -f "$HOOK_SH" ] || {
  echo "FAIL: hook not found: $HOOK_SH" >&2
  exit 1
}
[ -f "$HOOK_PS1" ] || {
  echo "FAIL: hook not found: $HOOK_PS1" >&2
  exit 1
}
[ -f "$TOOL_SH" ] || {
  echo "FAIL: hook not found: $TOOL_SH" >&2
  exit 1
}
[ -f "$TOOL_PS1" ] || {
  echo "FAIL: hook not found: $TOOL_PS1" >&2
  exit 1
}

out="$target/.codex/hooks.json"
if [ -e "$out" ]; then
  echo "kept existing $out (delete to regenerate)"
  exit 0
fi

mkdir -p "$target/.codex"

# POSIX absolute paths carry no JSON-special characters, so a heredoc is safe.
cat > "$out" << JSON
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_SH",
            "commandWindows": "pwsh -NoProfile -File $HOOK_PS1",
            "timeout": 10,
            "statusMessage": "delivering UserPromptSubmit audit document"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$TOOL_SH",
            "commandWindows": "pwsh -NoProfile -File $TOOL_PS1",
            "timeout": 10,
            "statusMessage": "delivering PostToolUse audit document"
          }
        ]
      }
    ]
  }
}
JSON

echo "wrote $out"
