#!/usr/bin/env bash
# shellcheck disable=SC2154

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
# shellcheck source=/dev/null
. "$component_dir/../shared/managed-config/lib/managed-config-core.sh"
# shellcheck source=/dev/null
. "$script_dir/lib/managed-config-adapter.sh"

managed_config::parse_args "$@"

with_telemetry=0
if [ -n "$logs_endpoint" ] || [ -n "$traces_endpoint" ] || [ -n "$metrics_endpoint" ]; then
  [ -n "$logs_endpoint" ] || managed_config::die "--logs-endpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/logs)"
  [ -n "$traces_endpoint" ] || managed_config::die "--traces-endpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/traces)"
  [ -n "$metrics_endpoint" ] || managed_config::die "--metrics-endpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/metrics)"
  with_telemetry=1
fi
[ "$with_telemetry" -eq 1 ] || [ "$with_hooks" -eq 1 ] ||
  managed_config::die "nothing to place (need OTLP endpoints and/or --with-hooks)"

templates="$component_dir/templates"
requirements_template="$templates/requirements.template.toml"
hooks_template="$templates/hooks.template.toml"
for t in "$requirements_template" "$hooks_template"; do
  [ -f "$t" ] || managed_config::die "template not found: $t"
done

managed_config_source=$(mktemp) || managed_config::die "could not create temp file"
requirements_source=$(mktemp) || managed_config::die "could not create temp file"
trap 'rm -f "$managed_config_source" "$requirements_source"; [ -n "$hooks_stage" ] && rm -rf "$hooks_stage"' EXIT

# Telemetry -> managed_config.toml ([otel] defaults), only when the OTLP endpoints are
# present (the adapter places it only then).
if [ "$with_telemetry" -eq 1 ]; then
  managed_template="$templates/managed_config.template.toml"
  otel_template="$templates/otel.template.toml"
  for t in "$managed_template" "$otel_template"; do
    [ -f "$t" ] || managed_config::die "template not found: $t"
  done
  otlp_headers=""
  [ -n "$otlp_api_key" ] && otlp_headers=" Authorization = \"ApiKey $otlp_api_key\" "
  {
    cat "$managed_template"
    printf '\n'
    sed \
      -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs_endpoint#" \
      -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces_endpoint#" \
      -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics_endpoint#" \
      -e "s#@@OTLP_HEADERS@@#$otlp_headers#" \
      "$otel_template" | sed -n '/^\[otel\]/,$p'
  } >"$managed_config_source" || managed_config::die "failed to render $managed_template"
fi

[ "$with_hooks" -ne 1 ] || [ -n "$es_url" ] ||
  managed_config::die "--with-hooks requires --es-url (audit hooks need the ES endpoint)"

# Hooks -> requirements.toml (the hook-enforcement layer), with the hook bundle
# materialized into the host managed_dir. Without --with-hooks there is no enforcement
# layer to place: a telemetry-only managed deploy is managed_config.toml alone (symmetric
# with Claude's env-only managed fragment).
# Codex picks managed_dir on non-Windows and windows_managed_dir on Windows, with no
# fallback (hook_config.rs: managed_dir_for_current_platform), so requirements.toml
# keeps only the key for the target OS.
render_for_os() {
  local target_os=$1 flavor hooks_ref hooks_dir sep requirements hooks
  : >"$requirements_source"
  [ "$with_hooks" -eq 1 ] || return 0
  flavor=$(managed_config::hook_flavor "$target_os")
  hooks_ref="$(managed_config::managed_root "$target_os")/hooks/$tool"
  managed_config::stage_hooks "$component_dir" "$es_url" "$es_api_key" \
    "$timeout_ms" "$capture_user_prompt_enabled" "$capture_user_prompt_content" \
    "$capture_tool_call_enabled" "$capture_tool_call_content" \
    "$seal_recipients_src" "$seal_key_id" "$hooks_ref/recipient.pem" "$flavor"
  if [ "$target_os" = windows ]; then
    hooks_dir=${hooks_ref//\//\\}
    sep="\\"
    requirements=$(sed '/^managed_dir = /d' "$requirements_template") ||
      managed_config::die "failed to render $requirements_template"
    requirements=${requirements//@@WINDOWS_MANAGED_DIR@@/"$hooks_dir"}
  else
    hooks_dir=$hooks_ref
    sep='/'
    requirements=$(sed '/^windows_managed_dir = /d' "$requirements_template") ||
      managed_config::die "failed to render $requirements_template"
    requirements=${requirements//@@MANAGED_DIR@@/"$hooks_dir"}
  fi
  hooks=$(cat "$hooks_template") || managed_config::die "failed to render $hooks_template"
  hooks=${hooks//@@AGENT_AUDIT_SH@@/"$hooks_dir${sep}agent-audit.sh"}
  hooks=${hooks//@@AGENT_AUDIT_PS1@@/"$hooks_dir${sep}agent-audit.ps1"}
  hooks=${hooks//@@AGENT_AUDIT_CONF@@/"$hooks_dir${sep}agent-audit.conf"}
  printf '%s\n\n%s\n' "$requirements" "$hooks" >"$requirements_source"
}

# shellcheck disable=SC2034  # read by managed_config::place across the source=/dev/null boundary
marker_endpoint="telemetry=$logs_endpoint;audit=$es_url"
if [ -n "$render_dir" ]; then
  for render_os in $(managed_config::render_os_list); do
    render_for_os "$render_os"
    managed_config::render "$render_os" "$requirements_source" "$managed_config_source"
  done
else
  managed_config::detect_os
  render_for_os "$os"
  managed_config::place "$requirements_source" "$managed_config_source"
fi
