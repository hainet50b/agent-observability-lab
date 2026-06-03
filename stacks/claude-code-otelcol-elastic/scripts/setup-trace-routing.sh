#!/usr/bin/env bash
#
# setup-trace-routing.sh — stack shim.
#
# The real implementation lives in the Elastic backend component:
#   ../../components/backends/elastic/scripts/setup-trace-routing.sh
# This forwarder keeps the command the user is accustomed to
# (`scripts/setup-trace-routing.sh` from the stack dir) working. `exec` so the
# real script's exit code and signals propagate identically; "$@" forwards args
# (e.g. ES_URL is read from the environment by the real script).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$SCRIPT_DIR/../../../components/backends/elastic/scripts/setup-trace-routing.sh" "$@"
