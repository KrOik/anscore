$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\crypto\hybrid_lattice_ntt'
$jsonPath = Join-Path $project 'build_oss\top.json'
$pnrLogPath = Join-Path $project 'build_oss\nextpnr.log'
$outputPath = Join-Path $project 'build_oss\metrics.json'

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
$lutram = 0

foreach ($entry in $counts.GetEnumerator()) {
    if ($entry.Key -match 'LUT' -and $entry.Key -notmatch '^RAM16') {
        $lut += $entry.Value
    }
    if ($entry.Key -match 'DFF|DFFE|DFFC|DFFR|DFFS') {
        $ff += $entry.Value
    }
    if ($entry.Key -match 'DSP|MULT|MULTALU|PADD') {
        $dsp += $entry.Value
    }
    # RAM16SDPx is slice LUTRAM. Counting it as block RAM inflated bram_class_cells
    # by 72 for a netlist whose real block-RAM usage is 2.
    if ($entry.Key -match '^RAM16') {
        $lutram += $entry.Value
    } elseif ($entry.Key -match 'BSRAM|SDP|SPX9|DPB|^SP$') {
        $bram += $entry.Value
    }
}

$fmaxMHz = $null
$deviceUtil = @{}
if (Test-Path $pnrLogPath) {
    $pnrText = Get-Content -Path $pnrLogPath -Raw
    $matches = [regex]::Matches($pnrText, "Max frequency for clock '[^']+':\s+([0-9.]+)\s+MHz")
    if ($matches.Count -gt 0) {
        $fmaxMHz = [double]$matches[$matches.Count - 1].Groups[1].Value
    }
    # nextpnr reports what actually landed in slices; the yosys JSON cell-type sums
    # above count logic cells, not packed LUT4 sites, and the two differ by tens of
    # percent once LUT5-LUT8 wide muxes and LUTRAM are expanded.
    foreach ($row in [regex]::Matches($pnrText, 'Info:\s+(\w+):\s+(\d+)/\s*(\d+)\s+(\d+)%')) {
        if (-not $deviceUtil.ContainsKey($row.Groups[1].Value)) {
            $deviceUtil[$row.Groups[1].Value] = [ordered]@{
                used      = [int]$row.Groups[2].Value
                available = [int]$row.Groups[3].Value
                percent   = [int]$row.Groups[4].Value
            }
        }
    }
}

function Get-DeviceRow {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($deviceUtil.ContainsKey($Name)) {
        return [ordered]@{
            used      = $deviceUtil[$Name].used
            available = $deviceUtil[$Name].available
            percent   = $deviceUtil[$Name].percent
        }
    }
    return $null
}

$lut4Row  = Get-DeviceRow 'LUT4'
$aluRow   = Get-DeviceRow 'ALU'
$dffRow   = Get-DeviceRow 'DFF'
$bsramRow = Get-DeviceRow 'BSRAM'
$lutramRow = Get-DeviceRow 'RAM16SDP4'

# Read the systolic switch-over numbers from the benches that measure them rather
# than restating them here, so a regression in the chain cannot survive an edit to
# this file.
function Get-SystolicVerdictEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Top,
        [Parameter(Mandatory = $true)][string]$VvpPath
    )
    if (!(Test-Path $VvpPath)) {
        throw "Simulation artifact not found: $VvpPath. Run scripts/test_hybrid_lattice_ntt_sim.ps1 first."
    }
    $output = (& vvp $VvpPath 2>&1) | Out-String
    $verdictLine = ($output -split "\r?\n" |
        Where-Object { $_ -match ('^' + [regex]::Escape($Top) + ' (PASS|FAIL)') } |
        Select-Object -Last 1)
    if (!$verdictLine) {
        throw "$Top produced no verdict line. Last output line: $(($output -split "\r?\n" | Where-Object { $_ } | Select-Object -Last 1))"
    }
    $fields = @{}
    foreach ($field in [regex]::Matches($verdictLine, '(\w+)=([^\s]+)')) {
        $fields[$field.Groups[1].Value] = $field.Groups[2].Value
    }
    [PSCustomObject]@{
        Top    = $Top
        Verdict = ($verdictLine -split '\s+')[1]
        Fields = $fields
    }
}

function To-Int {
    param([string]$Value)
    $digits = ([regex]::Match($Value, '^[0-9]+')).Value
    if ($digits -eq '') {
        throw "Expected a leading integer in '$Value'."
    }
    return [int]$digits
}

$chainVvp = Join-Path $project 'sim\tb_ntt256_systolic_zero_switch_chain.vvp'
$chainedVvp = Join-Path $project 'sim\tb_ntt256_systolic_chained_roundtrip.vvp'

