#!/usr/bin/env pwsh
# .ralph/gate.ps1 — the repo's pass gate. A PRD task is checked off only
# after this exits 0, and every run integration re-runs it. Executable form
# of CONVENTIONS.md's "Lint / Format / Test Commands" — keep the two from
# drifting apart, and keep gate.sh behaviorally identical.
#
# The Rust and Docker-smoke checks are scoped exactly as CONVENTIONS.md
# already documents them: "required whenever agent-config/ changed" /
# "whenever backends/elastic/ changed". Scope is decided against this run's
# upstream (set by ralph.ps1); with no upstream to diff against, run them.
$ErrorActionPreference = 'Stop'

Set-Location (git rev-parse --show-toplevel)

function Test-Changed([string]$Path) {
    $upstream = git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $true }
    git diff --quiet "$upstream...HEAD" -- $Path
    return ($LASTEXITCODE -ne 0)
}

function Invoke-Checked([string]$Description, [scriptblock]$Action) {
    Write-Output "-- $Description --"
    & $Action
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-Checked 'compose validate' {
    Get-ChildItem backends/*/docker-compose.yml | ForEach-Object {
        docker compose -f $_.FullName config -q
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}

if (Test-Changed 'agent-config/') {
    Invoke-Checked 'rust fmt/clippy/test (agent-config/)' {
        cargo fmt --manifest-path agent-config/Cargo.toml --check
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        cargo clippy --manifest-path agent-config/Cargo.toml --all-targets
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        cargo test --manifest-path agent-config/Cargo.toml
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}

if (Get-Module -ListAvailable PSScriptAnalyzer) {
    Invoke-Checked 'shell lint' {
        $settings = 'PSScriptAnalyzerSettings.psd1'
        Get-ChildItem -Recurse backends, agents -Filter *.ps1 | Where-Object { $_.Name -ne 'provision-standalone.ps1' } | ForEach-Object {
            $original = Get-Content -Raw $_.FullName
            $formatted = Invoke-Formatter -Settings $settings -ScriptDefinition $original
            if ($formatted -ne $original) {
                Write-Error "not formatted: $($_.FullName) (run Invoke-Formatter to fix)"
                exit 1
            }
            $findings = Invoke-ScriptAnalyzer -Settings $settings -Path $_.FullName
            if ($findings) {
                $findings | Format-Table | Out-String | Write-Output
                exit 1
            }
        }
    }
}

if (Test-Changed 'backends/elastic/') {
    Invoke-Checked 'backend smoke test (backends/elastic/)' {
        bash backends/elastic/smoke-test.sh
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}

exit 0
