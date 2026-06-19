#!/usr/bin/env bash
#
# setup-kibana.sh — import the Elastic backend's Kibana saved objects.
#
# Composition only: this backend owns no asset files. The telemetry backend's
# Kibana views are per-agent, so the SOURCE selection is the stack's to make — it
# passes the source namespace(s) for the agent(s) it composes, which this script
# forwards to the kibana service's generic importer. Routing the call through the
# backend (rather than letting the stack reach into services/) keeps the
# component layering intact: a stack composes backends, never their service
# fragments directly.
#
# KIBANA_URL is inherited from the environment (the stack exports it); the
# importer defaults it to http://localhost:5601. Run from anywhere — it locates
# the sibling kibana service component.

set -euo pipefail

[ "$#" -ge 1 ] || {
  echo "usage: setup-kibana.sh <source>... (e.g. claude-code)" >&2
  exit 1
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
KIBANA_SCRIPTS="$COMPONENT_DIR/../services/kibana/scripts"

"$KIBANA_SCRIPTS/import-kibana-objects.sh" "$@"
