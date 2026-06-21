#!/usr/bin/env bash
# shellcheck disable=SC2154

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
# shellcheck source=/dev/null
. "$component_dir/../shared/managed-config/lib/managed-config-core.sh"
# shellcheck source=/dev/null
. "$script_dir/lib/managed-config-adapter.sh"

managed_config::parse_args "$@"
[ -n "$logs_endpoint" ] || managed_config::die "--logs-endpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/logs)"
[ -n "$traces_endpoint" ] || managed_config::die "--traces-endpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/traces)"
[ -n "$metrics_endpoint" ] || managed_config::die "--metrics-endpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/metrics)"

template="$component_dir/templates/managed-settings.template.json"
[ -f "$template" ] || managed_config::die "template not found: $template"
otel_template="$component_dir/templates/otel.template.json"
[ -f "$otel_template" ] || managed_config::die "template not found: $otel_template"

rendered_source=$(mktemp) || managed_config::die "could not create temp file"
trap 'rm -f "$rendered_source"; [ -n "$hooks_stage" ] && rm -rf "$hooks_stage"' EXIT
otel_env=$(sed \
  -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs_endpoint#" \
  -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces_endpoint#" \
  -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics_endpoint#" \
  -e "s#@@OTLP_HEADERS@@##" \
  "$otel_template" |
  jq '.env | if .OTEL_EXPORTER_OTLP_HEADERS == "" then del(.OTEL_EXPORTER_OTLP_HEADERS) else . end') ||
  managed_config::die "failed to render $otel_template"
jq --argjson env "$otel_env" '.env = $env' "$template" >"$rendered_source" ||
  managed_config::die "failed to render $template"

# Opt-in (staged, off by default): also enforce the audit hooks org-wide by
# materializing the hook bundle beside managed-settings.json and adding a hooks
# block that points at it. Requires a confirmed host check (see the stack README).
if [ "$with_hooks" -eq 1 ]; then
  [ -n "$es_url" ] || managed_config::die "--with-hooks requires --es-url (audit hooks need the ES endpoint)"
  managed_config::detect_os
  root=$(managed_config::managed_root "$os")
  entry_target="$root/hooks/agent-audit.sh"
  conf_target="$root/hooks/agent-audit.conf"
  managed_config::stage_hooks "$component_dir" "$es_url"
  hook_template="$component_dir/templates/hook.template.json"
  [ -f "$hook_template" ] || managed_config::die "hook template not found: $hook_template"
  hooks_json=$(jq \
    --arg up "$entry_target --stream user_prompt --config $conf_target" \
    --arg tc "$entry_target --stream tool_call --config $conf_target" \
    '.hooks.UserPromptSubmit[0].hooks[0].command = $up
     | .hooks.PostToolUse[0].hooks[0].command = $tc
     | .hooks' "$hook_template") || managed_config::die "could not build hooks block"
  tmp=$(mktemp) || managed_config::die "could not create temp file"
  jq --argjson h "$hooks_json" '.hooks = $h' "$rendered_source" >"$tmp" ||
    managed_config::die "could not inject hooks block into managed-settings.json"
  mv "$tmp" "$rendered_source"
fi

managed_config::place "$rendered_source"
