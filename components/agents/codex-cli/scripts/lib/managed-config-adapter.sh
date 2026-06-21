#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

agent='codex-cli'

managed_config::manifest() {
  local os=$1 requirements_source=${2:-} managed_config_source=${3:-}
  local managed_target requirements_target
  case $os in
  macos | linux)
    requirements_target='/etc/codex/requirements.toml'
    managed_target='/etc/codex/managed_config.toml'
    ;;
  *) managed_config::die "no Codex managed-config path for os '$os'" ;;
  esac
  printf '%s\t%s\t%s\n' 'requirements' "$requirements_source" "$requirements_target"
  printf '%s\t%s\t%s\n' 'managed_config' "$managed_config_source" "$managed_target"
}
