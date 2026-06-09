#!/usr/bin/env bash
#
# setup-prompt-audit.sh — stack shim.
#
# The real implementation lives in the Elastic backend component:
#   ../../components/backends/elastic/scripts/setup-prompt-audit.sh
# This forwarder keeps the command the user is accustomed to
# (`scripts/setup-prompt-audit.sh` from the stack dir) working. `exec` so the
# real script's exit code and signals propagate identically; "$@" forwards args
# (e.g. ES_URL is read from the environment by the real script).
#
# The prompt-audit store talks straight to Elasticsearch, so it is identical in
# both stacks — the sidecar Collector relays OTLP only and is not on this path.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$SCRIPT_DIR/../../../components/backends/elastic/scripts/setup-prompt-audit.sh" "$@"
