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

# Default: requirements point at the in-repo component hooks (demo). Opt-in
# (staged, off by default): materialize the hook bundle into the host managed_dir
# and point the managed config there. Requires a confirmed host check (stack README).
hooks_ref="$component_dir/hooks"
if [ "$with_hooks" -eq 1 ]; then
  [ -n "$es_url" ] || managed_config::die "--with-hooks requires --es-url (audit hooks need the ES endpoint)"
  managed_config::detect_os
  hooks_ref="$(managed_config::managed_root "$os")/hooks"
  managed_config::stage_hooks "$component_dir" "$es_url" "$es_api_key"
fi

managed_config_source=$(mktemp) || managed_config::die "could not create temp file"
requirements_source=$(mktemp) || managed_config::die "could not create temp file"
trap 'rm -f "$managed_config_source" "$requirements_source"; [ -n "$hooks_stage" ] && rm -rf "$hooks_stage"' EXIT

# Telemetry is optional: render managed_config.toml ([otel] defaults) only when the
# OTLP endpoints are present. With no telemetry the file would be just a comment, so
# it is not placed (the adapter omits it) — place only requirements.toml.
if [ "$with_telemetry" -eq 1 ]; then
  managed_template="$templates/managed_config.template.toml"
  otel_template="$templates/otel.template.toml"
  for t in "$managed_template" "$otel_template"; do
    [ -f "$t" ] || managed_config::die "template not found: $t"
  done
  {
    cat "$managed_template"
    printf '\n'
    sed \
      -e "s#@@OTLP_LOGS_ENDPOINT@@#$logs_endpoint#" \
      -e "s#@@OTLP_TRACES_ENDPOINT@@#$traces_endpoint#" \
      -e "s#@@OTLP_METRICS_ENDPOINT@@#$metrics_endpoint#" \
      -e "s#@@OTLP_HEADERS@@##" \
      "$otel_template" | sed -n '/^\[otel\]/,$p'
  } >"$managed_config_source" || managed_config::die "failed to render $managed_template"
else
  # Audit-only deploy has no logs endpoint; key the marker/ownership on the audit
  # ES url instead so place()/teardown() and the provenance marker are meaningful.
  logs_endpoint=$es_url
fi

sed \
  -e "s#@@MANAGED_DIR@@#$hooks_ref#" \
  -e "s#@@WINDOWS_MANAGED_DIR@@#$hooks_ref#" \
  "$requirements_template" >"$requirements_source" || managed_config::die "failed to render $requirements_template"

printf '\n' >>"$requirements_source"

sed \
  -e "s#@@AGENT_AUDIT_SH@@#$hooks_ref/agent-audit.sh#" \
  -e "s#@@AGENT_AUDIT_PS1@@#$hooks_ref/agent-audit.ps1#" \
  -e "s#@@AGENT_AUDIT_CONF@@#$hooks_ref/agent-audit.conf#" \
  "$hooks_template" >>"$requirements_source" || managed_config::die "failed to render $hooks_template"

managed_config::place "$requirements_source" "$managed_config_source"
