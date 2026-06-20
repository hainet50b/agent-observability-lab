#!/usr/bin/env bash

# shellcheck source=/dev/null
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib/agent-audit.sh"

# shellcheck disable=SC2034  # consumed by the sourced library
stream=tool_call

require_config_arg "$@"
require_tools
load_delivery_config
require_stream_enabled
read_hook_payload
build_audit_document
deliver_document
