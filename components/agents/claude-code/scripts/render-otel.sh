#!/usr/bin/env bash
#
# render-otel.sh — render the Claude Code agent's telemetry `env` block into
# <target>/.claude/settings.local.json.
#
# The telemetry env knobs are the agent's property and live once in the
# agent-owned template ../otel.template.json. This renders that template's
# `env` block into the target's settings, filling the four values that are NOT
# the agent's to fix — the three full per-signal OTLP endpoints and the headers:
#   @@OTLP_LOGS_ENDPOINT@@     full logs endpoint    (e.g. http://localhost:8200/v1/logs)
#   @@OTLP_TRACES_ENDPOINT@@   full traces endpoint
#   @@OTLP_METRICS_ENDPOINT@@  full metrics endpoint
#   @@OTLP_HEADERS@@           OTLP headers string   (empty for the local demo)
# The caller supplies the FULL per-signal endpoints — this script does no path
# construction (the /v1/<signal> path is the backend's to choose).
#
# Telemetry only: this renders `env`. The prompt-capture/audit hook belongs to
# the separate claude-code-elastic-audit stack (render-hook), not here.
#
# JSON key-merge, create-if-absent: writes { "env": {…} } when the file is
# absent; adds `env` to an existing file only if it has no `env` key; never
# clobbers an existing `env` (your edits survive). Re-running is a no-op.
#
# Usage: render-otel.sh <target-dir> <logs-endpoint> <traces-endpoint> <metrics-endpoint> [otlp-headers]

set -euo pipefail

target=${1:-}
logs=${2:-}
traces=${3:-}
metrics=${4:-}
headers=${5:-}

if [ -z "$target" ] || [ -z "$logs" ] || [ -z "$traces" ] || [ -z "$metrics" ]; then
  echo "usage: render-otel.sh <target-dir> <logs-endpoint> <traces-endpoint> <metrics-endpoint> [otlp-headers]" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/otel.template.json"
out="$target/.claude/settings.local.json"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

# Never clobber an existing env block (create-if-absent).
if [ -e "$out" ] && jq -e 'has("env")' "$out" >/dev/null 2>&1; then
  echo "kept existing env in $out (delete to regenerate)"
  exit 0
fi

# Render the template's env block: fill the four tokens, drop _comment.
env_json=$(sed \
  -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs#" \
  -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces#" \
  -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics#" \
  -e "s#@@OTLP_HEADERS@@#$headers#" \
  "$TEMPLATE" | jq '.env')

mkdir -p "$target/.claude"
if [ -e "$out" ]; then
  # File exists but has no env — add `env` only, leave everything else intact.
  tmp=$(mktemp)
  jq --argjson env "$env_json" '.env = $env' "$out" >"$tmp"
  mv "$tmp" "$out"
  echo "added env to $out"
else
  jq -n --argjson env "$env_json" '{env: $env}' >"$out"
  echo "wrote $out"
fi
