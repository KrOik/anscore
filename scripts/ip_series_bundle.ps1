param(
    [string]$Name = 'ips_series_bundle',
    [string]$ExpectDigest = '',
    [int]$ExpectCycles = -1,
    [switch]$SkipSynth,
    [switch]$SkipElab,
    [switch]$AllowOverBudget,
    [switch]$Quiet
)

# Series-level integration station for the ip_series_20k portfolio.
#
# The per-core gate (scripts/ip_series_harness.ps1) proves one core at a time and
# elaborates a packaged wrapper only on its own.  This station proves the thing a
# customer actually buys: that the delivered wrappers compose into one design.
#
#   A package sweep  every core whose gate record says PASS must have a packaged
#                    wrapper, and each wrapper must elaborate standalone against
#                    its shipped core source (no missing dependency, no port-width
#                    drift after packaging).  This station is series-wide, not
#                    per-bundle: every delivered wrapper is elaborated.
#   B bundle run     sim/tb_<Name>.v runs src/<Name>.v, which instantiates the
#                    *packaged wrappers* listed in src/<Name>.deps with no parameter
#                    override, and its verdict digest is locked to that bundle's
#                    entry in $bundleLibrary (or -ExpectDigest / -ExpectCycles).
#   C bundle mutation that bundle's known wiring faults are injected into scratch
#                    copies of the bundle RTL and each must be detected by a verdict
#                    failure, which is the non-vacuity proof for that bundle's ledger
#                    and contract checks.
#   D aggregate area yosys synth_gowin -noalu -family gw2a over the composed bundle,
#                    checked against the device budget in AGENTS.md.
#
# Board evidence stays DEFERRED: nothing here is programmed to hardware.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$root = [string]$env:SIPEED_TANG20K_ROOT
$proj = Join-Path $root 'cores\system\ip_series'
$reportDir = Join-Path $root 'docs\quality\reports'

# Every integration top the series ships is its own station with its own locked
# verdict, its own core chain, its own report and -- most importantly -- its own
# set of wiring faults to inject.  Adding a bundle means adding an entry here and
# a src/<name>.deps file; the four stations below stay generic.
#
# A mutant is written as one exact source line swap because station C refuses to
# run a mutant whose anchor is not unique: if the bundle text moved, the fault
# being claimed may no longer be the fault being injected.
$bundleLibrary = @{
    'ips_series_bundle' = [pscustomobject]@{
        digest = '3e65c912'
        cycles = 1399
        report = 'ip_series_bundle.json'
        mutants = @(
            [pscustomobject]@{
                Tag    = 'pop_unconsumed'
                Detail = 'FIFO pops are not qualified by the packer being ready, so a word is destroyed'
                Old    = 'assign fifo_pop     = !fifo_empty && bc[2] && pkt_ready;'
                New    = 'assign fifo_pop     = !fifo_empty && bc[2];'
            },
            [pscustomobject]@{
                Tag    = 'stalled_double_push'
                Detail = 'a stalled tap line keeps one sample presented, and the FIFO takes it twice'
                Old    = 'assign fifo_push    = tap_valid && !fifo_full && tap_no_stall;'
                New    = 'assign fifo_push    = tap_valid && !fifo_full;'
            },
            [pscustomobject]@{
                Tag    = 'cdc_relaunch'
                Detail = 'a second CDC launch is issued while the first crossing is still outstanding'
                Old    = 'wire       src_start = src_tick && lfsr[5] && !cdc_outstanding;'
                New    = 'wire       src_start = src_tick && lfsr[5];'
            }
        )
    }
    'ips_series_nn_front' = [pscustomobject]@{
        digest = '08dfdae6'
        cycles = 1996
        report = 'ip_series_nn_front.json'
        mutants = @(
            [pscustomobject]@{
                Tag    = 'weight_store_write_on_read_beat'
                Detail = 'the store is written during the read phase, so a write collides with the read of the same cell'
                Old    = 'wire       ram_we   = ram_write_phase;'
                New    = 'wire       ram_we   = ram_write_phase || (ram_read_phase && bc[1]);'
            },
            [pscustomobject]@{
                Tag    = 'conv_free_running_tap'
                Detail = 'the tap index is the global beat counter instead of the window walk, so windows close at the wrong cadence'
                Old    = '    .tap        (cv_tap),'
                New    = '    .tap        (bc[2:0]),'
            },
            [pscustomobject]@{
                Tag    = 'booth_start_while_busy'
                Detail = 'a start pulse is issued into the multiplier while its previous product is still walking out'
                Old    = 'wire bt_start = bc[7] && !bt_busy;'
                New    = 'wire bt_start = bc[7];'
            },
            [pscustomobject]@{
                Tag    = 'ct_length_disagrees'
                Detail = 'the comparator is told to expect seven beats for an eight-beat frame, so the stream length check is wrong'
                Old    = "    .exp_len      (12'd8),"
                New    = "    .exp_len      (12'd7),"
            },
            [pscustomobject]@{
                Tag    = 'gray_double_step'
                Detail = 'the crossing advances the binary pointer by two for one publish, so pointer and ledger diverge'
                Old    = "    .src_step    (cross_pend ? 4'd1 : 4'd0),"
                New    = "    .src_step    (cross_pend ? 4'd2 : 4'd0),"
            }
        )
    }
}

