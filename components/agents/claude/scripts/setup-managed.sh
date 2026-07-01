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

template="$component_dir/templates/managed-settings.template.json"
[ -f "$template" ] || managed_config::die "template not found: $template"

rendered_source=$(mktemp) || managed_config::die "could not create temp file"
trap 'rm -f "$rendered_source"; [ -n "$hooks_stage" ] && rm -rf "$hooks_stage"' EXIT

# Telemetry is optional: render the env block only when the OTLP endpoints are
# present. Without them the managed-settings.json carries no env (just _comment,
# plus hooks if --with-hooks) — an audit-only managed deploy.
if [ "$with_telemetry" -eq 1 ]; then
  otel_template="$component_dir/templates/otel.template.json"
  [ -f "$otel_template" ] || managed_config::die "template not found: $otel_template"
  otlp_headers=""
  [ -n "$otlp_api_key" ] && otlp_headers="Authorization=ApiKey $otlp_api_key"
  otel_env=$(sed \
    -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs_endpoint#" \
    -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces_endpoint#" \
    -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics_endpoint#" \
    -e "s#@@OTLP_HEADERS@@#$otlp_headers#" \
    "$otel_template" |
    jq '.env | if .OTEL_EXPORTER_OTLP_HEADERS == "" then del(.OTEL_EXPORTER_OTLP_HEADERS) else . end') ||
    managed_config::die "failed to render $otel_template"
  jq --argjson env "$otel_env" '.env = $env' "$template" >"$rendered_source" ||
    managed_config::die "failed to render $template"
else
  cp "$template" "$rendered_source" || managed_config::die "failed to stage $template"
fi

# Opt-in (staged, off by default): also enforce the audit hooks org-wide by
# materializing the hook bundle beside managed-settings.json and adding a hooks
# block that points at it. Requires a confirmed host check (see the stack README).
if [ "$with_hooks" -eq 1 ]; then
  [ -n "$es_url" ] || managed_config::die "--with-hooks requires --es-url (audit hooks need the ES endpoint)"
  managed_config::detect_os
  root=$(managed_config::managed_root "$os")
  entry_target="$root/hooks/agent-audit.sh"
  conf_target="$root/hooks/agent-audit.conf"
  cert_target="$root/hooks/recipient.pem"
  managed_config::stage_hooks "$component_dir" "$es_url" "$es_api_key" \
    "$timeout_ms" "$capture_user_prompt_enabled" "$capture_user_prompt_content" \
    "$capture_tool_call_enabled" "$capture_tool_call_content" \
    "$seal_recipients_src" "$seal_key_id" "$cert_target"
  hook_template="$component_dir/templates/hook.template.json"
  [ -f "$hook_template" ] || managed_config::die "hook template not found: $hook_template"
  hooks_json=$(jq \
    --arg up "'$entry_target' --stream user_prompt --config '$conf_target'" \
    --arg tc "'$entry_target' --stream tool_call --config '$conf_target'" \
    '.hooks.UserPromptSubmit[0].hooks[0].command = $up
     | .hooks.PostToolUse[0].hooks[0].command = $tc
     | .hooks' "$hook_template") || managed_config::die "could not build hooks block"
  tmp=$(mktemp) || managed_config::die "could not create temp file"
  jq --argjson h "$hooks_json" '.hooks = $h' "$rendered_source" >"$tmp" ||
    managed_config::die "could not inject hooks block into managed-settings.json"
  mv "$tmp" "$rendered_source"
fi

# shellcheck disable=SC2034  # read by managed_config::place across the source=/dev/null boundary
marker_endpoint="telemetry=$logs_endpoint;audit=$es_url"
managed_config::place "$rendered_source"
