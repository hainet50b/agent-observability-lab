#!/usr/bin/env bash
#
# render-hooks.sh — append the Codex CLI agent's [hooks] tables to
# <target>/.codex/config.toml (from hooks.template.toml).
#
# Registers two hooks as inline [[hooks.<Event>]] tables in config.toml, so a
# Codex session launched with CODEX_HOME=<target>/.codex picks them up as
# user-level hooks — alongside the [otel] / [mcp_servers] tables the other
# render-* scripts append to the same config.toml (one representation per layer:
# inline [hooks], never a sidecar hooks.json):
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
# config.toml lives under .codex/, which is gitignored — it carries
# machine-specific absolute paths.
#
# append-if-absent: skip when config.toml already contains the [[hooks.UserPromptSubmit]]
# table (delete the [hooks] tables to regenerate — e.g. after the repo moves and the
# absolute paths go stale). When config.toml exists without it, the tables are
# appended (blank-line separated); when it does not exist, it is created.
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
TEMPLATE="$COMPONENT_DIR/hooks.template.toml"

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
[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

config="$target/.codex/config.toml"

if [ -e "$config" ] && grep -qF '[[hooks.UserPromptSubmit]]' "$config"; then
  echo "Skipped: $config already has [[hooks.UserPromptSubmit]]"
  exit 0
fi

mkdir -p "$target/.codex"
block=$(sed \
  -e "s#@@USER_PROMPT_SH@@#$HOOK_SH#" \
  -e "s#@@USER_PROMPT_PS1@@#$HOOK_PS1#" \
  -e "s#@@TOOL_CALL_SH@@#$TOOL_SH#" \
  -e "s#@@TOOL_CALL_PS1@@#$TOOL_PS1#" \
  "$TEMPLATE")

[ -e "$config" ] && printf '\n' >>"$config"
printf '%s\n' "$block" >>"$config"

echo "wrote [hooks] tables to $config"
