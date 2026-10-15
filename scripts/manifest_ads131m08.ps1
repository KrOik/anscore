param(
    [ValidateSet('tang25k', 'tang20k')]
    [string]$Board = 'tang20k',
    [ValidateRange(1, 16)]
    [int]$AdcCount = 1,
    [double]$TargetMHz = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$root = [string]$env:SIPEED_TANG20K_ROOT
$project = Join-Path $root 'cores\acquisition\ads131m08'
$build = Join-Path $project 'build_oss'
$tag = "${Board}_n${AdcCount}"
$statPath = Join-Path $build "$tag.stat.txt"
$metaPath = Join-Path $build "$tag.build.json"
$jsonPath = Join-Path $build "$tag.json"
$pnrPath = Join-Path $build "$tag.pnr.json"
$pnrLogPath = Join-Path $build "$tag.pnr.log"
$fsPath = Join-Path $build "$tag.fs"

if (-not (Test-Path $statPath)) { throw "Missing stat report: $statPath" }

function Get-StatBlock([string]$Raw, [string]$Top) {
    $escapedTop = [regex]::Escape($Top)
    $blocks = [regex]::Matches($Raw, "(?ms)^===\s+$escapedTop\s+===\s*\r?\n(?<body>.*?)(?=^Warnings:|\z)")
    if ($blocks.Count -eq 0) { throw "No final yosys statistics block found for top '$Top'" }
    return $blocks[$blocks.Count - 1].Groups['body'].Value
}

function Get-StatCount([string]$Body, [string[]]$Types) {
    foreach ($type in $Types) {
        $escapedType = [regex]::Escape($type)
        $matches = [regex]::Matches($Body, "(?m)^\s*(\d+)\s+$escapedType\s*$")
        if ($matches.Count -gt 0) {
            return [int]$matches[$matches.Count - 1].Groups[1].Value
        }
    }
    return 0
}

function Get-StatSum([string]$Body, [string[]]$Types) {
    $sum = 0
    foreach ($type in $Types) {
        $escapedType = [regex]::Escape($type)
        $matches = [regex]::Matches($Body, "(?m)^\s*(\d+)\s+$escapedType\s*$")
        if ($matches.Count -gt 0) { $sum += [int]$matches[$matches.Count - 1].Groups[1].Value }
    }
    return $sum
}

function ConvertTo-RepoPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $full = [System.IO.Path]::GetFullPath($Path)
    $prefix = ([System.IO.Path]::GetFullPath($root)).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($prefix.Length).Replace('\', '/')
    }
    return $full.Replace('\', '/')
}

function Get-ToolVersion([string]$Tool) {
    $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
    if (-not $cmd) { return [ordered]@{ available = $false; version = $null } }
    $versionArgs = @('--version')
    if ($Tool -in @('iverilog', 'vvp')) { $versionArgs = @('-V') }
    if ($Tool -in @('powershell', 'pwsh')) { $versionArgs = @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()') }
    $text = (& $Tool @versionArgs 2>&1 | Select-Object -First 1) -join ' '
    return [ordered]@{ available = $true; path = $cmd.Source; version = $text }
}

function Get-ArtifactRecord([string]$Path) {
    if (-not (Test-Path $Path -PathType Leaf)) { return $null }
    $item = Get-Item $Path
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $Path
    return [ordered]@{
        path = ConvertTo-RepoPath $Path
        bytes = [int64]$item.Length
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

# Build metadata is authoritative. The fallback keeps older generated
# artifacts readable, but marks the result so a fresh build can be required by
# release-check rather than silently trusting stale P&R files.
$metadataFresh = Test-Path $metaPath
if ($metadataFresh) {
    $meta = Get-Content -Raw $metaPath | ConvertFrom-Json
    $top = [string]$meta.top
    $mode = [string]$meta.mode
    $family = [string]$meta.family
    $part = [string]$meta.part
    $device = [string]$meta.device
    $targetFromMeta = [double]$meta.target_mhz
    $constraint = [string]$meta.constraint
    $constraintRole = [string]$meta.constraint_role
    $sourcePaths = @($meta.sources)
} else {
    $mode = if (Test-Path $pnrLogPath) { 'legacy-inferred-pnr' } else { 'legacy-inferred-synth' }
    $top = if ($mode -match 'pnr') {
        if ($Board -eq 'tang20k') { 'ads131m08_pads_top_20k' } else { 'ads131m08_pads_top' }
    } else { 'ads131m08_multi_ip' }
    $family = if ($Board -eq 'tang20k') { 'gw2a' } else { 'gw5a' }
    $part = if ($Board -eq 'tang20k') { 'GW2A-LV18PG256C8/I7' } else { 'GW5A-LV25MG121NES' }
    $device = if ($Board -eq 'tang20k') { 'GW2A-18' } else { 'GW5A-25A' }
    $targetFromMeta = if ($Board -eq 'tang20k') { 27 } else { 50 }
    $constraint = Join-Path $project (if ($Board -eq 'tang20k') { 'constr\tang20k_ads131m08_ip.cst' } else { 'constr\tang25k_ads131m08_16.cst' })
    $constraintRole = if ($Board -eq 'tang25k') { 'reference-only' } else { 'route-checked-template' }
    $sourcePaths = @(Get-ChildItem (Join-Path $project 'rtl') -Filter '*.v' | Sort-Object Name | ForEach-Object { $_.FullName })
}

if ($TargetMHz -le 0) { $TargetMHz = $targetFromMeta }
$statRaw = Get-Content -Raw $statPath
$statBody = Get-StatBlock $statRaw $top
$lut4 = Get-StatCount $statBody @('LUT4')
$dff = Get-StatSum $statBody @(
    'DFF', 'DFFE', 'DFFS', 'DFFSE', 'DFFR', 'DFFRE', 'DFFP', 'DFFPE',
    'DFFC', 'DFFCE', 'DFFN', 'DFFNE', 'DFFNS', 'DFFNSE', 'DFFNR',
    'DFFNRE', 'DFFNP', 'DFFNPE', 'DFFNC', 'DFFNCE'
)
$alu = Get-StatCount $statBody @('ALU')
$bram = Get-StatSum $statBody @('BSRAM', 'SDP', 'SDPB', 'SDPX9B', 'DP', 'DPB', 'DPX9B')
$dsp = Get-StatSum $statBody @('MULT', 'MULT9X9', 'MULT18X18', 'MULT36X36', 'MULTADDALU18X18')
$cellMatch = [regex]::Match($statBody, '(?m)^\s*(\d+)\s+cells\s*$')
$cellCount = if ($cellMatch.Success) { [int]$cellMatch.Groups[1].Value } else { $null }
$statWarning = [regex]::Match($statRaw, '(?m)^Warnings:\s+(\d+)\s+unique messages,\s+(\d+)\s+total')
$warningSummary = if ($statWarning.Success) {
    [ordered]@{ unique = [int]$statWarning.Groups[1].Value; total = [int]$statWarning.Groups[2].Value }
} else { [ordered]@{ unique = $null; total = $null } }

$pnrAttempted = $mode -match 'pnr'
$pnrRaw = if (Test-Path $pnrLogPath) { Get-Content -Raw $pnrLogPath } else { '' }
$pnrEvidenceRaw = if ($pnrAttempted) { $pnrRaw } else { '' }
$freqMatches = [regex]::Matches($pnrEvidenceRaw, 'Max frequency for clock .*?:\s*([0-9.]+) MHz')
$fmax = if ($freqMatches.Count -gt 0) { [double]$freqMatches[$freqMatches.Count - 1].Groups[1].Value } else { $null }
$unconstrainedMatches = [regex]::Matches($pnrEvidenceRaw, '(?im)^\s*(?!.*\bno\b).*unconstrained\s+(?:I/O|IO|ports?)')
$routeErrorMatches = [regex]::Matches($pnrEvidenceRaw, '(?im)^\s*(?:ERROR:|FATAL:|Failed to (?:place|route)|No package for|could not route)')
$pnrLutMatch = [regex]::Match($pnrEvidenceRaw, '(?im)^\s*Info:\s+LUT4:\s+(\d+)\s*/')

function Get-PnrCount([string]$Raw, [string]$Type) {
    $escapedType = [regex]::Escape($Type)
    $matches = [regex]::Matches($Raw, "(?im)^\s*Info:\s+${escapedType}:\s+(\d+)\s*/")
    if ($matches.Count -gt 0) { return [int]$matches[$matches.Count - 1].Groups[1].Value }
    return 0
}

function Get-PnrSum([string]$Raw, [string[]]$Types) {
    $sum = 0
    foreach ($type in $Types) { $sum += Get-PnrCount $Raw $type }
    return $sum
}

$synthesisResources = [ordered]@{
    lut4 = $lut4
    alu = $alu
    dff = $dff
    bram = $bram
    dsp = $dsp
    cells = $cellCount
}
$pnrResources = [ordered]@{
    lut4 = Get-PnrCount $pnrRaw 'LUT4'
    alu = Get-PnrCount $pnrRaw 'ALU'
    dff = Get-PnrCount $pnrRaw 'DFF'
    bram = Get-PnrCount $pnrRaw 'BSRAM'
    dsp = Get-PnrSum $pnrRaw @('MULT9X9', 'MULT18X18', 'MULT36X36', 'MULTADDALU18X18', 'MULTALU18X18', 'MULTALU36X18', 'ALU54D')
    cells = $null
}
$pnrResourcesPresent = $pnrAttempted -and $pnrLutMatch.Success
$synthesisResourcePass = ($synthesisResources.lut4 -le 15000 -and $synthesisResources.dsp -le 4)
$pnrResourcePass = if ($pnrAttempted) {
    $pnrResourcesPresent -and ($pnrResources.lut4 -le 15000 -and $pnrResources.dsp -le 4)
} else { $null }
$selectedResources = if ($pnrAttempted) { $pnrResources } else { $synthesisResources }
$timingPass = if ($pnrAttempted) { $null -ne $fmax -and $fmax -ge $TargetMHz } else { $null }
$routePass = if ($pnrAttempted) {
    (Test-Path $fsPath -PathType Leaf) -and
    [bool]$pnrResourcePass -and
    ($unconstrainedMatches.Count -eq 0) -and
    ($routeErrorMatches.Count -eq 0) -and
    [bool]$timingPass
} else { $null }

$sourceRecords = @()
foreach ($sourcePath in $sourcePaths) {
    $record = Get-ArtifactRecord ([string]$sourcePath)
    if ($null -eq $record) { throw "Missing source listed by build metadata: $sourcePath" }
    $sourceRecords += $record
}
$artifactRecords = @()
$artifactCandidates = @($statPath, $jsonPath, $metaPath)
if ($pnrAttempted) { $artifactCandidates += @($pnrPath, $pnrLogPath, $fsPath) }
foreach ($artifactPath in $artifactCandidates) {
    $record = Get-ArtifactRecord $artifactPath
    if ($null -ne $record) { $artifactRecords += $record }
}

$tools = [ordered]@{}
foreach ($tool in @('iverilog', 'vvp', 'yosys', 'nextpnr-himbaechel', 'sby', 'boolector', 'python', 'powershell', 'pwsh', 'git')) { $tools[$tool] = Get-ToolVersion $tool }
$gitCommit = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitCommit = (& git -C $root rev-parse HEAD 2>$null | Select-Object -First 1)
}

$resourcePass = ($synthesisResourcePass -and (!$pnrAttempted -or [bool]$pnrResourcePass))
$result = [ordered]@{
    schema = 'ads131m08-build-manifest-v2'
    generated = (Get-Date).ToUniversalTime().ToString('o')
    git_commit = $gitCommit
    board = $Board
    adc_count = $AdcCount
    mode = $mode
    metadata_fresh = [bool]$metadataFresh
    top = $top
    family = $family
    part = $part
    device = $device
    constraint = ConvertTo-RepoPath $constraint
    constraint_role = $constraintRole
    target_mhz = $TargetMHz
    resource_basis = 'synthesis_resources are final yosys mapped statistics; resources use nextpnr device utilisation when mode=pnr'
    # `resources` is the selected gate view for compatibility. The two
    # explicit views below preserve the distinction between IP sizing and
    # post-pack device utilisation.
    resources = $selectedResources
    synthesis_resources = $synthesisResources
    pnr_resources = if ($pnrAttempted) { $pnrResources } else { $null }
    warnings = $warningSummary
    resource_budget = [ordered]@{ lut4_max = 15000; dsp_max = 4 }
    resource_pass = $resourcePass
    pnr = [ordered]@{
        attempted = [bool]$pnrAttempted
        artifact = ($pnrAttempted -and (Test-Path $fsPath -PathType Leaf))
        fmax_mhz = $fmax
        timing_pass = $timingPass
        unconstrained_io_count = $unconstrainedMatches.Count
        route_error_count = $routeErrorMatches.Count
        warning_count = [regex]::Matches($pnrEvidenceRaw, '(?im)^\s*Warning:').Count
        resources_present = [bool]$pnrResourcesPresent
        resource_pass = $pnrResourcePass
        route_pass = $routePass
    }
    timing_pass = $timingPass
    route_pass = $routePass
    source_files = $sourceRecords
    artifacts = $artifactRecords
    tools = $tools
    board_evidence = 'DEFERRED'
    gate_pass = ($resourcePass -and (!$pnrAttempted -or [bool]$routePass))
}

$reportDir = Join-Path $root 'docs\quality\reports'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$out = Join-Path $reportDir "$tag.manifest.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $out
$result | ConvertTo-Json -Depth 8

if (-not $result.resource_pass -or ($pnrAttempted -and -not $result.pnr.route_pass)) { exit 1 }