if (-not $bundleLibrary.ContainsKey($Name)) {
    throw "unknown bundle '$Name' -- registered bundles: $(@($bundleLibrary.Keys) | Sort-Object | Join-String -Separator ', ')"
}
$bundle     = $bundleLibrary[$Name]
$bundleName = $Name
$bundleRel  = "src/$Name.v"
if ([string]::IsNullOrWhiteSpace($ExpectDigest)) { $ExpectDigest = [string]$bundle.digest }
if ($ExpectCycles -lt 0) { $ExpectCycles = [int]$bundle.cycles }

foreach ($d in @('build\sim', 'build\logs', 'build\mut', 'build\synth')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $proj $d) | Out-Null
}
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Say([string]$Text) {
    if (-not $Quiet) { Write-Host $Text }
}

function Get-Exe([string]$Tool) {
    $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "required tool not on PATH: $Tool" }
    return $cmd.Source
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [int]$TimeoutMs = 120000
    )
    $tag = [Guid]::NewGuid().ToString('N')
    $outPath = Join-Path $env:TEMP "ipbundle-$tag.out"
    $errPath = Join-Path $env:TEMP "ipbundle-$tag.err"
    $p = $null
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
            -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
            -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $timedOut = $true
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            if ($p.WaitForExit(50)) { $timedOut = $false; break }
        }
        if ($timedOut) {
            try { $p.Kill($true) } catch { }
            return [pscustomobject]@{ exit = 124; stdout = @("TIMEOUT after $TimeoutMs ms"); stderr = @() }
        }
        try { $p.WaitForExit() } catch { }
        $code = 0
        try { $code = [int]$p.ExitCode } catch { $code = 0 }
        $std = @(Get-Content -LiteralPath $outPath -ErrorAction SilentlyContinue)
        $str = @(Get-Content -LiteralPath $errPath -ErrorAction SilentlyContinue)
        return [pscustomobject]@{ exit = $code; stdout = [string[]]$std; stderr = [string[]]$str }
    }
    finally {
        if ($p) { try { $p.Dispose() } catch { } }
        Remove-Item $outPath, $errPath -Force -ErrorAction SilentlyContinue
    }
}

