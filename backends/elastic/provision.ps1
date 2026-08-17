$ErrorActionPreference = 'Stop'

$ProjectDir = (Resolve-Path $PSScriptRoot).Path
$Group = 'elastic'
$Network = if ($env:ESPALIER_NETWORK) { $env:ESPALIER_NETWORK } else { 'aol-elastic_default' }
$Image = 'ghcr.io/hainet50b/espalier:v0.2.0'

docker run --rm --network $Network -v "${ProjectDir}:/project" $Image `
    apply --config /project/espalier.toml --target local --group $Group --yes
exit $LASTEXITCODE
