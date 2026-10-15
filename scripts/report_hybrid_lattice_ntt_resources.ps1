$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\crypto\hybrid_lattice_ntt'
$jsonPath = Join-Path $project 'build_oss\top.json'

if (!(Test-Path $jsonPath)) {
    throw "Synthesized JSON not found: $jsonPath. Run scripts/build_hybrid_lattice_ntt_with_oss.ps1 first."
}

$json = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
$top = $json.modules.top
$counts = @{}

foreach ($cellProp in $top.cells.PSObject.Properties) {
    $type = [string]$cellProp.Value.type
    if (!$counts.ContainsKey($type)) {
        $counts[$type] = 0
    }
    $counts[$type]++
}

$lut = 0
$ff = 0
$dsp = 0
$bram = 0

foreach ($entry in $counts.GetEnumerator()) {
    if ($entry.Key -match 'LUT') {
        $lut += $entry.Value
    }
    if ($entry.Key -match 'DFF|DFFE|DFFC|DFFR|DFFS') {
        $ff += $entry.Value
    }
    if ($entry.Key -match 'DSP|MULT|MULTALU|PADD') {
        $dsp += $entry.Value
    }
    if ($entry.Key -match 'BSRAM|SP|SDP|DPB|RAM') {
        $bram += $entry.Value
    }
}

[PSCustomObject]@{
    Project = 'hybrid_lattice_ntt_20k'
    ApproxLUTCells = $lut
    ApproxFFCells = $ff
    ApproxDSPCells = $dsp
    ApproxBRAMCells = $bram
    Under15kLUT = ($lut -le 15000)
    Under4DSP = ($dsp -le 4)
}
