#!/usr/bin/env bash
#
# setup-elasticsearch.sh — apply the Elastic-audit backend's Elasticsearch assets.
#
# Composition only: this backend owns no asset files. It selects the assets
# intrinsic to the `elastic-audit` backend's identity — the two Agent Audit
# data-stream templates (logs-agent_audit.user_prompt / .tool_call) the hooks write
# to — and applies them through the elasticsearch service's generic index-template
# applier. The applier installs each template, creates its <name>-default data
# stream, and syncs the strict mapping. Rationale lives at its single source
# (the template JSON / SPEC/agent-audit.md), not here.
#
# ES_URL is inherited from the environment (the stack exports it); the appliers
# default it to http://localhost:9200. Run from anywhere — it locates the sibling
# elasticsearch service component.

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ES_SCRIPTS="$COMPONENT_DIR/../services/elasticsearch/scripts"

"$ES_SCRIPTS/import-index-templates.sh" logs-agent_audit.user_prompt logs-agent_audit.tool_call