$zeroSwitchChain = Get-SystolicVerdictEvidence -Top 'tb_ntt256_systolic_zero_switch_chain' -VvpPath $chainVvp
if ($zeroSwitchChain.Verdict -ne 'PASS') {
    throw "tb_ntt256_systolic_zero_switch_chain verdict is $($zeroSwitchChain.Verdict); metrics refuse to publish a zero-switch claim from a failing bench."
}
$chainedRoundtrip = Get-SystolicVerdictEvidence -Top 'tb_ntt256_systolic_chained_roundtrip' -VvpPath $chainedVvp
if ($chainedRoundtrip.Verdict -ne 'PASS') {
    throw "tb_ntt256_systolic_chained_roundtrip verdict is $($chainedRoundtrip.Verdict); metrics refuse to publish a chained-data claim from a failing bench."
}

$measuredZeroSwitch = [ordered]@{
    verdict = $zeroSwitchChain.Verdict
    ordered_adjacent_pairs = To-Int $zeroSwitchChain.Fields['pairs']
    descriptor_bursts = To-Int $zeroSwitchChain.Fields['streams']
    max_handoff_edges = To-Int $zeroSwitchChain.Fields['max_handoff']
    dead_cycles = To-Int $zeroSwitchChain.Fields['dead_cycles']
    underrun_cycles = To-Int $zeroSwitchChain.Fields['underrun']
    negative_checks = To-Int $zeroSwitchChain.Fields['negative']
    source = 'vvp sim/tb_ntt256_systolic_zero_switch_chain.vvp'
}
$measuredChainedRoundtrip = [ordered]@{
    verdict = $chainedRoundtrip.Verdict
    chains = To-Int $chainedRoundtrip.Fields['chains']
    ops_per_chain = To-Int $chainedRoundtrip.Fields['ops_per_chain']
    self_init_cycles_saved_per_op = To-Int $chainedRoundtrip.Fields['saved']
    max_handoff_edges = To-Int $chainedRoundtrip.Fields['handoff']
    source = 'vvp sim/tb_ntt256_systolic_chained_roundtrip.vvp'
}

