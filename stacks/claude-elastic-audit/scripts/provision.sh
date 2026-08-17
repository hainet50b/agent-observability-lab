#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

ESPALIER_NETWORK=claude-elastic-audit_default exec "$script_dir/../../../backends/elastic/provision.sh"
