param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$root = [string]$env:SIPEED_TANG20K_ROOT
$project = Join-Path $root 'cores\acquisition\ads131m08'
$reportDir = Join-Path $root 'docs\quality\reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$checks = @()
$failures = @()

function Add-Check([string]$Name, [bool]$Pass, [string]$Detail) {
    $record = [ordered]@{
        name = $Name
        pass = $Pass
        detail = $Detail
    }
    $script:checks += $record
    if (-not $Pass) { $script:failures += "${Name}: $Detail" }
}

function RepoPath([string]$Path) {
    return $Path.Replace('/', '\')
}

$releaseFiles = @(
    'docs\CODE_MAP.md',
    'docs\QUALITY_ISSUES.md',
    'cores\acquisition\ads131m08\rtl\ads131m08_multi_ip.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_axi_lite.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_sample_fifo.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_regfile.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_stream_adapter.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_scheduler.v',
    'cores\acquisition\ads131m08\rtl\ads131m08_spi_engine.v',
    'cores\acquisition\ads131m08\sim\tb_ads131m08_multi_ip.v',
    'cores\acquisition\ads131m08\sim\tb_ads131m08_axi.v',
    'cores\acquisition\ads131m08\sim\tb_ads131m08_fifo.v',
    'cores\acquisition\ads131m08\sim\ads131m08_device_model.v',
    'cores\acquisition\ads131m08\doc\README.md',
    'cores\acquisition\ads131m08\doc\INTERFACE.md',
    'cores\acquisition\ads131m08\doc\PARAMETERS.md',
    'cores\acquisition\ads131m08\doc\REGISTER_MAP.md',
    'cores\acquisition\ads131m08\doc\TIMING_AND_CONSTRAINTS.md',
    'cores\acquisition\ads131m08\doc\CHANGELOG.md',
    'cores\acquisition\ads131m08\formal\README.md',
    'cores\acquisition\ads131m08\formal\ads131m08.sby',
    'cores\acquisition\ads131m08\formal\ads131m08_formal_harness.sv',
    'cores\acquisition\ads131m08\constr\tang20k_ads131m08_ip.cst',
    'cores\acquisition\ads131m08\constr\tang25k_ads131m08_16.cst',
    'scripts\harness.ps1',
    'scripts\lint_ads131m08.ps1',
    'scripts\test_ads131m08_ip_sim.ps1',
    'scripts\test_ads131m08_parameters.ps1',
    'scripts\test_ads131m08_fifo.ps1',
    'scripts\test_ads131m08_formal.ps1',
    'scripts\build_ads131m08_ip_with_oss.ps1',
    'scripts\manifest_ads131m08.ps1',
    'scripts\report_ads131m08.ps1'
    'scripts\check_ads131m08_fifo_inference.ps1'
    'scripts\test_ads131m08_fault_injection.ps1'
    'scripts\package_ads131m08_candidate.ps1'
)

foreach ($relative in $releaseFiles) {
    $path = Join-Path $root $relative
    Add-Check "file:$relative" (Test-Path $path -PathType Leaf) 'required release input exists'
}

$documentationFiles = @(
    'docs\CODE_MAP.md',
    'docs\QUALITY_ISSUES.md',
    'docs\HARNESS_ENGINEERING_PLAN.md',
    'cores\acquisition\ads131m08\doc\README.md',
    'cores\acquisition\ads131m08\doc\INTERFACE.md',
    'cores\acquisition\ads131m08\doc\PARAMETERS.md',
    'cores\acquisition\ads131m08\doc\REGISTER_MAP.md',
    'cores\acquisition\ads131m08\doc\TIMING_AND_CONSTRAINTS.md',
    'cores\acquisition\ads131m08\doc\CHANGELOG.md',
    'cores\acquisition\ads131m08\formal\README.md'
)

# Audit repository-relative paths written in documentation. This catches a
# renamed script or RTL input before a release document points users at it.
$pathPattern = '(?<path>(?:docs|projects|scripts)/[A-Za-z0-9_./\\-]+\.(?:md|ps1|v|sv|sby|cst))'
foreach ($relative in $documentationFiles) {
    $path = Join-Path $root $relative
    if (-not (Test-Path $path -PathType Leaf)) { continue }
    $raw = Get-Content -Raw $path
    foreach ($match in [regex]::Matches($raw, $pathPattern)) {
        $reference = RepoPath $match.Groups['path'].Value
        $target = Join-Path $root $reference
        Add-Check "link:${relative}:$reference" (Test-Path $target -PathType Leaf) 'documented path exists'
    }
}

$buildScript = Get-Content -Raw (Join-Path $root 'scripts\build_ads131m08_ip_with_oss.ps1')
foreach ($source in @(
    'ads131m08_spi_engine.v',
    'ads131m08_scheduler.v',
    'ads131m08_axi_lite.v',
    'ads131m08_sample_fifo.v',
    'ads131m08_regfile.v',
    'ads131m08_stream_adapter.v',
    'ads131m08_multi_ip.v'
)) {
    Add-Check "build-source:$source" ($buildScript -match [regex]::Escape($source)) 'build input is listed by the reproducible OSS flow'
}

$rtl = Get-Content -Raw (Join-Path $project 'rtl\ads131m08_multi_ip.v')
$regfileRtl = Get-Content -Raw (Join-Path $project 'rtl\ads131m08_regfile.v')
$registerRtl = $rtl + "`n" + $regfileRtl
$registerMap = Get-Content -Raw (Join-Path $project 'doc\REGISTER_MAP.md')
foreach ($register in @(
    @{ name = 'CTRL';        token = "ridx == 10'h000"; doc = '0x000' },
    @{ name = 'STATUS';      token = "ridx == 10'h001"; doc = '0x004' },
    @{ name = 'SCHED';       token = "ridx == 10'h002"; doc = '0x008' },
    @{ name = 'ERR';         token = "ridx == 10'h003"; doc = '0x00C' },
    @{ name = 'IRQ_EN';      token = "ridx == 10'h004"; doc = '0x010' },
    @{ name = 'IRQ_STATUS';  token = "ridx == 10'h005"; doc = '0x014' },
    @{ name = 'CFG0';        token = "ridx == 10'h006"; doc = '0x018' },
    @{ name = 'CFG1';        token = "ridx == 10'h007"; doc = '0x01C' },
    @{ name = 'FIFO_DATA';   token = "ridx == 10'h080"; doc = '0x200' },
    @{ name = 'FIFO_STATUS'; token = "ridx == 10'h081"; doc = '0x204' },
    @{ name = 'DROP_COUNT';  token = "ridx == 10'h082"; doc = '0x208' }
)) {
    Add-Check "rtl-register:$($register.name)" ($registerRtl -match [regex]::Escape($register.token)) 'register read mux retains the documented word index'
    Add-Check "doc-register:$($register.name)" ($registerMap -match [regex]::Escape($register.doc) -and $registerMap -match [regex]::Escape($register.name)) 'register map retains the documented byte offset'
}

$cst25 = Get-Content -Raw (Join-Path $project 'constr\tang25k_ads131m08_16.cst')
Add-Check 'constraint:tang25k-role' ($cst25 -match '(?im)reference-only|template') '25K pin mapping remains explicitly reference-only'
$formalReadme = Get-Content -Raw (Join-Path $project 'formal\README.md')
Add-Check 'formal:scope' ($formalReadme -match '(?i)bounded' -and $formalReadme -match '(?i)DEFERRED') 'formal documentation states bounded scope and deferred board evidence'

$status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
$result = [ordered]@{
    schema = 'ads131m08-doc-audit-v1'
    generated = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    check_count = $checks.Count
    failure_count = $failures.Count
    checks = $checks
    failures = $failures
}
$reportPath = Join-Path $reportDir 'ads131m08-doc-audit.json'
$result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $reportPath

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    Write-Output "ADS131M08 DOC AUDIT $status checks=$($checks.Count) failures=$($failures.Count)"
    if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "FAIL $_" } }
}

if ($failures.Count -gt 0) { exit 1 }
exit 0
