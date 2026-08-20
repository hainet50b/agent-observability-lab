#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

group=elastic
network=${ESPALIER_NETWORK:-aol-elastic_default}
image=ghcr.io/hainet50b/espalier:v0.3.0

if command -v cygpath >/dev/null 2>&1; then
  script_dir=$(cygpath -m "$script_dir")
  export MSYS_NO_PATHCONV=1
fi

exec docker run --rm --network "$network" -v "$script_dir:/project" "$image" \
  apply --config /project/espalier.toml --target local --group "$group" --yes
