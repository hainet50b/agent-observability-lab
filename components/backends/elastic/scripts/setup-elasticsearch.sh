#!/usr/bin/env bash
#
# setup-elasticsearch.sh — apply the Elastic backend's Elasticsearch-side assets.
#
# Composition only: this backend owns no asset files. It selects the assets
# intrinsic to the `elastic` (full OTLP telemetry) backend's identity and applies
# them through the elasticsearch service's generic appliers:
#   - ingest pipelines  traces-apm@custom (per-agent trace routing + Codex span
#                       drop) and logs-apm.app@custom (Codex streaming-delta drop +
#                       I/O redaction) — both service-gated, so harmless to whichever
#                       agent isn't running.
#   - index             prompts-audit (agent-agnostic prompt-capture audit store).
# Each asset's rationale lives at its single source (the JSON body / SPEC), not here.
#
# ES_URL is inherited from the environment (the stack exports it); the appliers
# default it to http://localhost:9200. Run from anywhere — it locates the sibling
# elasticsearch service component.

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ES_SCRIPTS="$COMPONENT_DIR/../services/elasticsearch/scripts"

"$ES_SCRIPTS/import-ingest-pipelines.sh" traces-apm@custom logs-apm.app@custom
"$ES_SCRIPTS/import-indices.sh" prompts-audit
