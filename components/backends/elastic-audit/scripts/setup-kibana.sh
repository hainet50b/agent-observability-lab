#!/usr/bin/env bash
#
# setup-kibana.sh — import the Elastic-audit backend's Kibana saved objects.
#
# Composition only: this backend owns no asset files. The Agent Audit views are
# intrinsic to this backend's identity — cross-agent (the AI agent is a document
# field, not a stream-name segment), so every audit stack wants exactly them. The
# source is therefore fixed here (`agent-audit`) and applied through the kibana
# service's generic importer. The stack calls this backend script rather than
# reaching into services/, keeping the component layering intact.
#
# KIBANA_URL is inherited from the environment (the stack exports it); the
# importer defaults it to http://localhost:5601. Run from anywhere — it locates
# the sibling kibana service component.

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
KIBANA_SCRIPTS="$COMPONENT_DIR/../services/kibana/scripts"

"$KIBANA_SCRIPTS/import-kibana-assets.sh" agent-audit
