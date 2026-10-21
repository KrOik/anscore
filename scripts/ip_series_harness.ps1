param(
    [Parameter(Position = 0)]
    [ValidateSet('scan', 'core', 'all', 'report')]
    [string]$Command = 'scan',
    [Parameter(Position = 1)]
    [string]$Name = '',
    [ValidateRange(1, 24)]
    [int]$Mutants = 6,
    [switch]$SkipSynth,
    [switch]$Quiet
)

# Production-line gate for the ip_series_20k portfolio.
#
# Every core listed in cores/system/ip_series/ip_series_spec.json must clear all
# six stations, or the gate fails closed for the whole series:
#   1 compile   iverilog -g2012 of tb + core + declared deps
#   2 sim       vvp run must print  VERDICT ips_<name> PASS D=<hex> C=<cycles>
#   3 golden    models/ips_<name>.py must print MODEL ips_<name> D=<hex> and that
#               digest must equal the RTL digest (docs/IP_CORE_SOP.md trap T1:
#               expectations may never be back-filled from simulation output)
#   4 mutation  numeric literals in the RTL are incremented one at a time in a
#               scratch copy; every mutant must be detected and at least two must
#               change the digest, which is the non-vacuity proof for the tb
#   5 synth     yosys synth_gowin -noalu -family gw2a, cell classes checked
#               against the spec's lut_max / dsp_max budget
#   6 package   ip/<name>/gw2a_ips_<name>.v wrapper + ip_manifest.json +
#               README.md, and the wrapper must elaborate standalone
#
# Board evidence stays DEFERRED for every series core until a real board run is
# recorded, the same contract scripts/harness.ps1 release-check enforces.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$root = [string]$env:SIPEED_TANG20K_ROOT
$proj = Join-Path $root 'cores\system\ip_series'
$specPath = Join-Path $proj 'ip_series_spec.json'
$reportDir = Join-Path $root 'docs\quality\reports'

foreach ($d in @('src', 'sim', 'models', 'tools', 'ip', 'build\sim', 'build\logs', 'build\mut', 'build\synth')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $proj $d) | Out-Null
}
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Get-Exe([string]$Tool) {
    $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "required tool not on PATH: $Tool" }
    return $cmd.Source
}

$pythonExe = $null
foreach ($candidate in @('python', 'python3', 'py')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { $pythonExe = $cmd.Source; break }
}
if (-not $pythonExe) { throw 'no python interpreter found for golden models' }

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [int]$TimeoutMs = 120000
    )
    $tag = [Guid]::NewGuid().ToString('N')
    $outPath = Join-Path $env:TEMP "ipseries-$tag.out"
    $errPath = Join-Path $env:TEMP "ipseries-$tag.err"
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
    if ($verdicts.Count -eq 0) { throw "${Label}: no VERDICT line emitted (core $Core)" }
    $bad = @($verdicts | Where-Object { $_ -match 'FAIL' })
    if ($bad.Count -gt 0) { throw "${Label}: $Core verdict failure -> $($bad[0].Trim())" }
    $pick = [string]$verdicts[-1]
    if ($pick -notmatch 'PASS\s+D=([0-9a-fA-F]{1,8})\s+C=(\d+)') {
        throw "${Label}: $Core verdict malformed, need 'PASS D=<hex> C=<cycles>': $($pick.Trim())"
    }
    $hex = $Matches[1]
    $cyc = $Matches[2]
    return [pscustomobject]@{ digest = (Norm-Digest $hex); cycles = [int]$cyc; raw = $pick.Trim() }
}

function Blank-Brackets([string]$Line) {
    $chars = $Line.ToCharArray()
    $depth = 0
    for ($i = 0; $i -lt $chars.Length; $i++) {
        if ($chars[$i] -eq '[') { $depth++; $chars[$i] = ' ' }
        elseif ($chars[$i] -eq ']') { if ($depth -gt 0) { $depth-- }; $chars[$i] = ' ' }
        elseif ($depth -gt 0) { $chars[$i] = ' ' }
    }
    return (-join $chars)
}

