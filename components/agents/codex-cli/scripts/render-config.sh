#!/usr/bin/env bash
#
# render-config.sh — render the Codex CLI agent's session config.toml.
#
# The telemetry config *content* (the [otel] block) is the agent's property and
# lives once in the agent-owned template ../config.template.toml. This renders
# that template into <target>/.codex/config.toml, filling the one value that is
# NOT the agent's to fix:
#   - @@OTLP_ENDPOINT@@   the stack's OTLP endpoint (direct APM vs Collector)
# so a Codex session launched with CODEX_HOME=<target>/.codex reads it as
# user-level config and emits telemetry into the stack WITHOUT touching the
# user's ~/.codex. (A repo-local .codex/config.toml does NOT work for [otel] —
# Codex ignores otel keys in project-local config; CODEX_HOME is the supported
# per-project mechanism.) The rendered file is gitignored (.codex/ in the repo root).
#
# No TOML tooling needed — the single token is a URL, sed-safe with a # delimiter.
#
# create-if-absent: an existing config.toml is left untouched (your edits
# survive). Delete it to regenerate.
#
# Usage: render-config.sh <otlp-endpoint> <target-dir>

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/config.template.toml"

endpoint=${1:-}
target=${2:-}
[ -n "$endpoint" ] && [ -n "$target" ] || { echo "usage: render-config.sh <otlp-endpoint> <target-dir>" >&2; exit 2; }
out="$target/.codex/config.toml"

[ -f "$TEMPLATE" ] || { echo "FAIL: template not found: $TEMPLATE" >&2; exit 1; }

if [ -e "$out" ]; then
  echo "kept existing $out (delete to regenerate)"
  exit 0
fi

mkdir -p "$target/.codex"
sed -e "s#@@OTLP_ENDPOINT@@#$endpoint#" "$TEMPLATE" > "$out"

echo "wrote $out"
