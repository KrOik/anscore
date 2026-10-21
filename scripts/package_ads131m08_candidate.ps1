param(
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$root = [string]$env:SIPEED_TANG20K_ROOT
if ([string]::IsNullOrEmpty($OutputRoot)) {
    $OutputRoot = Join-Path $root 'artifacts\generated'
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$allowedOutputRoot = [System.IO.Path]::GetFullPath((Join-Path $root 'artifacts\generated')).TrimEnd('\', '/')
if (-not $OutputRoot.StartsWith($allowedOutputRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
    $OutputRoot -ne $allowedOutputRoot) {
    throw "-OutputRoot must stay under $allowedOutputRoot"
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

# The package is candidate-only by construction: release-check enforces the
# current route/formal/document gates, while the package metadata retains the
# deferred physical-board status and known open issue register.
& (Join-Path $PSScriptRoot 'harness.ps1') release-check
if ($LASTEXITCODE -ne 0) { throw "Cannot package a failed release check ($LASTEXITCODE)" }

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$tag = "ads131m08-candidate-$stamp"
$staging = Join-Path $OutputRoot $tag
$zipPath = Join-Path $OutputRoot "$tag.zip"
$shaPath = Join-Path $OutputRoot "$tag.zip.sha256"
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$packageFiles = @(
    'docs\CODE_MAP.md',
    'docs\HARNESS_ENGINEERING_PLAN.md',
    'docs\QUALITY_ISSUES.md',
    'cores\acquisition\ads131m08\rtl\ads131m08_multi_ip.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_axi_lite.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_sample_fifo.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_regfile.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_stream_adapter.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_scheduler.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_spi_engine.v',
    'cores\acquisition\ads131m08\src\ads131m08_pads_top.v',
    'cores\acquisition\ads131m08\src\ads131m08_pads_top_20k.v',
    'cores\acquisition\ads131m08\constr\tang20k_ads131m08_ip.cst',
    'cores\acquisition\ads131m08\constr\tang25k_ads131m08_16.cst',
    'cores\acquisition\ads131m08\doc\README.md',
    'cores\acquisition\ads131m08\doc\INTERFACE.md',
    'cores\acquisition\ads131m08\doc\PARAMETERS.md',
    'cores\acquisition\ads131m08\doc\REGISTER_MAP.md',
    'cores\acquisition\ads131m08\doc\TIMING_AND_CONSTRAINTS.md',
    'cores\acquisition\ads131m08\doc\CHANGELOG.md',
    'cores\acquisition\ads131m08\formal\README.md',
    'cores\acquisition\ads131m08\formal\ads131m08.sby',
    'cores\acquisition\ads131m08\formal\ads131m08_formal_harness.sv',
    'cores\acquisition\ads131m08\sim\ads131m08_device_model.v',
    'cores\acquisition\ads131m08\sim\ads131m08_timing_check.vh',
    'cores\acquisition\ads131m08\sim\tb_ads131m08_multi_ip.v',
    'cores\acquisition\ads131m08\sim\tb_ads131m08_axi.v',
    'cores\acquisition\ads131m08\sim\tb_ads131m08_fifo.v',
    'scripts\env.ps1',
    'scripts\harness.ps1',
    'scripts\lint_ads131m08.ps1',
    'scripts\test_ads131m08_ip_sim.ps1',
    'scripts\test_ads131m08_parameters.ps1',
    'scripts\test_ads131m08_fifo.ps1',
    'scripts\test_ads131m08_formal.ps1',
    'scripts\test_ads131m08_fault_injection.ps1',
    'scripts\check_ads131m08_docs.ps1',
    'scripts\check_ads131m08_fifo_inference.ps1',
    'scripts\build_ads131m08_ip_with_oss.ps1',
    'scripts\manifest_ads131m08.ps1',
    'scripts\report_ads131m08.ps1',
    'scripts\package_ads131m08_candidate.ps1'
)

$copied = @()
foreach ($relative in $packageFiles) {
    $source = Join-Path $root $relative
    if (-not (Test-Path $source -PathType Leaf)) { throw "Missing package input: $relative" }
    $destination = Join-Path $staging $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $source
    $copied += [ordered]@{
        path = $relative.Replace('\', '/')
        bytes = [int64](Get-Item -LiteralPath $source).Length
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

$reportDir = Join-Path $root 'docs\quality\reports'
$evidence = @()
foreach ($name in @('scan.json', 'ads131m08-formal.json', 'ads131m08-resource-report.json', 'tang20k_n1.manifest.json', 'ads131m08-doc-audit.json', 'ads131m08-fifo-inference.json', 'ads131m08-fault-injection.json')) {
    $source = Join-Path $reportDir $name
    if (Test-Path $source -PathType Leaf) {
        $destination = Join-Path $staging "docs\quality\reports\$name"
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $source
        $evidence += [ordered]@{ path = "docs/quality/reports/$name"; sha256 = $hash.Hash.ToLowerInvariant() }
    }
}

$packageManifest = [ordered]@{
    schema = 'ads131m08-candidate-package-v1'
    generated = (Get-Date).ToUniversalTime().ToString('o')
    release_status = 'candidate-only'
    board_evidence = 'DEFERRED'
    constraint_25k = 'reference-only'
    source_files = $copied
    evidence_files = $evidence
    note = 'Physical-board programming, electrical SPI measurements and hardware verification are deferred.'
}
$packageManifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $staging 'PACKAGE_MANIFEST.json')

Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal
$zipHash = Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath
"$($zipHash.Hash.ToLowerInvariant())  $([System.IO.Path]::GetFileName($zipPath))" | Set-Content -Encoding ASCII $shaPath

$result = [ordered]@{
    schema = 'ads131m08-candidate-package-result-v1'
    generated = (Get-Date).ToUniversalTime().ToString('o')
    status = 'PASS-CANDIDATE-ONLY'
    package = $zipPath.Replace('\', '/')
    sha256 = $zipHash.Hash.ToLowerInvariant()
    sha256_file = $shaPath.Replace('\', '/')
    file_count = $copied.Count + $evidence.Count + 1
    board_evidence = 'DEFERRED'
}
$result | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $OutputRoot "$tag.result.json")
$result | ConvertTo-Json -Depth 6
