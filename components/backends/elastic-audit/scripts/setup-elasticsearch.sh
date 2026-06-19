#!/usr/bin/env bash
set -euo pipefail

: "${ES_URL:?must be set by the stack}"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
backend_dir=$(cd -- "$script_dir/.." && pwd)
es_scripts="$backend_dir/../services/elasticsearch/scripts"

"$es_scripts/import-elasticsearch-assets.sh" agent-audit
