param(
    [Parameter(Position=0)]
    [ValidateSet('scan', 'docs', 'fifo-inference', 'faults', 'sim', 'synth', 'pnr', 'report', 'formal', 'release-check', 'package')]
    [string]$Command = 'scan',
    [ValidateSet('tang25k', 'tang20k')]
    [string]$Board = 'tang25k',
    [ValidateSet(1, 2, 4, 8, 16)]
    [int]$AdcCount = 1,
    [switch]$Full,
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 300,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$root = [string]$env:SIPEED_TANG20K_ROOT
$project = Join-Path $root 'cores\acquisition\ads131m08'
$reportDir = Join-Path $root 'docs\quality\reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Invoke-Child([string]$Path, [string[]]$Arguments) {
    & $Path @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Harness child command failed ($LASTEXITCODE): $Path $($Arguments -join ' ')" }
}

function Get-ToolVersion([string]$Tool) {
    $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
    if (-not $cmd) { return @{ available = $false; version = $null } }
    $versionArgs = @('--version')
    if ($Tool -in @('iverilog', 'vvp')) { $versionArgs = @('-V') }
    if ($Tool -in @('powershell', 'pwsh')) { $versionArgs = @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()') }
    $text = (& $Tool @versionArgs 2>&1 | Select-Object -First 1) -join ' '
    return @{ available = $true; path = $cmd.Source; version = $text }
}

switch ($Command) {
    'scan' {
        & (Join-Path $PSScriptRoot 'lint_ads131m08.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 lint failed ($LASTEXITCODE)" }
        & (Join-Path $PSScriptRoot 'check_ads131m08_docs.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 documentation audit failed ($LASTEXITCODE)" }
        $tools = [ordered]@{}
        foreach ($tool in @('iverilog', 'vvp', 'yosys', 'nextpnr-himbaechel', 'sby', 'boolector', 'python', 'powershell', 'pwsh', 'git')) { $tools[$tool] = Get-ToolVersion $tool }
        $result = [ordered]@{ schema = 'ads131m08-harness-scan-v1'; generated = (Get-Date).ToUniversalTime().ToString('o'); root = $root; tools = $tools; board_evidence = 'DEFERRED' }
        $result | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $reportDir 'scan.json')
        $result | ConvertTo-Json -Depth 5
    }
    'docs' {
        & (Join-Path $PSScriptRoot 'check_ads131m08_docs.ps1') -Json
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 documentation audit failed ($LASTEXITCODE)" }
        Write-Output 'HARNESS DOCS PASS'
    }
    'fifo-inference' {
        & (Join-Path $PSScriptRoot 'check_ads131m08_fifo_inference.ps1') -Json
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 FIFO inference probe failed ($LASTEXITCODE)" }
        Write-Output 'HARNESS FIFO-INFERENCE CHECK COMPLETE'
    }
    'faults' {
        & (Join-Path $PSScriptRoot 'test_ads131m08_fault_injection.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 fault-injection check failed ($LASTEXITCODE)" }
        Write-Output 'HARNESS FAULT-INJECTION PASS'
    }
    'sim' {
        $test = if ($Full) { 'all' } else { 'multi' }
        & (Join-Path $PSScriptRoot 'test_ads131m08_parameters.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 parameter checks failed ($LASTEXITCODE)" }
        & (Join-Path $PSScriptRoot 'test_ads131m08_fifo.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 FIFO checks failed ($LASTEXITCODE)" }
        & (Join-Path $PSScriptRoot 'test_ads131m08_fault_injection.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 fault-injection check failed ($LASTEXITCODE)" }
        & (Join-Path $PSScriptRoot 'test_ads131m08_ip_sim.ps1') -Test $test -TimeoutSeconds $TimeoutSeconds -Quiet:$Quiet
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 simulation failed ($LASTEXITCODE)" }
        Write-Output "HARNESS SIM PASS test=$test"
    }
    'synth' {
        & (Join-Path $PSScriptRoot 'build_ads131m08_ip_with_oss.ps1') -Board $Board -AdcCount $AdcCount
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 synthesis failed ($LASTEXITCODE)" }
        & (Join-Path $PSScriptRoot 'manifest_ads131m08.ps1') -Board $Board -AdcCount $AdcCount
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 manifest failed ($LASTEXITCODE)" }
        Write-Output "HARNESS SYNTH PASS board=$Board adc_count=$AdcCount"
    }
    'pnr' {
        & (Join-Path $PSScriptRoot 'build_ads131m08_ip_with_oss.ps1') -Board $Board -AdcCount $AdcCount -Route
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 P&R failed ($LASTEXITCODE)" }
        & (Join-Path $PSScriptRoot 'manifest_ads131m08.ps1') -Board $Board -AdcCount $AdcCount
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 manifest failed ($LASTEXITCODE)" }
        Write-Output "HARNESS PNR PASS board=$Board adc_count=$AdcCount"
    }
    'report' {
        & (Join-Path $PSScriptRoot 'report_ads131m08.ps1') -Board $Board -AdcCount $AdcCount
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Metric report failed ($LASTEXITCODE)" }
        Write-Output 'HARNESS REPORT PASS'
    }
    'formal' {
        & (Join-Path $PSScriptRoot 'test_ads131m08_formal.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 formal gate failed ($LASTEXITCODE)" }
        Write-Output 'HARNESS FORMAL CHECK COMPLETE'
    }
    'package' {
        & (Join-Path $PSScriptRoot 'package_ads131m08_candidate.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 candidate package failed ($LASTEXITCODE)" }
        Write-Output 'HARNESS CANDIDATE PACKAGE PASS'
    }
    'release-check' {
        $required = @('docs\CODE_MAP.md', 'docs\QUALITY_ISSUES.md', 'cores\acquisition\ads131m08\doc\README.md', 'cores\acquisition\ads131m08\doc\INTERFACE.md', 'cores\acquisition\ads131m08\doc\PARAMETERS.md', 'cores\acquisition\ads131m08\doc\REGISTER_MAP.md', 'cores\acquisition\ads131m08\doc\TIMING_AND_CONSTRAINTS.md', 'cores\acquisition\ads131m08\doc\CHANGELOG.md', 'cores\acquisition\ads131m08\formal\README.md', 'cores\acquisition\ads131m08\formal\ads131m08.sby', 'cores\acquisition\ads131m08\formal\ads131m08_formal_harness.sv', 'scripts\test_ads131m08_ip_sim.ps1', 'scripts\test_ads131m08_parameters.ps1', 'scripts\test_ads131m08_fifo.ps1', 'scripts\test_ads131m08_formal.ps1', 'scripts\test_ads131m08_fault_injection.ps1', 'scripts\build_ads131m08_ip_with_oss.ps1', 'scripts\lint_ads131m08.ps1', 'scripts\check_ads131m08_docs.ps1', 'scripts\check_ads131m08_fifo_inference.ps1', 'scripts\package_ads131m08_candidate.ps1', 'scripts\manifest_ads131m08.ps1', 'scripts\report_ads131m08.ps1')
        foreach ($item in $required) { if (-not (Test-Path (Join-Path $root $item))) { throw "Missing release input: $item" } }
        & (Join-Path $PSScriptRoot 'check_ads131m08_docs.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 documentation audit failed ($LASTEXITCODE)" }
        & (Join-Path $PSScriptRoot 'check_ads131m08_fifo_inference.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 FIFO inference probe failed ($LASTEXITCODE)" }
        & (Join-Path $PSScriptRoot 'test_ads131m08_fault_injection.ps1')
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "ADS131M08 fault-injection check failed ($LASTEXITCODE)" }
        $plan = Get-Content -Raw (Join-Path $root 'docs\HARNESS_ENGINEERING_PLAN.md')
        if ($plan -notmatch 'candidate-only|DEFERRED|未执行') { throw 'Release check cannot establish deferred hardware status.' }
        $evidencePath = Join-Path $reportDir 'tang20k_n1.manifest.json'
        if (-not (Test-Path $evidencePath)) { throw "Missing route evidence manifest: $evidencePath" }
        $evidence = Get-Content -Raw $evidencePath | ConvertFrom-Json
        if ($evidence.schema -ne 'ads131m08-build-manifest-v2') { throw 'Route evidence manifest schema is stale.' }
        if (-not $evidence.metadata_fresh) { throw 'Route evidence was inferred from stale artifacts; rerun harness pnr.' }
        if ($evidence.mode -ne 'pnr' -or $evidence.top -ne 'ads131m08_pads_top_20k') { throw '20K route evidence does not identify the scalar bring-up top.' }
        if (-not $evidence.resource_pass -or -not $evidence.pnr.resource_pass -or -not $evidence.pnr.route_pass) { throw '20K route evidence does not satisfy resource/P&R gates.' }
        if ($evidence.pnr.unconstrained_io_count -ne 0 -or -not $evidence.pnr.timing_pass) { throw '20K route evidence has unconstrained IO or failed timing.' }
        if ($evidence.board_evidence -ne 'DEFERRED') { throw 'Hardware evidence must remain DEFERRED until a board run is recorded.' }
        foreach ($record in @($evidence.source_files)) {
            $sourcePath = Join-Path $root ($record.path.Replace('/', '\'))
            if (-not (Test-Path $sourcePath -PathType Leaf)) { throw "Manifest source is missing: $($record.path)" }
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
            if ($actualHash -ne ([string]$record.sha256).ToLowerInvariant()) { throw "Manifest source hash is stale: $($record.path)" }
        }
        foreach ($record in @($evidence.artifacts)) {
            $artifactPath = Join-Path $root ($record.path.Replace('/', '\'))
            if (-not (Test-Path $artifactPath -PathType Leaf)) { throw "Manifest artifact is missing: $($record.path)" }
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
            if ($actualHash -ne ([string]$record.sha256).ToLowerInvariant()) { throw "Manifest artifact hash is stale: $($record.path)" }
        }
        $template = Get-Content -Raw (Join-Path $project 'constr\tang25k_ads131m08_16.cst')
        if ($template -notmatch '(?im)reference-only|template') { throw '25K constraint file is missing its reference-only declaration.' }
        $formalOutput = & (Join-Path $PSScriptRoot 'test_ads131m08_formal.ps1') 2>&1
        $formalExit = $LASTEXITCODE
        if ($null -eq $formalExit) { $formalExit = 0 }
        if ($formalExit -ne 0) { $formalOutput | Select-Object -Last 40 | Out-Host; throw "ADS131M08 formal gate failed ($formalExit)" }
        $formalPath = Join-Path $reportDir 'ads131m08-formal.json'
        if (-not (Test-Path $formalPath)) { throw "Missing formal status report: $formalPath" }
        $formal = Get-Content -Raw $formalPath | ConvertFrom-Json
        if ($formal.status -notin @('PASS-BOUNDED', 'DEFERRED')) { throw "Unsupported formal status: $($formal.status)" }
        Write-Output "HARNESS RELEASE-CHECK PASS manifest=$($evidencePath.Replace('\', '/')) resource_pass=$($evidence.resource_pass) timing_pass=$($evidence.pnr.timing_pass) unconstrained_io=$($evidence.pnr.unconstrained_io_count) formal=$($formal.status) board=DEFERRED"
    }
}
