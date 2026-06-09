#!/usr/bin/env bash
#
# sync-claude-settings.sh — DEV-ONLY helper for lab maintainers.
#
# Each stack's scripts/setup.sh generates stacks/<stack>/.claude/settings.local.json
# (telemetry env + audit hook), which applies only when `claude` is launched from
# that stack directory (project settings load from the launch dir, not parents).
# Lab maintainers tend to launch `claude` at the repo root instead, so this copies
# a stack's generated settings up to the repo-root .claude/ so a root-launched
# session uses the same telemetry + audit config.
#
# The .claude/ directories are gitignored; only this helper is committed.
#
# Usage:  dev/sync-claude-settings.sh <stack>
#   e.g.  dev/sync-claude-settings.sh claude-code-otelcol-elastic

set -euo pipefail

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stack=${1:-}
[ -n "$stack" ] || { echo "usage: dev/sync-claude-settings.sh <stack>" >&2; exit 2; }

src="$REPO/stacks/$stack/.claude/settings.local.json"
dst="$REPO/.claude/settings.local.json"

[ -f "$src" ] || { echo "not found: $src" >&2
  echo "run 'cd stacks/$stack && scripts/setup.sh' first" >&2; exit 1; }

mkdir -p "$REPO/.claude"
cp "$src" "$dst"
echo "copied $src -> $dst"
echo "a 'claude' launched at the repo root now uses the $stack telemetry + audit config."
