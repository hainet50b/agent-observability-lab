#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
backends_dir=$(cd -- "$script_dir/../../../components/backends" && pwd)

group=claude-elastic-audit
network=claude-elastic-audit_default
image=ghcr.io/hainet50b/espalier:v0.1.0

if command -v cygpath >/dev/null 2>&1; then
  backends_dir=$(cygpath -m "$backends_dir")
  export MSYS_NO_PATHCONV=1
fi

exec docker run --rm --network "$network" -v "$backends_dir:/project" "$image"   apply --config /project/espalier.toml --target stack --group "$group" --yes
