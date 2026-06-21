#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

agent='codex-cli'

managed_config::managed_root() {
  case $1 in
  macos | linux) printf '%s' '/etc/codex' ;;
  *) managed_config::die "no Codex managed-config path for os '$1'" ;;
  esac
}

managed_config::manifest() {
  local os=$1 requirements_source=${2:-} managed_config_source=${3:-} root
  root=$(managed_config::managed_root "$os")
  # requirements.toml is the hook-enforcement layer — placed only when hooks are
  # deployed (--with-hooks). A telemetry-only managed deploy places managed_config.toml
  # alone (symmetric with Claude's env-only managed-settings.json).
  [ "$with_hooks" -eq 1 ] && printf '%s\t%s\t%s\n' 'requirements' "$requirements_source" "$root/requirements.toml"
  # managed_config.toml carries only telemetry defaults; with no telemetry it
  # would be just a comment, so place it only when telemetry is present.
  [ "$with_telemetry" -eq 1 ] && printf '%s\t%s\t%s\n' 'managed_config' "$managed_config_source" "$root/managed_config.toml"
  [ "$with_hooks" -eq 1 ] && managed_config::hook_manifest_lines "$root/hooks"
}