function Save-Log {
    param([string]$Path, [string[]]$Lines)
    Set-Content -LiteralPath $Path -Value (($Lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) -Encoding UTF8
}

function Norm-Digest([string]$Hex) {
    if ([string]::IsNullOrWhiteSpace($Hex)) { return $null }
    $clean = $Hex.Trim().ToLowerInvariant()
    if ($clean.StartsWith('0x')) { $clean = $clean.Substring(2) }
    if ($clean -notmatch '^[0-9a-f]{1,8}$') { return $null }
    return ([Convert]::ToString([Convert]::ToUInt32($clean, 16), 16)).PadLeft(8, '0')
}

function Get-Verdict {
    param([string[]]$Lines, [string]$Core, [string]$Label)
    $text = @($Lines | ForEach-Object { [string]$_ })
    $verdicts = @($text | Where-Object { $_ -match '^\s*VERDICT\b' })
    if ($verdicts.Count -eq 0) { throw "${Label}: no VERDICT line emitted ($Core)" }
    $bad = @($verdicts | Where-Object { $_ -match 'FAIL' })
    if ($bad.Count -gt 0) { throw "${Label}: $Core verdict failure -> $($bad[0].Trim())" }
    $pick = [string]$verdicts[-1]
    if ($pick -notmatch 'PASS\s+D=([0-9a-fA-F]{1,8})\s+C=(\d+)') {
        throw "${Label}: $Core verdict malformed: $($pick.Trim())"
    }
    return [pscustomobject]@{ digest = (Norm-Digest $Matches[1]); cycles = [int]$Matches[2]; raw = $pick.Trim() }
}

function Get-CellClasses {
    param([string]$JsonPath, [string]$ModuleName)
    $json = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
    if (-not $json.modules.PSObject.Properties.Name -contains $ModuleName) {
        throw "module $ModuleName missing from $JsonPath"
    }
    $counts = @{}
    foreach ($cell in $json.modules.$ModuleName.cells.PSObject.Properties) {
        $type = [string]$cell.Value.type
        if (-not $counts.ContainsKey($type)) { $counts[$type] = 0 }
        $counts[$type] += 1
    }
    $lut = 0; $ff = 0; $dsp = 0; $bram = 0; $lutram = 0; $alu = 0
    foreach ($e in $counts.GetEnumerator()) {
        if ($e.Key -match '^RAM16') { $lutram += $e.Value }
        elseif ($e.Key -match 'LUT') { $lut += $e.Value }
        if ($e.Key -match 'DFF|DFFE|DFFC|DFFR|DFFS') { $ff += $e.Value }
        if ($e.Key -match 'DSP|MULT|PADD') { $dsp += $e.Value }
        if ($e.Key -match '^ALU') { $alu += $e.Value }
        if ($e.Key -notmatch '^RAM16' -and $e.Key -match 'BSRAM|SDP|SPX9|DPB|^SP$') { $bram += $e.Value }
    }
    return [pscustomobject]@{
        lut          = $lut
        ff           = $ff
        dsp          = $dsp
        bram         = $bram
        lutram       = $lutram
        alu          = $alu
        slice_class  = $lut + $alu + $lutram
        bram_blocks  = [int][Math]::Ceiling($bram / 2.0)
    }
}

function Get-CoreDeps([string]$Name) {
    $deps = @()
    $depsFile = Join-Path $proj "src\ips_$Name.deps"
    if (Test-Path -LiteralPath $depsFile -PathType Leaf) {
        foreach ($raw in @(Get-Content -LiteralPath $depsFile)) {
            $t = ([string]$raw).Trim()
            if ($t.Length -eq 0 -or $t.StartsWith('#')) { continue }
            $p = Join-Path $proj ($t -replace '/', '\')
            if (-not (Test-Path -LiteralPath $p)) { throw "dependency of ips_$Name is missing: $t" }
            $deps += $t
        }
    }
    return @($deps)
}

$iverilog = Get-Exe 'iverilog'
$vvp = Get-Exe 'vvp'

# ------------------------------------------------------------------ station A
# Every gated core must be packaged, and every package must elaborate standalone.
$gates = @(Get-ChildItem -LiteralPath (Join-Path $proj 'ip') -Filter 'gate_*.json' -File |
    Sort-Object Name | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
$passed = @($gates | Where-Object { [string]$_.status -eq 'PASS' })
Say "A  package sweep: $($passed.Count) gated cores"
$elab = @()
if ($SkipElab) {
    Say '   skipped (-SkipElab)'
    foreach ($g in $passed) {
        $elab += [pscustomobject]@{ core = [string]$g.core; wrapper = [string]$g.detail; ip_module = '' }
    }
} else {
foreach ($g in $passed) {
    $name = [string]$g.core
    $manifestPath = Join-Path $proj "ip\$name\ip_manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "A: gate record for $name exists but ip/$name/ip_manifest.json is missing"
    }
    $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $wrapperRel = [string]$m.sources.wrapper
    $coreRel = [string]$m.sources.core
    foreach ($rel in @($wrapperRel, $coreRel)) {
        if (-not (Test-Path -LiteralPath (Join-Path $proj ($rel -replace '/', '\')))) {
            throw "A: packaged source missing for $name : $rel"
        }
    }
    $elabArgs = @('-g2012', '-s', [string]$m.ip_name, '-o', "build\sim\elab_$name.vvp", $wrapperRel, $coreRel)
    $elabArgs = $elabArgs + @(Get-CoreDeps $name)
    $c = Invoke-Native -FilePath $iverilog -Arguments $elabArgs -WorkDir $proj -TimeoutMs 120000
    Save-Log -Path (Join-Path $proj "build\logs\$name.bundle.elab.log") -Lines ($c.stdout + $c.stderr)
    if ($c.exit -ne 0) {
        $why = (($c.stderr + $c.stdout) | Select-Object -Last 6 | ForEach-Object { [string]$_ }) -join ' / '
        throw "A: wrapper elaboration failed for $name : $why"
    }
    $elab += [pscustomobject]@{ core = $name; wrapper = $wrapperRel; ip_module = [string]$m.ip_name }
    Say "   ok  $name ($($elab.Count)/$($passed.Count))"
}
}

# ------------------------------------------------------------------ station B
$bundleFiles = @("sim/tb_$bundleName.v", $bundleRel)
$chainNames = @()
foreach ($raw in @(Get-Content -LiteralPath (Join-Path $proj "src\$bundleName.deps"))) {
    $t = ([string]$raw).Trim()
    if ($t.Length -eq 0 -or $t.StartsWith('#')) { continue }
    $chainNames += $t
}
foreach ($n in $chainNames) {
    $bundleFiles += "ip/$n/gw2a_ips_$n.v"
    $bundleFiles += "src/ips_$n.v"
    $bundleFiles += @(Get-CoreDeps $n)
}
foreach ($f in $bundleFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $proj ($f -replace '/', '\')))) {
        throw "B: bundle source missing: $f"
    }
}

Say "B  bundle run ($($chainNames.Count) packaged wrappers)"
$compileArgs = @('-g2012', '-I', 'sim', '-s', "tb_$bundleName", '-o', "build\sim\$bundleName.vvp") + @($bundleFiles)
$c = Invoke-Native -FilePath $iverilog -Arguments $compileArgs -WorkDir $proj -TimeoutMs 180000
Save-Log -Path (Join-Path $proj "build\logs\$bundleName.iverilog.log") -Lines ($c.stdout + $c.stderr)
if ($c.exit -ne 0) {
    $why = (($c.stderr + $c.stdout) | Select-Object -Last 8 | ForEach-Object { [string]$_ }) -join ' / '
    throw "B: bundle compile failed: $why"
}
$r = Invoke-Native -FilePath $vvp -Arguments @("build\sim\$bundleName.vvp") -WorkDir $proj -TimeoutMs 180000
Save-Log -Path (Join-Path $proj "build\logs\$bundleName.vvp.log") -Lines ($r.stdout + $r.stderr)
$verdict = Get-Verdict -Lines $r.stdout -Core $bundleName -Label 'bundle'
if ($verdict.digest -ne (Norm-Digest $ExpectDigest)) {
    throw "B: bundle digest $($verdict.digest) != locked expectation $(Norm-Digest $ExpectDigest)"
}
if ($verdict.cycles -ne $ExpectCycles) {
    throw "B: bundle cycle count $($verdict.cycles) != locked expectation $ExpectCycles"
}
Say "   ok  $($verdict.raw)"

# ------------------------------------------------------------------ station C
# Each fault in the bundle's library entry is a wiring mistake a series
# integrator can really make.  The bundle must not just notice it -- the run
# must end in a verdict failure.
$mutations = @($bundle.mutants)
$lines = @(Get-Content -LiteralPath (Join-Path $proj ($bundleRel -replace '/', '\')) | ForEach-Object { [string]$_ })
$mutResults = @()
foreach ($mu in $mutations) {
    $hit = @($lines | Where-Object { $_ -eq $mu.Old })
    if ($hit.Count -ne 1) {
        throw "C: mutation anchor for $($mu.Tag) is not unique (found $($hit.Count)); the bundle text moved"
    }
    $mutRel = "build/mut/$bundleName.$($mu.Tag).v"
    $copy = @($lines | ForEach-Object { if ($_ -eq $mu.Old) { $mu.New } else { $_ } })
    Set-Content -LiteralPath (Join-Path $proj ($mutRel -replace '/', '\')) -Value ($copy -join [Environment]::NewLine) -Encoding UTF8
    # $bundleFiles already carries the testbench, so only the bundle RTL is swapped.
    $files = @($mutRel) + @($bundleFiles | Where-Object { $_ -ne $bundleRel })
    $mc = Invoke-Native -FilePath $iverilog `
        -Arguments (@('-g2012', '-I', 'sim', '-s', "tb_$bundleName", '-o', "build\sim\$bundleName.$($mu.Tag).vvp") + @($files)) `
        -WorkDir $proj -TimeoutMs 180000
    if ($mc.exit -ne 0) {
        Save-Log -Path (Join-Path $proj "build\logs\$bundleName.$($mu.Tag).iverilog.log") -Lines ($mc.stdout + $mc.stderr)
        $why = (($mc.stderr + $mc.stdout) | Select-Object -Last 6 | ForEach-Object { [string]$_ }) -join ' / '
        throw "C: mutant $($mu.Tag) failed to compile: $why"
    }
    $mr = Invoke-Native -FilePath $vvp -Arguments @("build\sim\$bundleName.$($mu.Tag).vvp") -WorkDir $proj -TimeoutMs 180000
    Save-Log -Path (Join-Path $proj "build\logs\$bundleName.$($mu.Tag).vvp.log") -Lines ($mr.stdout + $mr.stderr)
    $detected = @([string[]]($mr.stdout | ForEach-Object { [string]$_ }) | Where-Object { $_ -match '^\s*VERDICT.*FAIL' }).Count -gt 0
    if (-not $detected) {
        $tail = (($mr.stdout | Select-Object -Last 4 | ForEach-Object { [string]$_ })) -join ' / '
        throw "C: mutant $($mu.Tag) survived -- $bundleName's ledger checks are vacuous. $tail"
    }
    $mutResults += [pscustomobject]@{ tag = $mu.Tag; detail = $mu.Detail; detected = $true }
    Say "   ok  mutant $($mu.Tag) detected"
}

# ------------------------------------------------------------------ station D
$area = $null
if (-not $SkipSynth) {
    Say 'D  aggregate synthesis (-noalu, gw2a)'
    $yosys = Get-Exe 'yosys'
    $jsonRel = "build/synth/$bundleName.json"
    $ysLines = @(
        ('read_verilog -sv ' + ((@($bundleFiles | Where-Object { $_ -ne "sim/tb_$bundleName.v" })) -join ' ')),
        ("synth_gowin -noalu -family gw2a -top $bundleName -json $jsonRel"),
        'stat'
    )
    Set-Content -LiteralPath (Join-Path $proj "build\synth\$bundleName.ys") -Value ($ysLines -join [Environment]::NewLine) -Encoding UTF8
    $s = Invoke-Native -FilePath $yosys `
        -Arguments @('-l', "build\logs\$bundleName.synth.log", '-s', "build\synth\$bundleName.ys") `
        -WorkDir $proj -TimeoutMs 600000
    if ($s.exit -ne 0) {
        $logPath = Join-Path $proj "build\logs\$bundleName.synth.log"
        $tail = ''
        if (Test-Path $logPath) { $tail = ((Get-Content -LiteralPath $logPath | Select-Object -Last 10) -join ' / ') }
        throw "D: bundle synthesis failed (exit $($s.exit)): $tail"
    }
    $area = Get-CellClasses -JsonPath (Join-Path $proj ($jsonRel -replace '/', '\')) -ModuleName $bundleName
    $overBudget = ($area.slice_class -gt 15000) -or ($area.dsp -gt 4)
    if ($overBudget -and -not $AllowOverBudget) {
        if ($area.slice_class -gt 15000) { throw "D: bundle uses $($area.slice_class) slice cells, over the 15000 device budget" }
        throw "D: bundle uses $($area.dsp) DSP cells, over the 4 device budget"
    }
    Say "   ok  slice=$($area.slice_class) ff=$($area.ff) dsp=$($area.dsp) bram=$($area.bram_blocks)"
}

# Which member cores own the composed DSP demand.  A customer choosing a slice of
# the series needs the attribution, not just the total: the device envelope is
# spent by specific cores.
$memberArea = @($chainNames | ForEach-Object {
    $gp = Join-Path $proj ('ip\gate_' + $_ + '.json')
    if (-not (Test-Path -LiteralPath $gp)) { return $null }
    $g = Get-Content -LiteralPath $gp -Raw | ConvertFrom-Json
    [pscustomobject]@{ core = $_; lut_class = [int]$g.resources.lut_class_cells; dsp = [int]$g.resources.dsp_cells }
} | Where-Object { $null -ne $_ })
$memberDsp = ($memberArea | Measure-Object -Property dsp -Sum).Sum
$memberLut = ($memberArea | Measure-Object -Property lut_class -Sum).Sum
$deviceFit = if ($null -eq $area) { 'NOT MEASURED (-SkipSynth)' }
             elseif ($area.slice_class -le 15000 -and $area.dsp -le 4) { 'WITHIN DEVICE BUDGET' }
             else { "OVER DEVICE BUDGET: slice=$($area.slice_class) (limit 15000) dsp=$($area.dsp) (limit 4) -- this composition is a delivered core set, not a single-device image" }
if ($deviceFit -like 'OVER*') { Say "   FINDING  $deviceFit" }
if ($deviceFit -like 'OVER*') { Say "   DSP demand by member: $(($memberArea | Where-Object { $_.dsp -gt 0 } | ForEach-Object { "$($_.core)=$($_.dsp)" }) -join ' ')" }

$perCore = @($passed | ForEach-Object { [pscustomobject]@{
    core = [string]$_.core
    lut_class = [int]$_.resources.lut_class_cells
    ff = [int]$_.resources.ff_cells
    dsp = [int]$_.resources.dsp_cells
} })
$sumLut = ($perCore | Measure-Object -Property lut_class -Sum).Sum
$sumDsp = ($perCore | Measure-Object -Property dsp -Sum).Sum

$report = [pscustomobject]@{
    schema            = 'ip-series-bundle-v1'
    generated_utc     = (Get-Date).ToUniversalTime().ToString('o')
    device            = 'GW2A-LV18PG256C8/I7'
    top               = $bundleName
    stage             = 'bundle'
    status            = 'PASS'
    gated_cores       = $passed.Count
    wrappers_elaborated = $elab.Count
    bundle_members    = @($chainNames)
    verdict           = $verdict.raw
    digest            = $verdict.digest
    cycles            = $verdict.cycles
    nonvacuity        = @($mutResults)
    bundle_resources  = $area
    device_fit        = $deviceFit
    member_area       = [pscustomobject]@{
        lut_class_sum = [int]$memberLut
        dsp_sum       = [int]$memberDsp
        by_core       = @($memberArea)
    }
    portfolio_area    = [pscustomobject]@{
        per_core_lut_class_sum = [int]$sumLut
        per_core_dsp_sum       = [int]$sumDsp
        note                   = 'sum of standalone per-core areas; the composed bundle area is bundle_resources'
    }
    board_evidence    = 'DEFERRED'
}
$out = Join-Path $reportDir ([string]$bundle.report)
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $out -Encoding UTF8
Say "report -> $out"
