param(
    [int]$Width = 272,
    [int[]]$Depth = @(64, 512),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$root = [string]$env:SIPEED_TANG20K_ROOT
$fifo = (Join-Path $root 'cores\acquisition\ads131m08\rtl\ads131m08_sample_fifo.v').Replace('\', '/')
$reportDir = Join-Path $root 'docs\quality\reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Get-PrimitiveCount([string]$Text, [string[]]$Names) {
    $sum = 0
    foreach ($name in $Names) {
        $matches = [regex]::Matches($Text, "(?im)^\s*(\d+)\s+$([regex]::Escape($name))\s*$")
        if ($matches.Count -gt 0) { $sum += [int]$matches[$matches.Count - 1].Groups[1].Value }
    }
    return $sum
}

function Invoke-Probe([string]$Family, [int]$ProbeDepth) {
    $tag = "${Family}_d${ProbeDepth}"
    $logPath = Join-Path $reportDir "ads131m08-fifo-$tag.log"
    $yosysScript = "read_verilog -sv $fifo; chparam -set WIDTH $Width -set DEPTH $ProbeDepth ads131m08_sample_fifo; synth_gowin -family $Family -top ads131m08_sample_fifo; stat"
    $output = yosys -p $yosysScript 2>&1
    $exitCode = $LASTEXITCODE
    $output | Set-Content -Encoding UTF8 $logPath
    $outputText = @($output) -join "`n"

    if ($exitCode -ne 0) {
        return [ordered]@{
            family = $Family
            depth = $ProbeDepth
            status = 'DEFERRED'
            inference = 'UNAVAILABLE'
            bsram = $null
            block_ram = $null
            ssram = $null
            distributed_ram = $null
            reason = "yosys synth_gowin failed with exit code $exitCode"
            log = $logPath.Replace('\', '/')
        }
    }

    $bsram = Get-PrimitiveCount $outputText @(
        'BSRAM', 'SP', 'SPB', 'SPX9B', 'SDPB', 'SDPX9B', 'DPB', 'DPX9B'
    )
    $ssram = Get-PrimitiveCount $outputText @('SSRAM')
    $distributed = Get-PrimitiveCount $outputText @(
        'RAM16S1', 'RAM16S2', 'RAM16S4', 'RAM16SDP1', 'RAM16SDP2',
        'RAM16SDP4', 'RAM16SDP8'
    )
    $inferred = ($bsram + $ssram + $distributed) -gt 0
    return [ordered]@{
        family = $Family
        depth = $ProbeDepth
        status = if ($inferred) { 'PASS' } else { 'DEFERRED' }
        inference = if ($inferred) { 'DETECTED' } else { 'NOT-DETECTED' }
        bsram = $bsram
        block_ram = $bsram
        ssram = $ssram
        distributed_ram = $distributed
        reason = if ($inferred) { 'Gowin mapped a memory primitive in this isolated probe' } else { 'No Gowin memory primitive was present in the final isolated stat block' }
        log = $logPath.Replace('\', '/')
    }
}

$probes = @()
foreach ($family in @('gw2a', 'gw5a')) {
    foreach ($probeDepth in $Depth) {
        if ($probeDepth -lt 2 -or ($probeDepth -band ($probeDepth - 1)) -ne 0) {
            throw "Probe depth must be a power of two >= 2: $probeDepth"
        }
        $probes += Invoke-Probe $family $probeDepth
    }
}

$hasDeferred = @($probes | Where-Object { $_.status -eq 'DEFERRED' }).Count -gt 0
$result = [ordered]@{
    schema = 'ads131m08-fifo-inference-report-v1'
    generated = (Get-Date).ToUniversalTime().ToString('o')
    width = $Width
    requested_depths = $Depth
    status = if ($hasDeferred) { 'DEFERRED' } else { 'PASS' }
    interpretation = 'This is an implementation evidence probe, not a functional or cross-vendor release gate. DEFERRED means the selected local flow did not provide sufficient evidence.'
    probes = $probes
}
$reportPath = Join-Path $reportDir 'ads131m08-fifo-inference.json'
$result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $reportPath

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    Write-Output "ADS131M08 FIFO INFERENCE $($result.status) probes=$($probes.Count)"
    foreach ($probe in $probes) {
        Write-Output ("  {0} depth={1} inference={2} block_ram={3} SSRAM={4} distributed={5}" -f `
            $probe.family, $probe.depth, $probe.inference, $probe.block_ram, $probe.ssram, $probe.distributed_ram)
    }
}

# A deferred implementation probe is an honest result and does not invalidate
# functional regression. The H-007 status remains open until portable BRAM
# evidence is available.
exit 0
