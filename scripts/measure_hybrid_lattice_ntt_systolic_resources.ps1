$ErrorActionPreference = 'Stop'

# Standalone sizing gate for the systolic NTT subsystem.
#
# The board top already uses most of the device, so the coefficient-state systolic
# array, the descriptor bridge and the descriptor sequencer are deliberately not
# wired into src/top.v.  That means the normal resource report never sees them and
# the subsystem had no size verdict at all.  This script synthesizes each module on
# its own and applies the same cell-class counting that
# report_hybrid_lattice_ntt_resources.ps1 uses, so the figures compare directly
# with the board-top numbers.
#
# ALU cells are listed separately: yosys maps the shift-add modular pipeline to GW2A
# ALU primitives, which share slice area with LUT4s, so the subsystem total is
# LUT + ALU for slice-pressure purposes.

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\crypto\hybrid_lattice_ntt'
$outDir = Join-Path $project 'build_oss\systolic_resources'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$modules = @(
    [pscustomobject]@{
        Name = 'ntt256_systolic_state_array'
        Sources = @(
            'src/ntt256_systolic_bank_mapper.v',
            'src/ntt256_systolic_arith_pipe.v',
            'src/ntt256_systolic_state_array.v'
        )
    },
    [pscustomobject]@{
        Name = 'hybrid_descriptor_bridge'
        Sources = @('src/hybrid_descriptor_bridge.v')
    },
    [pscustomobject]@{
        Name = 'hybrid_zero_switch_descriptor_sequencer'
        Sources = @('src/hybrid_zero_switch_descriptor_sequencer.v')
    }
)

function Get-CellClasses {
    param(
        [Parameter(Mandatory = $true)][string]$JsonPath,
        [Parameter(Mandatory = $true)][string]$ModuleName
    )

    $json = Get-Content -Path $JsonPath -Raw | ConvertFrom-Json
    if (!$json.modules.PSObject.Properties.Name -contains $ModuleName) {
        throw "module $ModuleName not present in $JsonPath"
    }
    $counts = @{}
    foreach ($cellProp in $json.modules.$ModuleName.cells.PSObject.Properties) {
        $type = [string]$cellProp.Value.type
        if (!$counts.ContainsKey($type)) {
            $counts[$type] = 0
        }
        $counts[$type]++
    }

    $result = [pscustomobject]@{
        LUT    = 0
        FF     = 0
        DSP    = 0
        BRAM   = 0
        LUTRAM = 0
        ALU    = 0
    }
    foreach ($entry in $counts.GetEnumerator()) {
        if ($entry.Key -match 'LUT' -and $entry.Key -notmatch '^RAM16') { $result.LUT += $entry.Value }
        if ($entry.Key -match 'DFF|DFFE|DFFC|DFFR|DFFS') { $result.FF += $entry.Value }
        if ($entry.Key -match 'DSP|MULT|MULTALU|PADD') { $result.DSP += $entry.Value }
        # RAM16SDPx primitives are slice LUTRAM, not block RAM, and they consume
        # slice area, so they must not inflate the block-RAM column.
        if ($entry.Key -match '^RAM16') { $result.LUTRAM += $entry.Value }
        elseif ($entry.Key -match 'BSRAM|SDP|SPX9|DPB|^SP$') { $result.BRAM += $entry.Value }
        if ($entry.Key -match '^ALU') { $result.ALU += $entry.Value }
    }
    return $result
}

$rows = @()
foreach ($module in $modules) {
    $jsonPath = Join-Path $outDir ($module.Name + '.json').Replace('\', '/')
    $sources = ($module.Sources | ForEach-Object { (Join-Path $project $_).Replace('\', '/') }) -join ' '
    $logPath = Join-Path $outDir ($module.Name + '.yosys.log')

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # No -flatten: synth_gowin in this yosys build has no such option, and
        # inlining the LUTRAM cells would replace RAM16SDP4 primitives with logic the
        # router never sees.  The LUTRAM column below counts those instances instead,
        # and nextpnr's own utilization table is the authority on device pressure.
        yosys -p "read_verilog $sources; synth_gowin -family gw2a -top $($module.Name) -json $jsonPath" `
            2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $logPath | Out-Null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw "yosys failed for $($module.Name) with exit code $exitCode (see $logPath)"
    }

    $classes = Get-CellClasses -JsonPath (Join-Path $outDir ($module.Name + '.json')) -ModuleName $module.Name
    $rows += [pscustomobject]@{
        Module      = $module.Name
        LUTCells    = $classes.LUT
        ALUCells    = $classes.ALU
        SliceCells  = $classes.LUT + $classes.ALU
        FFCells     = $classes.FF
        BRAMBlocks  = $classes.BRAM
        LUTRAMCells = $classes.LUTRAM
        DSPCells    = $classes.DSP
    }
}

$total = [pscustomobject]@{
    Module       = 'SUBSYSTEM TOTAL'
    LUTCells     = ($rows | Measure-Object -Property LUTCells -Sum).Sum
    ALUCells     = ($rows | Measure-Object -Property ALUCells -Sum).Sum
    SliceCells   = ($rows | Measure-Object -Property SliceCells -Sum).Sum
    FFCells      = ($rows | Measure-Object -Property FFCells -Sum).Sum
    BRAMBlocks   = ($rows | Measure-Object -Property BRAMBlocks -Sum).Sum
    LUTRAMCells  = ($rows | Measure-Object -Property LUTRAMCells -Sum).Sum
    DSPCells     = ($rows | Measure-Object -Property DSPCells -Sum).Sum
}

$rows + $total | Format-Table -AutoSize

[PSCustomObject]@{
    SubsystemLUTCells      = $total.LUTCells
    SubsystemALUCells      = $total.ALUCells
    SubsystemSliceCells    = $total.SliceCells
    SubsystemFFCells       = $total.FFCells
    SubsystemBRAMBlocks    = $total.BRAMBlocks
    SubsystemLUTRAMCells   = $total.LUTRAMCells
    SubsystemDSPCells      = $total.DSPCells
    ArrayLUTCells          = $rows[0].LUTCells
    ArraySliceCells        = $rows[0].SliceCells
    ArrayBRAMBlocks        = $rows[0].BRAMBlocks
    Under15kLUT            = ($total.LUTCells -le 15000)
    Under15kLUTPlusALU     = ($total.SliceCells -le 15000)
    Under4DSP              = ($total.DSPCells -le 4)
}