function Format-LiteralIncrement {
    param([string]$Width, [string]$Base, [string]$Value)
    $clean = $Value.Replace('_', '')
    if ($clean.Length -eq 0) { return $null }
    $radix = 0
    switch ($Base.ToLower()) {
        'd' { $radix = 10 }
        'h' { $radix = 16 }
        'b' { $radix = 2 }
        default { $radix = 0 }
    }
    if ($radix -eq 0) { return $null }
    try { $v = [Convert]::ToInt64($clean, $radix) } catch { return $null }
    $nv = $v + 1
    $s = ''
    switch ($radix) {
        10 { $s = $nv.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
        16 { $s = $nv.ToString('X', [System.Globalization.CultureInfo]::InvariantCulture) }
        2 { $s = [Convert]::ToString($nv, 2) }
    }
    if ($s.Length -lt $clean.Length) { $s = $s.PadLeft($clean.Length, '0') }
    return ($Width + "'" + $Base + $s)
}

function Get-MutationSites {
    param([string]$Path, [int]$Limit)
    $lines = @(Get-Content -LiteralPath $Path | ForEach-Object { [string]$_ })
    $sites = @()
    # Constants inside the asynchronous reset branch are deliberately not mutated:
    # every one of them is overwritten before the first observation window, so an
    # unchanged digest there is an equivalent mutant, not a vacuous testbench.
    $inReset = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($sites.Count -ge $Limit) { break }
        $line = $lines[$i]
        $trim = $line.Trim()
        if ($trim.Length -eq 0) { continue }
        if ($trim.StartsWith('//') -or $trim.StartsWith('*') -or $trim.StartsWith('`')) { continue }
        if (-not $inReset -and $trim -match '^if\s*\(\s*!\s*rst_n\s*\)') { $inReset = $true; continue }
        if ($inReset) {
            if ($trim -match '^end\s+else') { $inReset = $false }
            continue
        }
        $sized = @([regex]::Matches($line, "(\d+)'([hdbHDB])([0-9A-Fa-f_]+)"))
        $pickedSite = $null
        foreach ($m in $sized) {
            $mut = Format-LiteralIncrement $m.Groups[1].Value $m.Groups[2].Value $m.Groups[3].Value
            if ($null -eq $mut) { continue }
            $pickedSite = [pscustomobject]@{
                Line = $i; Col = [int]$m.Index; Old = [string]$m.Value; New = $mut; Kind = 'sized'
            }
            break
        }
        if ($null -eq $pickedSite -and $sized.Count -eq 0 -and ($line.Contains('=') -or $trim.StartsWith('parameter'))) {
            $body = Blank-Brackets $line
            $bare = @([regex]::Matches($body, "(?<![\w.'])\d+(?![\w.'])"))
            foreach ($m in $bare) {
                $v = [Convert]::ToInt64($m.Value, 10) + 1
                $pickedSite = [pscustomobject]@{
                    Line = $i; Col = [int]$m.Index; Old = [string]$m.Value; New = [string]$v; Kind = 'bare'
                }
                break
            }
        }
        if ($null -ne $pickedSite) { $sites += $pickedSite }
    }
    return @($sites)
}

function New-MutantFile {
    param([string[]]$Lines, [pscustomobject]$Site, [string]$OutPath)
    $copy = New-Object 'string[]' $Lines.Length
    [Array]::Copy($Lines, $copy, $Lines.Length)
    $line = $copy[$Site.Line]
    $copy[$Site.Line] = $line.Substring(0, $Site.Col) + $Site.New + $line.Substring($Site.Col + $Site.Old.Length)
    Set-Content -LiteralPath $OutPath -Value ($copy -join [Environment]::NewLine) -Encoding UTF8
}

