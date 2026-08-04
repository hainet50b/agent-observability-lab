#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$BackendsDir = (Resolve-Path (Join-Path $PSScriptRoot '../../../components/backends')).Path
$Group = 'claude-elastic-audit'
$Network = 'claude-elastic-audit_default'
$Image = 'ghcr.io/hainet50b/espalier:v0.1.0'

docker run --rm --network $Network -v "${BackendsDir}:/project" $Image `
  apply --config /project/espalier.toml --target stack --group $Group --yes
exit $LASTEXITCODE
