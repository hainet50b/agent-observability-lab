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

templates="$component_dir/templates"
managed_template="$templates/managed_config.template.toml"
requirements_template="$templates/requirements.template.toml"
for t in "$managed_template" "$requirements_template"; do
  [ -f "$t" ] || managed_config::die "template not found: $t"
done

hooks_dir="$component_dir/hooks"

managed_config_source=$(mktemp) || managed_config::die "could not create temp file"
requirements_source=$(mktemp) || managed_config::die "could not create temp file"
trap 'rm -f "$managed_config_source" "$requirements_source"' EXIT

sed \
  -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs_endpoint#" \
  -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces_endpoint#" \
  -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics_endpoint#" \
  "$managed_template" >"$managed_config_source" || managed_config::die "failed to render $managed_template"

sed \
  -e "s#@@MANAGED_DIR@@#$hooks_dir#" \
  -e "s#@@WINDOWS_MANAGED_DIR@@#$hooks_dir#" \
  -e "s#@@AGENT_AUDIT_SH@@#$hooks_dir/agent-audit.sh#" \
  -e "s#@@AGENT_AUDIT_PS1@@#$hooks_dir/agent-audit.ps1#" \
  -e "s#@@AGENT_AUDIT_CONF@@#$hooks_dir/agent-audit.conf#" \
  "$requirements_template" >"$requirements_source" || managed_config::die "failed to render $requirements_template"

managed_config::place "$requirements_source" "$managed_config_source"