$metrics = [ordered]@{
    project = 'hybrid_lattice_ntt_20k'
    scope = 'operation-scheduled dual-bank two-lane 256-point dual-mode ML-KEM/ML-DSA NTT/INTT transform-slot engine with bounded KEM_FLOW/DSA_FLOW scheduler skeleton, board-visible OPS4/FLOW reports, integrated zero-bubble systolic issue/control-plane and bounded arithmetic-lane self-tests, plus strict simulation and board-visible monitor evidence for a full 3072-slot systolic stream'
    generated_at = (Get-Date).ToString('s')
    resource = [ordered]@{
        lut_class_cells = $lut
        ff_class_cells = $ff
        dsp_class_cells = $dsp
        bram_class_cells = $bram
        lutram_class_cells = $lutram
        under_15k_lut = ($lut -le 15000)
        under_4_dsp = ($dsp -le 4)
        cell_class_note = 'lut_class_cells counts yosys logic cells of LUT type; it is not the number of LUT4 sites the place-and-router packs, and wide MUX2_LUT5-LUT8 folding plus LUTRAM make the packed figure higher. Read packed_device_utilization for the device-pressure verdict against the 15K target.'
        packed_device_utilization = [ordered]@{
            lut4        = $lut4Row
            alu         = $aluRow
            dff         = $dffRow
            bsram       = $bsramRow
            lutram      = $lutramRow
            under_15k_lut4 = ($null -ne $lut4Row -and $lut4Row.used -le 15000)
            source      = 'build_oss/nextpnr.log utilization table'
        }
    }
    timing = [ordered]@{
        fmax_mhz = $fmaxMHz
        target_clock_mhz = 12
    }
    function = [ordered]@{
        transform_points = 256
        modes = @('ML-KEM q=3329', 'ML-DSA q=8380417')
        operation_interface = 'hybrid_lattice_op_scheduler accepts KEM_NTT, DSA_NTT, KEM_INTT, DSA_INTT, bounded KEM_FLOW, and bounded DSA_FLOW op codes over the shared core; HYBRID_RUN and broader future flow op codes remain explicit done/error responses'
        twiddle_schedule = 'forward NTT uses precomputed flattened table indexed by stage-local m-1+j; INTT uses inverse GS scheduling with inverse twiddles derived from the same root table and final n^-1 scaling'
        selftest_cycles = 38810
        kem_digest = '1E664367'
        dsa_digest = '7FC8E2FC'
        kem_intt_digest = 'B88A6C64'
        dsa_intt_digest = 'D23ECEF9'
        kem_flow_digest = 'EDAA6354'
        dsa_flow_digest = 'E9B06052'
        ops4_digest = '444A5032'
        selftest_digest = '2F9C94AD'
        board_uart_report = 'N256 PASS D=2F9C94AD C=0000979A'
        board_uart_ops_report = 'OPS4 PASS D=444A5032'
        board_uart_flow_report = 'FLOW PASS K=EDAA6354 D=E9B06052'
        board_uart_pipe_report = 'PIPE PASS B=0000 P=FFFF'
        board_uart_syst_report = 'SYST PASS D=EF556C7C B=0000 P=FFFF'
        board_uart_full_report = 'FULL PASS D=C4090C17 B=0000 O=0C00 L=0017'
        systolic_issue_sequence = '17 descriptors covering all 16 ordered adjacent pairs over {KEM_NTT, DSA_NTT, KEM_INTT, DSA_INTT}: KEM_NTT -> KEM_NTT -> DSA_NTT -> KEM_NTT -> KEM_INTT -> KEM_NTT -> DSA_INTT -> DSA_NTT -> DSA_NTT -> KEM_INTT -> DSA_NTT -> DSA_INTT -> KEM_INTT -> KEM_INTT -> DSA_INTT -> DSA_INTT -> KEM_NTT'
        systolic_issue_interval_cycles = 1
        systolic_fill_latency_cycles = 8
        systolic_invalid_bubbles_between_mixed_ops = 0
        systolic_ordered_adjacent_pair_coverage = '16/16'
        systolic_bank_conflict_checks = 2048
        systolic_arith_latency_cycles = 23
        systolic_arith_issue_interval_cycles = 1
        systolic_arith_invalid_bubbles_between_mixed_ops = 0
        systolic_arith_ordered_adjacent_pair_coverage = '16/16'
        systolic_arith_exact_butterfly_checks = 17
        systolic_arith_digest = 'EF556C7C'
        systolic_arith_note = 'The arithmetic lane is a bounded throughput-one butterfly stream prototype. It carries KEM/DSA modulus choice, NTT/INTT direction, twiddle, and coefficient-pair data through a 23-stage shift-add modular multiply pipeline and checks exact modular forward/inverse butterfly outputs for 17 mixed descriptors.'
        systolic_full_stream_sequence = 'KEM_NTT -> DSA_INTT -> KEM_INTT'
        systolic_full_stream_issue_slots = 3072
        systolic_full_stream_outputs = 3072
        systolic_full_stream_slots_per_operation = 1024
        systolic_full_stream_latency_cycles = 23
        systolic_full_stream_issue_interval_cycles = 1
        systolic_full_stream_invalid_output_bubbles = 0
        systolic_full_stream_bank_conflict_checks = 3072
        systolic_full_stream_transition_mask = 'C409'
        systolic_full_stream_digest = '3CC0FDBF'
        systolic_full_stream_monitor_digest = 'C4090C17'
        systolic_full_stream_note = 'Strict simulation-only full-stream regression around ntt256_systolic_arith_pipe enumerates all 8 x 128 butterfly slots for KEM_NTT, DSA_INTT, and KEM_INTT, checks full metadata alignment, bank mapper consistency, ordered outputs, and exact modular butterfly outputs against a testbench reference. The board-visible FULL monitor is a reduced-cost synthesized proof of the same 3072 issue/output slots, zero output bubbles, 23-cycle first latency, 3072 bank checks, and transition mask C409; it intentionally avoids instantiating a second arithmetic pipe.'
        zero_switch_chain = $measuredZeroSwitch
        chained_roundtrip = $measuredChainedRoundtrip
        zero_switch_status = 'Simulation-only and re-measured at export time: descriptor sequencer -> hybrid_descriptor_bridge -> ntt256_systolic_state_array accepts each chained operation on the clock edge after the previous done, with zero dead cycles and zero bridge underruns. Neither the bridge nor the state array is instantiated in top.v yet, so no board report carries this evidence.'
        architecture_note = 'The full 256-point numerical transform path remains the validated dual-bank two-lane core. The board-visible systolic issue/control-plane RTL proves one-operation-per-cycle descriptor acceptance, fixed 8-stage fill latency, KEM/DSA parameter steering, NTT/INTT direction metadata reversal, and conflict-free per-stage bank mapping for all 128 butterflies across 8 stages in both directions. The bounded arithmetic lane proves real modular butterfly data can move through a zero-bubble systolic stream. The strict full-stream simulation proves every butterfly slot for three adjacent full transform operations can pass through that lane with no bubbles and exact modular butterfly outputs. The board FULL report preserves the no-bubble, latency, count, transition, and bank-check evidence in hardware, but coefficient-memory state update equivalence remains a later gate.'
    }
    security = [ordered]@{
        masking_order = 0
        control_flow_randomization = $false
        formal_glitch_proof = 'not_started'
        tvla = 'not_run'
        security_gate = 'fail_unprotected_baseline'
    }
}

$metrics | ConvertTo-Json -Depth 8 | Set-Content -Path $outputPath -Encoding ASCII
Get-Content -Path $outputPath