function Invoke-CoreSim {
    param(
        [string]$Core,
        [string]$RtlRel,
        [string[]]$DepRels,
        [string]$Tag,
        [string]$VvpRel
    )
    $iverilog = Get-Exe 'iverilog'
    $vvp = Get-Exe 'vvp'
    $compileArgs = @('-g2012', '-I', 'sim', '-s', "tb_$Core", '-o', $VvpRel)
    $compileArgs = $compileArgs + @("sim/tb_$Core.v", $RtlRel) + @($DepRels)
    $c = Invoke-Native -FilePath $iverilog -Arguments $compileArgs -WorkDir $proj -TimeoutMs 120000
    Save-Log -Path (Join-Path $proj "build\logs\$Core.$Tag.iverilog.log") -Lines ($c.stdout + $c.stderr)
    if ($c.exit -ne 0) {
        $why = (($c.stderr + $c.stdout) | Select-Object -Last 6 | ForEach-Object { [string]$_ }) -join ' / '
        return [pscustomobject]@{ ok = $false; reason = 'compile failed'; detail = $why }
    }
    $r = Invoke-Native -FilePath $vvp -Arguments @($VvpRel) -WorkDir $proj -TimeoutMs 90000
    Save-Log -Path (Join-Path $proj "build\logs\$Core.$Tag.vvp.log") -Lines ($r.stdout + $r.stderr)
    if ($r.exit -ne 0) {
        $why = (($r.stdout + $r.stderr) | Select-Object -Last 6 | ForEach-Object { [string]$_ }) -join ' / '
        return [pscustomobject]@{ ok = $false; reason = "vvp exit $($r.exit)"; detail = $why }
    }
    try {
        $v = Get-Verdict -Lines $r.stdout -Core $Core -Label "sim[$Tag]"
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = $_.Exception.Message; detail = '' }
    }
    return [pscustomobject]@{ ok = $true; digest = $v.digest; cycles = $v.cycles; raw = $v.raw; reason = ''; detail = '' }
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
        bram_blocks  = [Math]::Ceiling($bram / 2.0)
    }
}

function Invoke-CoreSynth {
    param([string]$Core, [string[]]$RtlRels)
    $yosys = Get-Exe 'yosys'
    $ysPath = Join-Path $proj "build\synth\$Core.ys"
    $jsonRel = "build/synth/$Core.json"
    $top = "ips_$Core"
    $lines = @(
        ('read_verilog -sv ' + (@($RtlRels) -join ' ')),
        ("synth_gowin -noalu -family gw2a -top $top -json $jsonRel"),
        'stat'
    )
    Set-Content -LiteralPath $ysPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    $s = Invoke-Native -FilePath $yosys `
        -Arguments @('-l', "build\logs\$Core.synth.log", '-s', "build\synth\$Core.ys") `
        -WorkDir $proj -TimeoutMs 600000
    if ($s.exit -ne 0) {
        $logPath = Join-Path $proj "build\logs\$Core.synth.log"
        $tail = ''
        if (Test-Path $logPath) { $tail = ((Get-Content -LiteralPath $logPath | Select-Object -Last 10) -join ' / ') }
        throw "synthesis failed for $Core (exit $($s.exit)): $tail"
    }
    return Get-CellClasses -JsonPath (Join-Path $proj ("build\synth\$Core.json")) -ModuleName $top
}

function Invoke-Packaging {
    param(
        [string]$Core,
        $Entry,
        [string]$Digest,
        [string]$ModelDigest,
        [int]$Cycles,
        $Cells,
        [int]$SiteCount,
        [int]$Strong,
        [int]$Weak
    )
    $packArgs = @(
        (Join-Path $proj 'tools\package_core.py'),
        '--proj', "`"$proj`"",
        '--name', $Core,
        '--family', [string]$Entry.family,
        '--function', "`"$([string]$Entry.function)`"",
        '--digest', $Digest,
        '--model-digest', $ModelDigest,
        '--cycles', [string]$Cycles,
        '--sites', [string]$SiteCount,
        '--strong', [string]$Strong,
        '--weak', [string]$Weak
    )
    if ($null -ne $Cells) {
        $packArgs = $packArgs + @('--lut', [string]$Cells.slice_class, '--ff', [string]$Cells.ff,
            '--dsp', [string]$Cells.dsp, '--bram', [string]$Cells.bram_blocks,
            '--lut-max', [string]$Entry.lut_max, '--dsp-max', [string]$Entry.dsp_max)
    }
    $p = Invoke-Native -FilePath $pythonExe -Arguments $packArgs -WorkDir $proj -TimeoutMs 120000
    if ($p.exit -ne 0) {
        throw ("packaging failed for $Core : " + (($p.stdout + $p.stderr) | Select-Object -Last 8 | ForEach-Object { [string]$_ } | Out-String))
    }
    return (($p.stdout | Select-Object -Last 1) | ForEach-Object { [string]$_ }) -join ''
}

