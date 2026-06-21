#!/usr/bin/env bash
# shellcheck disable=SC2154

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=/dev/null
. "$COMPONENT_DIR/../shared/managed-config/lib/managed-config-core.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/managed-config-adapter.sh"

mc_parse_args "$@"
[ -n "$mc_endpoint" ] || mc_die "--endpoint <otlp-base> is required (e.g. http://localhost:8200)"

template="$COMPONENT_DIR/templates/managed-settings.template.json"
[ -f "$template" ] || mc_die "template not found: $template"

mc_source=$(mktemp) || mc_die "could not create temp file"
trap 'rm -f "$mc_source"' EXIT
sed \
  -e "s#@@OTLP_LOGS_ENDPOINT@@#$mc_endpoint/v1/logs#" \
  -e "s#@@OTLP_TRACES_ENDPOINT@@#$mc_endpoint/v1/traces#" \
  -e "s#@@OTLP_METRICS_ENDPOINT@@#$mc_endpoint/v1/metrics#" \
  -e "s#@@OTLP_HEADERS@@##" \
  "$template" >"$mc_source" || mc_die "failed to render $template"

mc_place
