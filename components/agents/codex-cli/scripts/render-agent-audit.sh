#!/usr/bin/env bash
#
# render-agent-audit.sh — render the Codex CLI agent's .codex/agent-audit.toml
# (the Agent Audit hook's Elasticsearch delivery config).
#
# Fills the single @@ES_URL@@ placeholder in the agent-owned template
# ../agent-audit.template.toml with the stack's Elasticsearch base URL and writes
# the result to <target>/.codex/agent-audit.toml, beside the config.toml / hooks.json
# that render-config / render-hooks write under CODEX_HOME=<target>/.codex. The
# UserPromptSubmit hook reads this file to deliver captured prompts to the local
# Agent Audit data stream (see ../../../SPEC/agent-audit.md). This script only
# GENERATES the delivery config — wiring the hook to read and POST it is separate.
# The rendered file is gitignored (.codex/ in the repo root).
#
# No TOML tooling needed — the single token is a URL, sed-safe with a # delimiter.
#
# create-if-absent: an existing agent-audit.toml is left untouched, so a real
# api_key you add survives. Delete it to regenerate.
#
# Usage: render-agent-audit.sh <es-url> <target-dir>

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/agent-audit.template.toml"

es_url=${1:-}
target=${2:-}
if [ -z "$es_url" ] || [ -z "$target" ]; then
  echo "usage: render-agent-audit.sh <es-url> <target-dir>" >&2
  exit 2
fi
out="$target/.codex/agent-audit.toml"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

if [ -e "$out" ]; then
  echo "kept existing $out (delete to regenerate)"
  exit 0
fi

mkdir -p "$target/.codex"
sed -e "s#@@ES_URL@@#$es_url#" "$TEMPLATE" > "$out"

echo "wrote $out"
