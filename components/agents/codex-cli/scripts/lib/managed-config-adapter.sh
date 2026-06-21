#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

mc_agent='codex-cli'

mc_manifest() {
  local managed_target requirements_target
  case $1 in
  macos | linux)
    requirements_target='/etc/codex/requirements.toml'
    managed_target='/etc/codex/managed_config.toml'
    ;;
  *) mc_die "no Codex managed-config path for os '$1'" ;;
  esac
  printf '%s\t%s\t%s\n' 'requirements' "${mc_source_requirements:-}" "$requirements_target"
  printf '%s\t%s\t%s\n' 'managed_config' "${mc_source_managed_config:-}" "$managed_target"
}
