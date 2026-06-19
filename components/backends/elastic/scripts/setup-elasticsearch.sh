#!/usr/bin/env bash
#
# setup-elasticsearch.sh — apply the Elastic backend's Elasticsearch-side assets.
#
# Composition only: this backend owns no asset files. It selects the concern
# intrinsic to the `elastic` (full OTLP telemetry) backend — `shared` (the
# agent-agnostic @custom ingest routers) — plus the agent concern(s) the stack
# composes, and applies them through
# the elasticsearch service's concern importer. Only the composed agent's
# per-agent sub-pipelines are installed (per-stack minimal); the routers dispatch
# to them by service.name and ignore agents that aren't present. Each asset's
# rationale lives at its single source (the JSON body / SPEC), not here.
#
# ES_URL is inherited from the environment (the stack exports it); the appliers
# default it to http://localhost:9200. Run from anywhere — it locates the sibling
# elasticsearch service component.

set -euo pipefail

[ "$#" -ge 1 ] || {
  echo "usage: setup-elasticsearch.sh <agent-source>... (e.g. claude-code)" >&2
  exit 1
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ES_SCRIPTS="$COMPONENT_DIR/../services/elasticsearch/scripts"

# Intrinsic telemetry concern (`shared` @custom routers) plus the stack's agent
# concern(s): only the composed agent's per-agent sub-pipelines are installed; the
# routers dispatch to them by service.name and ignore the rest.
"$ES_SCRIPTS/import-elasticsearch-assets.sh" shared "$@"
