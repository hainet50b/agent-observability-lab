#!/usr/bin/env bash
#
# import-kibana-objects.sh — stack shim.
#
# The real implementation lives in the Elastic backend component:
#   ../../components/backends/elastic/scripts/import-kibana-objects.sh
# This forwarder keeps the command the user is accustomed to
# (`scripts/import-kibana-objects.sh` from the stack dir) working. `exec` so the
# real script's exit code and signals propagate identically; "$@" forwards args
# (e.g. KIBANA_URL is read from the environment by the real script).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$SCRIPT_DIR/../../../components/backends/elastic/scripts/import-kibana-objects.sh" "$@"
