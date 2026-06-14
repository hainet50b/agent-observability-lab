#!/usr/bin/env bash
#
# render-hooks.sh — write the Codex CLI agent's stack-local .codex/hooks.json.
#
# Registers the characterization hook hooks/capture-user-prompt.{sh,ps1} on
# Codex's `UserPromptSubmit` event into <target>/.codex/hooks.json, so a Codex
# session launched with CODEX_HOME=<target>/.codex picks it up as user-level
# hooks config — coexisting with the [otel] config.toml that render-config
# writes (Codex reads hooks.json and config.toml side by side under CODEX_HOME).
#
# The hook scripts are referenced by ABSOLUTE path (resolved from this
# component): `command` for POSIX hosts and `commandWindows` (pwsh) for Windows.
# hooks.json is written under .codex/, which is gitignored — it carries
# machine-specific absolute paths and the captured payloads it points at can
# contain prompt text.
#
# create-if-absent: an existing hooks.json is left untouched (delete to
# regenerate — e.g. after the repo moves and the absolute paths go stale).
#
# Usage: render-hooks.sh <target-dir>

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
HOOKS_DIR="$COMPONENT_DIR/hooks"
HOOK_SH="$HOOKS_DIR/capture-user-prompt.sh"
HOOK_PS1="$HOOKS_DIR/capture-user-prompt.ps1"

target=${1:-}
[ -n "$target" ] || { echo "usage: render-hooks.sh <target-dir>" >&2; exit 2; }

[ -f "$HOOK_SH" ]  || { echo "FAIL: hook not found: $HOOK_SH"  >&2; exit 1; }
[ -f "$HOOK_PS1" ] || { echo "FAIL: hook not found: $HOOK_PS1" >&2; exit 1; }

out="$target/.codex/hooks.json"
if [ -e "$out" ]; then
  echo "kept existing $out (delete to regenerate)"
  exit 0
fi

mkdir -p "$target/.codex"

# POSIX absolute paths carry no JSON-special characters, so a heredoc is safe.
cat > "$out" <<JSON
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
            "statusMessage": "capturing UserPromptSubmit payload (characterization)"
          }
        ]
      }
    ]
  }
}
JSON

echo "wrote $out"
