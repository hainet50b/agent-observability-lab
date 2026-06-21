#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

mc_agent='claude-code'

mc_manifest() {
  local os=$1 source=${2:-} target
  case $os in
  macos) target='/Library/Application Support/ClaudeCode/managed-settings.json' ;;
  linux) target='/etc/claude-code/managed-settings.json' ;;
  *) mc_die "no Claude managed-settings path for os '$os'" ;;
  esac
  printf '%s\t%s\t%s\n' 'managed-settings' "$source" "$target"
}