function Test-WrapperElaborates {
    param([string]$Core, [string[]]$RtlRels)
    $iverilog = Get-Exe 'iverilog'
    $wrapRel = "ip/$Core/gw2a_ips_$Core.v"
    $args = @('-g2012', '-s', "gw2a_ips_$Core", '-o', "build/sim/$Core.wrapper.vvp")
    $args = $args + @($wrapRel) + @($RtlRels)
    $c = Invoke-Native -FilePath $iverilog -Arguments $args -WorkDir $proj -TimeoutMs 120000
    Save-Log -Path (Join-Path $proj "build\logs\$Core.wrapper.log") -Lines ($c.stdout + $c.stderr)
    if ($c.exit -ne 0) {
        throw ('packaged wrapper does not elaborate: ' + (($c.stderr + $c.stdout) | Select-Object -Last 8 | ForEach-Object { [string]$_ } | Out-String))
    }
}

function Get-SpecCores {
    param([string[]]$Filter)
    $all = @($spec.cores)
    if ($null -eq $Filter -or $Filter.Count -eq 0) { return , $all }
    $picked = @($all | Where-Object { $Filter -contains [string]$_.name })
    if ($picked.Count -ne $Filter.Count) {
        $known = @($all | ForEach-Object { [string]$_.name })
        $missing = @($Filter | Where-Object { $known -notcontains $_ })
        throw "core(s) not declared in ip_series_spec.json: $($missing -join ', ')"
    }
    return , $picked
}

