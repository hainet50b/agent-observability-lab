#!/usr/bin/env bash
# shellcheck disable=SC2034

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(cd -- "$script_dir/.." && pwd)
# shellcheck source=/dev/null
. "$component_dir/../shared/managed-config/lib/managed-config-core.sh"
# shellcheck source=/dev/null
. "$script_dir/lib/managed-config-adapter.sh"

managed_config::parse_args "$@"
# Teardown enumerates every candidate target for removal; an absent one is a
# harmless no-op. Force telemetry targets in so a telemetry deploy's
# managed_config.toml is removed even though teardown carries no endpoints.
with_telemetry=1
managed_config::teardown
