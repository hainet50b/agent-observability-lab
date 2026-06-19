#!/usr/bin/env bash
#
# setup-elasticsearch.sh — apply the Elastic-audit backend's Elasticsearch assets.
#
# Composition only: this backend owns no asset files. The Agent Audit data-stream
# templates (logs-agent_audit.user_prompt / .tool_call the hooks write to) are
# intrinsic to this backend's identity, so the `agent-audit` concern is fixed here
# and applied through the elasticsearch service's concern importer (which installs
# each template, creates its <name>-default data stream, and syncs the strict
# mapping). Rationale lives at its single source (the template JSON /
# SPEC/agent-audit.md), not here.
#
# ES_URL is inherited from the environment (the stack exports it); the appliers
# default it to http://localhost:9200. Run from anywhere — it locates the sibling
# elasticsearch service component.

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ES_SCRIPTS="$COMPONENT_DIR/../services/elasticsearch/scripts"

"$ES_SCRIPTS/import-elasticsearch-assets.sh" agent-audit
