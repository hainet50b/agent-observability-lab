[CmdletBinding()]
param(
    [string]$EsUrl = $(if ($env:ES_URL) { $env:ES_URL } else { 'http://localhost:9200' }),
    [Parameter(Mandatory = $true)]
    [string[]]$Concerns
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$ComponentDir = Split-Path -Parent $ScriptDir

function Invoke-Ilm($Name, $File) {
    $Body = Get-Content -Raw -LiteralPath $File
    Write-Host "[apply] ILM policy '$Name' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put `
            -Uri "$EsUrl/_ilm/policy/$([uri]::EscapeDataString($Name))" `
            -ContentType 'application/json' -Body $Body
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: ILM policy PUT not acknowledged"; exit 1 }
    Write-Host "[apply] ILM policy '$Name' installed"
}

function Invoke-ComponentTemplate($Name, $File) {
    $Body = Get-Content -Raw -LiteralPath $File
    Write-Host "[apply] component template '$Name' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put `
            -Uri "$EsUrl/_component_template/$([uri]::EscapeDataString($Name))" `
            -ContentType 'application/json' -Body $Body
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: component template PUT not acknowledged"; exit 1 }
    Write-Host "[apply] component template '$Name' installed"
}

function Invoke-Pipeline($Name, $File) {
    $Body = Get-Content -Raw -LiteralPath $File
    Write-Host "[apply] ingest pipeline '$Name' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put `
            -Uri "$EsUrl/_ingest/pipeline/$([uri]::EscapeDataString($Name))" `
            -ContentType 'application/json' -Body $Body
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: pipeline PUT not acknowledged"; exit 1 }
    Write-Host "[apply] ingest pipeline '$Name' installed"
}

function Invoke-Template($Template, $TemplateFile) {
    $DataStream = "$Template-default"
    $Body = Get-Content -Raw -LiteralPath $TemplateFile

    Write-Host "[apply] installing index template '$Template' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_index_template/$Template" `
            -ContentType 'application/json' -Body $Body
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: index template PUT not acknowledged"; exit 1 }
    Write-Host "[apply] index template '$Template' installed"

    $exists = $false
    try {
        Invoke-RestMethod -Method Get -Uri "$EsUrl/_data_stream/$DataStream" | Out-Null
        $exists = $true
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1
        }
    }
    if ($exists) {
        Write-Host "[apply] data stream '$DataStream' already exists — leaving as-is"
    }
    else {
        Write-Host "[apply] creating data stream '$DataStream' on $EsUrl…"
        try { $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_data_stream/$DataStream" }
        catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
        $result | ConvertTo-Json -Depth 10 | Write-Host
        if (-not $result.acknowledged) { Write-Error "FAIL: data stream create not acknowledged"; exit 1 }
        Write-Host "[apply] data stream '$DataStream' created"
    }

    Write-Host "[apply] syncing mapping onto data stream '$DataStream'…"
    try {
        $simulated = Invoke-RestMethod -Method Post -Uri "$EsUrl/_index_template/_simulate_index/$DataStream"
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    if (-not $simulated.template.mappings) { Write-Error "FAIL: resolved composed mapping for $Template has no template.mappings"; exit 1 }
    $mappings = ($simulated.template.mappings | ConvertTo-Json -Depth 20)
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/$DataStream/_mapping" `
            -ContentType 'application/json' -Body $mappings
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: data stream mapping update not acknowledged"; exit 1 }
    Write-Host "[apply] mapping synced onto '$DataStream'"
}

function Invoke-IndexTemplatePut($Name, $File) {
    $Body = Get-Content -Raw -LiteralPath $File
    Write-Host "[apply] index template (overlay) '$Name' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/_index_template/$Name" `
            -ContentType 'application/json' -Body $Body
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: index template PUT not acknowledged"; exit 1 }
    Write-Host "[apply] index template (overlay) '$Name' installed"
}

function Invoke-Index($Name, $File) {
    $exists = $false
    try {
        Invoke-RestMethod -Method Get -Uri "$EsUrl/$Name" | Out-Null
        $exists = $true
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1
        }
    }
    if ($exists) {
        Write-Host "[apply] index '$Name' already exists — leaving as-is"
        return
    }
    $Body = Get-Content -Raw -LiteralPath $File
    Write-Host "[apply] creating index '$Name' on $EsUrl…"
    try {
        $result = Invoke-RestMethod -Method Put -Uri "$EsUrl/$Name" `
            -ContentType 'application/json' -Body $Body
    }
    catch { Write-Error "FAIL: request to Elasticsearch failed ($_)"; exit 1 }
    $result | ConvertTo-Json -Depth 10 | Write-Host
    if (-not $result.acknowledged) { Write-Error "FAIL: index create not acknowledged"; exit 1 }
    Write-Host "[apply] index '$Name' created"
}

# ilm → component → pipelines → templates → index-templates → indices, so composed/referenced objects exist first
function Import-Concern($Concern) {
    $dir = Join-Path $ComponentDir $Concern
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Error "FAIL: concern dir not found: $dir"; exit 1
    }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.ilm.json' -File) {
        Invoke-Ilm ($f.Name -replace '\.ilm\.json$', '') $f.FullName
    }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.component.json' -File) {
        Invoke-ComponentTemplate ($f.Name -replace '\.component\.json$', '') $f.FullName
    }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.pipeline.json' -File) {
        Invoke-Pipeline ($f.Name -replace '\.pipeline\.json$', '') $f.FullName
    }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.template.json' -File | Where-Object { $_.Name -notlike '*.index-template.json' }) {
        Invoke-Template ($f.Name -replace '\.template\.json$', '') $f.FullName
    }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.index-template.json' -File) {
        Invoke-IndexTemplatePut ($f.Name -replace '\.index-template\.json$', '') $f.FullName
    }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.index.json' -File) {
        Invoke-Index ($f.Name -replace '\.index\.json$', '') $f.FullName
    }
}

Write-Host "[import] applying Elasticsearch assets to $EsUrl…"
foreach ($concern in $Concerns) {
    Write-Host ''
    Write-Host "[import] concern: $concern"
    Import-Concern $concern
}

Write-Host ''
Write-Host "PASS: Elasticsearch assets applied on $EsUrl`: $($Concerns -join ', ')."