function Invoke-CoreGate {
    param($Entry)
    $name = [string]$Entry.name
    $gate = [ordered]@{
        schema         = 'ip-series-gate-v1'
        core           = $name
        family         = [string]$Entry.family
        function       = [string]$Entry.function
        stage          = 'inputs'
        status         = 'FAIL'
        detail         = ''
        rtl_digest     = $null
        model_digest   = $null
        cycles         = $null
        mutation       = $null
        resources      = $null
        budget         = [ordered]@{ lut_max = $Entry.lut_max; dsp_max = $Entry.dsp_max }
        board_evidence = 'DEFERRED'
        checked_utc    = (Get-Date).ToUniversalTime().ToString('o')
    }
    $rtlRel = "src/ips_$name.v"
    $tbRel = "sim/tb_ips_$name.v"
    $modelRel = "models/ips_$name.py"
    $deps = @()
    if ($Entry.PSObject.Properties.Name -contains 'deps') { $deps = @($Entry.deps) }
    $rtlAbs = Join-Path $proj ('src\ips_' + $name + '.v')
    $tbAbs = Join-Path $proj ('sim\tb_ips_' + $name + '.v')
    $modelAbs = Join-Path $proj ('models\ips_' + $name + '.py')
    $required = @(
        [pscustomobject]@{ Abs = $rtlAbs; Rel = $rtlRel },
        [pscustomobject]@{ Abs = $tbAbs; Rel = $tbRel },
        [pscustomobject]@{ Abs = $modelAbs; Rel = $modelRel }
    )
    foreach ($item in $required) {
        if (-not (Test-Path -LiteralPath $item.Abs -PathType Leaf)) {
            throw "missing production-line input: $($item.Rel)"
        }
    }
    foreach ($dep in $deps) {
        if (-not (Test-Path -LiteralPath (Join-Path $proj ($dep.Replace('/', '\'))) -PathType Leaf)) {
            throw "missing declared dependency: $dep"
        }
    }
    # A core may declare extra compile files in src/ips_<name>.deps, one relative
    # path per line.  A 'sim:' prefix marks a simulation-only file (for example a
    # Gowin primitive behaviour model) that must not be read during synthesis.
    $simDeps = @($deps)
    $synthDeps = @($deps)
    $depsFile = Join-Path $proj "src\ips_$name.deps"
    if (Test-Path -LiteralPath $depsFile -PathType Leaf) {
        foreach ($raw in @(Get-Content -LiteralPath $depsFile)) {
            $t = ([string]$raw).Trim()
            if ($t.Length -eq 0 -or $t.StartsWith('//') -or $t.StartsWith('#')) { continue }
            $simOnly = $false
            if ($t.StartsWith('sim:')) { $simOnly = $true; $t = $t.Substring(4).Trim() }
            if (-not (Test-Path -LiteralPath (Join-Path $proj ($t.Replace('/', '\'))) -PathType Leaf)) {
                throw "dependency listed in src/ips_$name.deps is missing: $t"
            }
            $simDeps += $t
            if (-not $simOnly) { $synthDeps += $t }
        }
    }

    $sim = Invoke-CoreSim -Core "ips_$name" -RtlRel $rtlRel -DepRels $simDeps -Tag 'golden' `
        -VvpRel "build/sim/$name.vvp"
    if (-not $sim.ok) { throw "sim station: $($sim.reason) $($sim.detail)" }
    $gate.stage = 'sim'
    $gate.rtl_digest = $sim.digest
    $gate.cycles = $sim.cycles

    $m = Invoke-Native -FilePath $pythonExe -Arguments @("models/ips_$name.py") -WorkDir $proj -TimeoutMs 120000
    Save-Log -Path (Join-Path $proj "build\logs\$name.model.log") -Lines ($m.stdout + $m.stderr)
    if ($m.exit -ne 0) {
        throw ('model station: ' + (($m.stderr + $m.stdout) | Select-Object -Last 6 | ForEach-Object { [string]$_ } | Out-String))
    }
    $modelLines = @($m.stdout | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'MODEL.*D=[0-9a-fA-F]{1,8}' })
    if ($modelLines.Count -eq 0) { throw 'model station: no MODEL ... D=<hex> line printed' }
    $lastModel = $modelLines[-1]
    if ($lastModel -notmatch 'D=([0-9a-fA-F]{1,8})') { throw "model station: digest malformed: $lastModel" }
    $gate.model_digest = (Norm-Digest $Matches[1])
    if ($gate.model_digest -ne $gate.rtl_digest) {
        throw "golden divergence for ${name}: RTL=$($gate.rtl_digest) model=$($gate.model_digest)"
    }
    $gate.stage = 'golden'

    $rtlLines = @(Get-Content -LiteralPath $rtlAbs | ForEach-Object { [string]$_ })
    $sites = @(Get-MutationSites -Path $rtlAbs -Limit $Mutants)
    if ($sites.Count -lt 3) {
        throw "insufficient mutation sites in $rtlRel (found $($sites.Count), need 3)"
    }
    $strong = 0
    $weak = 0
    $survivors = @()
    $mutRoot = Join-Path $proj "build\mut\$name"
    if (Test-Path $mutRoot) { Remove-Item -LiteralPath $mutRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $mutRoot | Out-Null
    for ($i = 0; $i -lt $sites.Count; $i++) {
        $site = $sites[$i]
        $dir = Join-Path $mutRoot ("m$i")
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $mutRel = "build/mut/$name/m$i/ips_$name.v"
        New-MutantFile -Lines $rtlLines -Site $site -OutPath (Join-Path $proj ($mutRel.Replace('/', '\')))
        $res = Invoke-CoreSim -Core "ips_$name" -RtlRel $mutRel -DepRels $simDeps -Tag "mut$i" `
            -VvpRel "build/sim/$name.m$i.vvp"
        if (-not $res.ok) { $weak += 1; continue }
        if ($res.digest -ne $gate.rtl_digest) { $strong += 1; continue }
        $survivors += ("m$i[" + $site.Kind + " '" + $site.Old + "'->" + $site.New + " line " + ($site.Line + 1) + ']')
    }
    $gate.mutation = [ordered]@{
        sites           = $sites.Count
        detected_digest = $strong
        detected_build  = $weak
        survivors       = $survivors.Count
        survivor_list   = $survivors
    }
    if ($survivors.Count -gt 0) {
        throw "vacuous testbench for ${name}: mutant(s) left the digest unchanged: $($survivors -join ', ')"
    }
    if ($strong -lt 2) {
        throw "weak evidence for ${name}: only $strong mutant(s) changed the digest, need 2"
    }
    $gate.stage = 'mutation'

    if ($SkipSynth) {
        $gate.detail = 'synth+packaging skipped by -SkipSynth'
        $gate.status = 'PASS'
        return $gate
    }

    $cells = Invoke-CoreSynth -Core $name -RtlRels (@($rtlRel) + $synthDeps)
    $gate.resources = [ordered]@{
        lut_class_cells = $cells.slice_class
        lut_cells       = $cells.lut
        alu_cells       = $cells.alu
        lutram_cells    = $cells.lutram
        ff_cells        = $cells.ff
        dsp_cells       = $cells.dsp
        bram_blocks     = $cells.bram_blocks
    }
    if ($cells.slice_class -gt [int]$Entry.lut_max) {
        throw "resource gate: $name uses $($cells.slice_class) LUT-class cells, budget is $($Entry.lut_max)"
    }
    if ($cells.dsp -gt [int]$Entry.dsp_max) {
        throw "resource gate: $name uses $($cells.dsp) DSP-class cells, budget is $($Entry.dsp_max)"
    }
    $gate.stage = 'synth'

    $note = Invoke-Packaging -Core $name -Entry $Entry -Digest $gate.rtl_digest `
        -ModelDigest $gate.model_digest -Cycles $gate.cycles -Cells $cells `
        -SiteCount $sites.Count -Strong $strong -Weak $weak
    Test-WrapperElaborates -Core $name -RtlRels (@("src/ips_$name.v") + $simDeps)
    $gate.stage = 'package'
    $gate.detail = $note
    $gate.status = 'PASS'
    return $gate
}

function Write-GateRecord {
    param($Gate)
    $core = [string]$Gate.core
    Set-Content -LiteralPath (Join-Path $proj ("ip\gate_$core.json")) `
        -Value ($Gate | ConvertTo-Json -Depth 8) -Encoding UTF8
    $ipDir = Join-Path $proj "ip\$core"
    if (Test-Path $ipDir) {
        Set-Content -LiteralPath (Join-Path $ipDir 'gate.json') `
            -Value ($Gate | ConvertTo-Json -Depth 8) -Encoding UTF8
    }
}

$spec = Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json
if ($spec.schema -ne 'ip-series-portfolio-v1') { throw "unexpected spec schema: $($spec.schema)" }

switch ($Command) {
    'scan' {
        $names = @($spec.cores | ForEach-Object { [string]$_.name })
        if ($names.Count -lt 50) { throw "portfolio declares $($names.Count) cores, the objective requires 50+" }
        $dupes = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($dupes.Count -gt 0) { throw "duplicate core names: $($dupes -join ', ')" }
        $badNames = @($names | Where-Object { $_ -notmatch '^[a-z0-9_]+$' })
        if ($badNames.Count -gt 0) { throw "core names must be lowercase [a-z0-9_]: $($badNames -join ', ')" }
        $rows = @()
        foreach ($entry in $spec.cores) {
            $n = [string]$entry.name
            $rows += [pscustomobject]@{
                Core     = $n
                Family   = [string]$entry.family
                Rtl      = (Test-Path -LiteralPath (Join-Path $proj "src\ips_$n.v"))
                Tb       = (Test-Path -LiteralPath (Join-Path $proj "sim\tb_ips_$n.v"))
                Model    = (Test-Path -LiteralPath (Join-Path $proj "models\ips_$n.py"))
                Packaged = (Test-Path -LiteralPath (Join-Path $proj "ip\$n\ip_manifest.json"))
            }
        }
        $rows | Format-Table -AutoSize
        $trios = @($rows | Where-Object { $_.Rtl -and $_.Tb -and $_.Model }).Count
        $packed = @($rows | Where-Object { $_.Packaged }).Count
        [pscustomobject]@{
            schema         = 'ip-series-scan-v1'
            generated_utc  = (Get-Date).ToUniversalTime().ToString('o')
            cores_declared = $names.Count
            cores_with_trio = $trios
            cores_packaged = $packed
            families       = (@($rows | ForEach-Object { $_.Family } | Sort-Object -Unique)) -join ','
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $reportDir 'ip_series_scan.json') -Encoding UTF8
        Write-Output "HARNESS IP-SERIES SCAN declared=$($names.Count) trios=$trios packaged=$packed"
    }
    'core' {
        if ([string]::IsNullOrWhiteSpace($Name)) { throw 'harness core requires a core name, e.g. -Name fix_add_sat' }
        $picked = Get-SpecCores -Filter @($Name)
        $gate = Invoke-CoreGate -Entry $picked[0]
        Write-GateRecord -Gate $gate
        $gate | ConvertTo-Json -Depth 8
        Write-Output "HARNESS IP-SERIES CORE PASS $($gate.core) digest=$($gate.rtl_digest) cycles=$($gate.cycles) stage=$($gate.stage)"
    }
    'all' {
        $filter = @()
        if (-not [string]::IsNullOrWhiteSpace($Name)) { $filter = @($Name.Split(',')) }
        $picked = Get-SpecCores -Filter $filter
        $results = @()
        $fail = 0
        foreach ($entry in $picked) {
            $n = [string]$entry.name
            try {
                $gate = Invoke-CoreGate -Entry $entry
                Write-GateRecord -Gate $gate
                $lut = 'n/a'
                $dsp = 'n/a'
                $mut = 'n/a'
                if ($gate.resources) { $lut = $gate.resources.lut_class_cells; $dsp = $gate.resources.dsp_cells }
                if ($gate.mutation) { $mut = "$($gate.mutation.detected_digest)/$($gate.mutation.sites)" }
                $results += [pscustomobject]@{ Core = $n; Status = 'PASS'; Digest = $gate.rtl_digest; Cycles = $gate.cycles; Lut = $lut; Dsp = $dsp; Mut = $mut; Note = '' }
            }
            catch {
                $fail += 1
                $msg = $_.Exception.Message
                $gate = [ordered]@{
                    schema         = 'ip-series-gate-v1'
                    core           = $n
                    family         = [string]$entry.family
                    status         = 'FAIL'
                    stage          = 'aborted'
                    detail         = $msg
                    board_evidence = 'DEFERRED'
                    checked_utc    = (Get-Date).ToUniversalTime().ToString('o')
                }
                Write-GateRecord -Gate $gate
                $results += [pscustomobject]@{ Core = $n; Status = 'FAIL'; Digest = ''; Cycles = ''; Lut = ''; Dsp = ''; Mut = ''; Note = $msg }
                Write-Host "FAIL $n : $msg"
            }
        }
        $results | Format-Table -AutoSize
        [pscustomobject]@{
            schema         = 'ip-series-run-v1'
            generated_utc  = (Get-Date).ToUniversalTime().ToString('o')
            attempted      = $results.Count
            failed         = $fail
            board_evidence = 'DEFERRED'
            cores          = $results
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDir 'ip_series_run.json') -Encoding UTF8
        if ($fail -gt 0) { throw "ip series gate: $fail of $($results.Count) cores FAILED" }
        Write-Output "HARNESS IP-SERIES ALL PASS cores=$($results.Count)"
    }
    'report' {
        $rows = @()
        $missing = 0
        $failed = 0
        $pass = 0
        foreach ($entry in $spec.cores) {
            $n = [string]$entry.name
            $path = Join-Path $proj "ip\gate_$n.json"
            $packaged = Test-Path -LiteralPath (Join-Path $proj "ip\$n\ip_manifest.json")
            if (-not (Test-Path -LiteralPath $path)) {
                $missing += 1
                $rows += [pscustomobject]@{ Core = $n; Family = [string]$entry.family; Status = 'MISSING'; Digest = ''; Lut = ''; Dsp = ''; Board = 'DEFERRED'; Packaged = $false }
                continue
            }
            $g = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $lut = ''
            $dsp = ''
            if ($g.resources) { $lut = $g.resources.lut_class_cells; $dsp = $g.resources.dsp_cells }
            if ([string]$g.status -eq 'PASS') { $pass += 1 } else { $failed += 1 }
            if ([string]$g.board_evidence -ne 'DEFERRED' -and [string]$g.board_evidence -ne 'PASS') {
                throw "gate record for $n has unsupported board_evidence '$($g.board_evidence)'"
            }
            $rows += [pscustomobject]@{
                Core = $n; Family = [string]$g.family; Status = [string]$g.status; Digest = [string]$g.rtl_digest
                Lut = $lut; Dsp = $dsp; Board = [string]$g.board_evidence; Packaged = $packaged
            }
        }
        $rows | Format-Table -AutoSize
        $md = New-Object System.Collections.Generic.List[string]
        $md.Add('# ip_series_20k production line index')
        $md.Add('')
        $md.Add('Generated by `scripts\ip_series_harness.ps1 report`.  A core is only listed PASS after all six')
        $md.Add('stations cleared: iverilog compile, sim verdict, independent golden-model digest match, literal')
        $md.Add('mutation (non-vacuity), `synth_gowin -noalu` resource budget, and packaging of the `gw2a_ips_*`')
        $md.Add('wrapper.  Device: GW2A-LV18PG256C8/I7 (Tang Primer 20K).')
        $md.Add('')
        $md.Add('| core | family | gate | sim digest | LUT-class | DSP | packaged | board |')
        $md.Add('|---|---|---|---|---|---|---|---|')
        foreach ($r in ($rows | Sort-Object Family, Core)) {
            $pack = if ($r.Packaged) { 'yes' } else { 'no' }
            $d = if ($r.Digest) { $r.Digest } else { '-' }
            $l = if ($r.Lut -eq '') { '-' } else { $r.Lut }
            $s = if ($r.Dsp -eq '') { '-' } else { $r.Dsp }
            $md.Add(('| ips_{0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f `
                $r.Core, $r.Family, $r.Status, $d, $l, $s, $pack, $r.Board))
        }
        $md.Add('')
        $md.Add(('Totals: declared {0}, gated PASS {1}, failed {2}, never gated {3}.' -f `
            $rows.Count, $pass, $failed, $missing))
        $md.Add('')
        Set-Content -LiteralPath (Join-Path $proj 'ip\MANIFEST.md') -Value ($md -join [Environment]::NewLine) -Encoding UTF8
        [pscustomobject]@{
            schema        = 'ip-series-ledger-v1'
            generated_utc = (Get-Date).ToUniversalTime().ToString('o')
            namespace     = [string]$spec.namespace
            device        = [string]$spec.device
            declared      = $rows.Count
            gated_pass    = $pass
            gated_fail    = $failed
            not_yet_gated = $missing
            board_evidence = 'DEFERRED'
            cores         = $rows
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDir 'ip_series_ledger.json') -Encoding UTF8
        Write-Output "HARNESS IP-SERIES REPORT declared=$($rows.Count) pass=$pass fail=$failed missing=$missing board=DEFERRED index=cores/system/ip_series/ip/MANIFEST.md"
        if ($missing -gt 0 -or $failed -gt 0) { throw "ip series ledger incomplete: $missing ungated, $failed failed" }
    }
}
