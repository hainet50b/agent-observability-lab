#!/usr/bin/env bash
# shellcheck disable=SC2154

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=/dev/null
. "$COMPONENT_DIR/../shared/managed-config/lib/managed-config-core.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/managed-config-adapter.sh"

mc_parse_args "$@"
[ -n "$mc_logs_endpoint" ] || mc_die "--logs-endpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/logs)"
[ -n "$mc_traces_endpoint" ] || mc_die "--traces-endpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/traces)"
[ -n "$mc_metrics_endpoint" ] || mc_die "--metrics-endpoint is required (full OTLP URL, e.g. http://localhost:8200/v1/metrics)"

templates="$COMPONENT_DIR/templates"
managed_template="$templates/managed_config.template.toml"
requirements_template="$templates/requirements.template.toml"
for t in "$managed_template" "$requirements_template"; do
  [ -f "$t" ] || mc_die "template not found: $t"
done

hooks_dir="$COMPONENT_DIR/hooks"

mc_source_managed_config=$(mktemp) || mc_die "could not create temp file"
mc_source_requirements=$(mktemp) || mc_die "could not create temp file"
trap 'rm -f "$mc_source_managed_config" "$mc_source_requirements"' EXIT

sed \
  -e "s#@@OTLP_LOGS_ENDPOINT@@#$mc_logs_endpoint#" \
  -e "s#@@OTLP_TRACES_ENDPOINT@@#$mc_traces_endpoint#" \
  -e "s#@@OTLP_METRICS_ENDPOINT@@#$mc_metrics_endpoint#" \
  "$managed_template" >"$mc_source_managed_config" || mc_die "failed to render $managed_template"

sed \
  -e "s#@@MANAGED_DIR@@#$hooks_dir#" \
  -e "s#@@WINDOWS_MANAGED_DIR@@#$hooks_dir#" \
  -e "s#@@AGENT_AUDIT_SH@@#$hooks_dir/agent-audit.sh#" \
  -e "s#@@AGENT_AUDIT_PS1@@#$hooks_dir/agent-audit.ps1#" \
  -e "s#@@AGENT_AUDIT_CONF@@#$hooks_dir/agent-audit.conf#" \
  "$requirements_template" >"$mc_source_requirements" || mc_die "failed to render $requirements_template"

mc_place "$mc_source_requirements" "$mc_source_managed_config"
