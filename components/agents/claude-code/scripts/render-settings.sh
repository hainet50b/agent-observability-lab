#!/usr/bin/env bash
#
# render-settings.sh — render the Claude Code agent's settings.local.json.
#
# The settings *content* (telemetry env knobs + the prompt-audit hook
# registration) is the agent's property and lives once in the agent-owned
# template ../settings.template.json. This renders that template into
# <target>/.claude/settings.local.json, filling the three values that are NOT
# the agent's to fix:
#   - @@OTLP_ENDPOINT@@        the stack's OTLP endpoint (direct APM vs Collector)
#   - @@PROMPTS_AUDIT_ES_URL@@ the audit store endpoint (default below)
#   - @@HOOK_COMMAND@@         this machine's absolute path to capture-prompt.sh
# so a `claude` launched from <target> auto-emits telemetry and audits prompts.
#
# The hook command is the POSIX form (capture-prompt.sh); render-settings.ps1
# writes the PowerShell form. No jq needed — the template tokens are filled with
# sed (the values are URLs / a filesystem path, all sed-safe with a # delimiter).
#
# create-if-absent: an existing settings.local.json is left untouched (your edits
# survive). Delete it to regenerate.
#
# Usage: render-settings.sh <otlp-endpoint> <target-dir>
#   PROMPTS_AUDIT_ES_URL overrides the audit endpoint (default http://localhost:9200).

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/settings.template.json"

endpoint=${1:-}
target=${2:-}
if [ -z "$endpoint" ] || [ -z "$target" ]; then
  echo "usage: render-settings.sh <otlp-endpoint> <target-dir>" >&2
  exit 2
fi
audit=${PROMPTS_AUDIT_ES_URL:-http://localhost:9200}
hook="$COMPONENT_DIR/hooks/capture-prompt.sh"
out="$target/.claude/settings.local.json"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

if [ -e "$out" ]; then
  echo "kept existing $out (delete to regenerate)"
  exit 0
fi

mkdir -p "$target/.claude"
sed -e "s#@@OTLP_ENDPOINT@@#$endpoint#" \
  -e "s#@@PROMPTS_AUDIT_ES_URL@@#$audit#" \
  -e "s#@@HOOK_COMMAND@@#$hook#" \
  "$TEMPLATE" >"$out"

echo "wrote $out"
