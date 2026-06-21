#!/usr/bin/env bash
# shellcheck disable=SC2154

hook_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
core="$hook_dir/lib/agent-audit-core.sh"
[ -f "$core" ] || core="$hook_dir/../../shared/agent-audit/lib/agent-audit-core.sh"
# shellcheck source=/dev/null
. "$core"
# shellcheck source=/dev/null
. "$hook_dir/lib/adapter.sh"

parse_args "$@"
require_stream "$stream"
require_config
require_tools
load_delivery_config "$stream"
require_stream_enabled "$stream"
read_hook_payload "$stream"
build_audit_document "$stream"
deliver_document
