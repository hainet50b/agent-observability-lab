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

rendered_source=$(mktemp) || managed_config::die "could not create temp file"
trap 'rm -f "$rendered_source"' EXIT
sed \
  -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs_endpoint#" \
  -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces_endpoint#" \
  -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics_endpoint#" \
  "$template" >"$rendered_source" || managed_config::die "failed to render $template"

managed_config::place "$rendered_source"
