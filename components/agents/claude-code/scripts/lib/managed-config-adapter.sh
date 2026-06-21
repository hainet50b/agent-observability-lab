#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

agent='claude-code'

managed_config::managed_root() {
  case $1 in
  macos) printf '%s' '/Library/Application Support/ClaudeCode' ;;
  linux) printf '%s' '/etc/claude-code' ;;
  *) managed_config::die "no Claude managed-settings path for os '$1'" ;;
  esac
}

managed_config::manifest() {
  local os=$1 source=${2:-} root
  root=$(managed_config::managed_root "$os")
  printf '%s\t%s\t%s\n' 'managed-settings' "$source" "$root/managed-settings.json"
  [ "$with_hooks" -eq 1 ] && managed_config::hook_manifest_lines "$root/hooks"
}
