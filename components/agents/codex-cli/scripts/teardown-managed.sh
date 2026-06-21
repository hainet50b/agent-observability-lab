#!/usr/bin/env bash

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=/dev/null
. "$COMPONENT_DIR/../shared/managed-config/lib/managed-config-core.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/managed-config-adapter.sh"

mc_parse_args "$@"
mc_teardown
