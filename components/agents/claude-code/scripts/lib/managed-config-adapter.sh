#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

agent='claude-code'

managed_config::manifest() {
  local os=$1 source=${2:-} target
  case $os in
  macos) target='/Library/Application Support/ClaudeCode/managed-settings.json' ;;
  linux) target='/etc/claude-code/managed-settings.json' ;;
  *) managed_config::die "no Claude managed-settings path for os '$os'" ;;
  esac
  printf '%s\t%s\t%s\n' 'managed-settings' "$source" "$target"
}
