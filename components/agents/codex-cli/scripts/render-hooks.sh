#!/usr/bin/env bash
set -euo pipefail

target_dir=${1:-}

[ -n "$target_dir" ] || {
  echo "Usage: render-hooks.sh <target-dir>" >&2
  exit 2
}

config="$target_dir/.codex/config.toml"

if [ -e "$config" ] && grep -qF '[[hooks.UserPromptSubmit]]' "$config"; then
  echo "Skipped: $config already has [[hooks.UserPromptSubmit]]"
  exit 0
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
hooks_dir="$component_dir/hooks"
user_prompt_sh="$hooks_dir/capture-user-prompt.sh"
user_prompt_ps1="$hooks_dir/capture-user-prompt.ps1"
tool_call_sh="$hooks_dir/capture-tool-call.sh"
tool_call_ps1="$hooks_dir/capture-tool-call.ps1"
template="$component_dir/hooks.template.toml"

for hook in "$user_prompt_sh" "$user_prompt_ps1" "$tool_call_sh" "$tool_call_ps1"; do
  [ -f "$hook" ] || {
    echo "FAIL: hook not found: $hook" >&2
    exit 1
  }
done
[ -f "$template" ] || {
  echo "FAIL: template not found: $template" >&2
  exit 1
}

block=$(sed \
  -e "s#@@USER_PROMPT_SH@@#$user_prompt_sh#" \
  -e "s#@@USER_PROMPT_PS1@@#$user_prompt_ps1#" \
  -e "s#@@TOOL_CALL_SH@@#$tool_call_sh#" \
  -e "s#@@TOOL_CALL_PS1@@#$tool_call_ps1#" \
  "$template")

mkdir -p "$target_dir/.codex"
[ -e "$config" ] && printf '\n' >>"$config"
printf '%s\n' "$block" >>"$config"
