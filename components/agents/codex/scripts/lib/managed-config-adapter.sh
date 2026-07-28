#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

agent='codex'

managed_config::managed_root() {
  case $1 in
  macos | linux) printf '%s' '/etc/codex' ;;
  windows) printf '%s' 'C:/ProgramData/OpenAI/Codex' ;;
  *) managed_config::die "no Codex managed-config path for os '$1'" ;;
  esac
}

managed_config::manifest() {
  local os=$1 requirements_source=${2:-} managed_config_source=${3:-} root managed_config_target
  root=$(managed_config::managed_root "$os")
  # Codex reads managed_config.toml from the user profile on Windows, so the
  # rendered bundle carries it under a USERPROFILE/ placeholder the MDM layer
  # must expand per user.
  if [ "$os" = windows ]; then
    managed_config_target='%USERPROFILE%/.codex/managed_config.toml'
  else
    managed_config_target="$root/managed_config.toml"
  fi
  # requirements.toml is the hook-enforcement layer — placed only when hooks are
  # deployed (--with-hooks). A telemetry-only managed deploy places managed_config.toml
  # alone (symmetric with Claude's env-only managed fragment).
  [ "$with_hooks" -eq 1 ] && printf '%s\t%s\t%s\n' 'requirements' "$requirements_source" "$root/requirements.toml"
  # managed_config.toml carries only telemetry defaults; with no telemetry it
  # would be just a comment, so place it only when telemetry is present.
  [ "$with_telemetry" -eq 1 ] && printf '%s\t%s\t%s\n' 'managed_config' "$managed_config_source" "$managed_config_target"
  [ "$with_hooks" -eq 1 ] && managed_config::hook_manifest_lines "$root/hooks" "$(managed_config::hook_flavor "$os")"
}
