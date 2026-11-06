# SPDX-License-Identifier: Apache-2.0
param([switch]$Freeze,[switch]$Execute)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Pkg=$PSScriptRoot
$Repo=[IO.Path]::GetFullPath((Join-Path $Pkg '../../..'))
$PlanPath=Join-Path $Pkg 'PRECHECK_PLAN.json'
$SealPath=Join-Path $Pkg 'SOURCE_SEAL.json'
$InventoryPath=Join-Path $Pkg 'TOOL_INVENTORY.json'
$Plan=Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$IV=Join-Path $Repo 'tools/oss-cad-suite/oss-cad-suite/bin/iverilog.exe'
$VVP=Join-Path $Repo 'tools/oss-cad-suite/oss-cad-suite/bin/vvp.exe'
$PY='C:/Program Files/Python312/python.exe'
$TreeKill=Join-Path $env:SystemRoot 'System32/taskkill.exe'
$Sources=@(
    'rtl/causal_palette_diffusion.sv','example/rgb_palette_diffusion.sv',
    'sim/tb_causal_palette.sv','files.f','example/files.f',
    'reference_model.py','prepare_vectors.py','run_tests.ps1','PRECHECK_PLAN.json',
    'README.md','ARCHITECTURE.md','SOURCES.md','references.json','LICENSE','.gitattributes'
)
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function WriteJson([string]$Path,$Value){
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30)+"`n",[Text.UTF8Encoding]::new($false))
}
if($Freeze -eq $Execute){throw 'Choose exactly one of -Freeze or -Execute'}
if($Freeze){
    if(Test-Path -LiteralPath $SealPath){throw 'Source seal already exists; no implicit overwrite'}
    $Files=@()
    foreach($Rel in $Sources){
        $Path=Join-Path $Pkg $Rel
        $Files+=@{path=[IO.Path]::GetRelativePath($Repo,$Path).Replace('\','/');sha256=(Hash $Path);bytes=(Get-Item -LiteralPath $Path).Length}
    }
    $Dependency=Join-Path $Repo 'cores/system/extended_library/src/isp_rgb2gray.v'
    $Files+=@{path='cores/system/extended_library/src/isp_rgb2gray.v';sha256=(Hash $Dependency);bytes=(Get-Item -LiteralPath $Dependency).Length}
    $Tools=@()
    foreach($Path in @($PY,$IV,$VVP,$TreeKill)){$Tools+=@{path=$Path;sha256=(Hash $Path);bytes=(Get-Item -LiteralPath $Path).Length}}
    WriteJson $InventoryPath @{schema='b43-c-tools-v1';tools=$Tools;executed=$false}
    WriteJson $SealPath @{schema='b43-c-source-seal-v1';baseline=$Plan.baseline;files=$Files;tool_inventory_sha256=(Hash $InventoryPath);model_imports=0;hdl_children=0;preparation_children=0}
    Write-Output ('B43_C_SOURCE_FROZEN seal_sha256='+(Hash $SealPath))
    exit 0
}
$Seal=Get-Content -LiteralPath $SealPath -Raw | ConvertFrom-Json
$Inventory=Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
foreach($File in $Seal.files){if((Hash (Join-Path $Repo $File.path)) -ne $File.sha256){throw ('Sealed source changed: '+$File.path)}}
if((Hash $InventoryPath) -ne $Seal.tool_inventory_sha256){throw 'Tool inventory changed'}
foreach($Tool in $Inventory.tools){if((Hash $Tool.path) -ne $Tool.sha256){throw ('Tool changed: '+$Tool.path)}}
if(Test-Path -LiteralPath (Join-Path $Pkg 'EXECUTION_LOCK.json')){throw 'Prior execution exists: stop, no retry'}
$RunId=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
$Run=Join-Path $Pkg ('reports/'+$RunId)
$Build=Join-Path $Pkg ('.build/'+$RunId)
[IO.Directory]::CreateDirectory($Run)|Out-Null
[IO.Directory]::CreateDirectory($Build)|Out-Null
WriteJson (Join-Path $Pkg 'EXECUTION_LOCK.json') @{run_id=$RunId;source_seal_sha256=(Hash $SealPath);plan_sha256=(Hash $PlanPath);status='STARTED_NO_RETRY'}
$Snapshot=Join-Path $Run 'source'
foreach($File in $Seal.files){
    $Dest=Join-Path $Snapshot $File.path
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Dest))|Out-Null
    [IO.File]::Copy((Join-Path $Repo $File.path),$Dest,$false)
    if((Hash $Dest) -ne $File.sha256){throw 'Archive copy mismatch'}
}
foreach($File in @($SealPath,$InventoryPath)){
    [IO.File]::Copy($File,(Join-Path $Run ([IO.Path]::GetFileName($File))),$false)
}
$Archived=Join-Path $Snapshot 'cores/image_processing/causal_palette_diffusion'
$Result=@{schema='b43-c-results-v1';run_id=$RunId;status='RUNNING';source_seal_sha256=(Hash $SealPath);plan_sha256=(Hash $PlanPath);preparation_children=0;oracle_imports=0;oracle_preparations=0;hdl_children=0;children=@();images=@();vectors=@();automatic_retry=$false;failure=$null}
$ResultPath=Join-Path $Run 'results.json'
WriteJson $ResultPath $Result
function StartCaptured([string]$Exe,[string[]]$Argv,[string]$Working,[string]$Prefix){
    $Info=[Diagnostics.ProcessStartInfo]::new()
    $Info.FileName=$Exe;$Info.WorkingDirectory=$Working;$Info.UseShellExecute=$false
    $Info.CreateNoWindow=$true;$Info.RedirectStandardOutput=$true;$Info.RedirectStandardError=$true
    $Info.Environment['PYTHONDONTWRITEBYTECODE']='1'
    foreach($Arg in $Argv){$Info.ArgumentList.Add($Arg)}
    $Process=[Diagnostics.Process]::new();$Process.StartInfo=$Info
    $Capture=@{process=$Process;stdout=$null;stderr=$null;out_task=$null;err_task=$null;prefix=$Prefix;started=$false;start_exception=$null}
    try{
        $Capture.stdout=[IO.File]::Open($Prefix+'.stdout.raw',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $Capture.stderr=[IO.File]::Open($Prefix+'.stderr.raw',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $Capture.started=$Process.Start()
        if(!$Capture.started){throw 'Process start failed'}
        $Capture.out_task=$Process.StandardOutput.BaseStream.CopyToAsync($Capture.stdout)
        $Capture.err_task=$Process.StandardError.BaseStream.CopyToAsync($Capture.stderr)
    }catch{$Capture.start_exception=$_.Exception.Message}
    # Always return ownership, including a partially initialized/start-failed
    # capture. The caller's finally closes every acquired resource.
    return $Capture
}
function DrainAll([object[]]$Captures){
    $Ok=$false
    $Tasks=@()
    foreach($Capture in $Captures){
        if($null -ne $Capture){
            if($null -ne $Capture.out_task){$Tasks+=,$Capture.out_task}
            if($null -ne $Capture.err_task){$Tasks+=,$Capture.err_task}
        }
    }
    # One joint deadline for primary and taskkill stdout/stderr, never 2+2s.
    try{$Ok=[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$Tasks,2000)}catch{$Ok=$false}
    foreach($Capture in $Captures){
        if($null -eq $Capture){continue}
        if($Capture.started -and !$Ok){
            try{$Capture.process.StandardOutput.BaseStream.Dispose()}catch{}
            try{$Capture.process.StandardError.BaseStream.Dispose()}catch{}
        }
        if($null -ne $Capture.stdout){try{$Capture.stdout.Dispose()}catch{}}
        if($null -ne $Capture.stderr){try{$Capture.stderr.Dispose()}catch{}}
    }
    return $Ok
}
function Child([string]$Name,[string]$Kind,[string]$Exe,[string[]]$Argv,[string]$Working,[string]$Marker){
    $Prefix=Join-Path $Run $Name
    $Receipt=@{name=$Name;kind=$Kind;argv=@($Exe)+$Argv;cwd=$Working;status='STARTING';deadline_seconds=20;tree_kill_seconds=5;drain_seconds=2;started_utc=[DateTime]::UtcNow.ToString('o');timed_out=$false;tree_kill=$null}
    $Watch=[Diagnostics.Stopwatch]::StartNew()
    $Cap=$null;$Kill=$null;$Finished=$false;$Exited=$false;$Drained=$false;$Killed=$false
    try{
        $Cap=StartCaptured $Exe $Argv $Working $Prefix
        if($null -ne $Cap.start_exception){throw $Cap.start_exception}
        $Finished=$Cap.process.WaitForExit(20000)
        if(!$Finished){$Receipt.timed_out=$true}
    }catch{$Receipt.status='HARNESS_FAILURE';$Receipt.exception=$_.Exception.Message}
    finally{
        # The same finite tree-kill path covers both normal timeouts and every
        # exception after process acquisition. No acquired capture escapes.
        if($null -ne $Cap -and $Cap.started){
            try{
                if(!$Cap.process.HasExited){
                    $Receipt.tree_kill=@{argv=@($TreeKill,'/PID',[string]$Cap.process.Id,'/T','/F');finished=$false;exit_code=$null;exception=$null}
                    $Kill=StartCaptured $TreeKill @('/PID',[string]$Cap.process.Id,'/T','/F') $Working ($Prefix+'.tree_kill')
                    if($null -ne $Kill.start_exception){throw $Kill.start_exception}
                    $Killed=$Kill.process.WaitForExit(5000)
                    if(!$Killed){try{$Kill.process.Kill()}catch{}}
                    $Receipt.tree_kill.finished=$Killed
                    if($Killed){$Receipt.tree_kill.exit_code=$Kill.process.ExitCode}
                }
            }catch{
                if($null -ne $Receipt.tree_kill){$Receipt.tree_kill.exception=$_.Exception.Message}
                $Receipt.status='HARNESS_FAILURE'
                $Receipt.exception=$_.Exception.Message
            }
        }
        # A partial helper start or helper failure must not leave either owned
        # process running. These non-waiting kill requests share the existing
        # tree-kill phase; the one joint drain below is the final wait.
        if($null -ne $Kill -and $Kill.started){
            try{if(!$Kill.process.HasExited){$Kill.process.Kill()}}catch{
                $Receipt.status='HARNESS_FAILURE';$Receipt.helper_kill_exception=$_.Exception.Message
            }
        }
        if($null -ne $Cap -and $Cap.started){
            try{
                if(!$Cap.process.HasExited){$Receipt.fallback_tree_kill_requested=$true;$Cap.process.Kill($true)}
            }catch{$Receipt.status='HARNESS_FAILURE';$Receipt.fallback_kill_exception=$_.Exception.Message}
        }
        $Drained=DrainAll @($Cap,$Kill)
        $Receipt.drained=$Drained
        if($null -ne $Cap){
            if($Cap.started){
                try{$Exited=$Cap.process.HasExited;if($Exited){$Receipt.exit_code=$Cap.process.ExitCode}}catch{$Exited=$false}
            }
            try{$Cap.process.Dispose()}catch{}
        }
        if($null -ne $Kill){try{$Kill.process.Dispose()}catch{}}
    }
    try{
        if(!$Receipt.ContainsKey('exit_code')){$Receipt.exit_code=$null}
        if($Receipt.status -eq 'STARTING'){
            $Receipt.status=if($Receipt.timed_out){'TIMEOUT'}elseif(!$Exited -or !$Drained -or $Receipt.exit_code -ne 0){'FAIL'}else{'PASS'}
        }
        $Stdout=[IO.File]::ReadAllText($Prefix+'.stdout.raw')
        if($Receipt.status -eq 'PASS' -and $Marker -and !$Stdout.Contains($Marker)){$Receipt.status='FAIL_MARKER'}
        if($Kind -eq 'simulation' -and $Receipt.status -eq 'PASS'){
            $Match=[regex]::Match($Stdout,'B43_C_PASS frames=19 faults=3 invalids=2 resets=9 outputs=(\d+) early=(\d+) holds=(\d+) gaps=(\d+)')
            if(!$Match.Success){$Receipt.status='FAIL_COUNTERS'}else{$Receipt.counters=@{frames=19;faults=3;invalids=2;resets=9;outputs=[int]$Match.Groups[1].Value;early=[int]$Match.Groups[2].Value;holds=[int]$Match.Groups[3].Value;gaps=[int]$Match.Groups[4].Value}}
            if($Match.Success){
                $Profile=@($Plan.profiles|Where-Object {('sim_'+$_.name) -eq $Name})
                if($Profile.Count -ne 1){$Receipt.status='FAIL_PROFILE'}else{
                    $Pixels=$Profile[0].w*$Profile[0].h
                    $ExpectedOutputs=19*$Pixels+3*[int][Math]::Floor($Pixels/2)
                    $ExpectedEarly=if($Pixels -gt 1){22}else{0}
                    if($Receipt.counters.outputs -ne $ExpectedOutputs -or $Receipt.counters.early -ne $ExpectedEarly -or $Receipt.counters.holds -lt 1){$Receipt.status='FAIL_COUNTERS'}
                }
            }
        }
    }catch{$Receipt.status='HARNESS_FAILURE';$Receipt.exception=$_.Exception.Message}
    $Receipt.elapsed_seconds=$Watch.Elapsed.TotalSeconds
    if($Kind -eq 'compile'){
        $OutputIndex=[Array]::IndexOf($Argv,'-o')
        if($OutputIndex -ge 0 -and $OutputIndex+1 -lt $Argv.Length){
            $Artifact=$Argv[$OutputIndex+1]
            if(Test-Path -LiteralPath $Artifact){
                $Receipt.artifact=@{path=[IO.Path]::GetRelativePath($Pkg,$Artifact).Replace('\','/');sha256=(Hash $Artifact);bytes=(Get-Item -LiteralPath $Artifact).Length;compile_status=$Receipt.status}
                $Result.images+=,$Receipt.artifact
            }
        }
    }
    foreach($Ext in @('stdout','stderr')){
        $Raw=$Prefix+'.'+$Ext+'.raw'
        if(Test-Path -LiteralPath $Raw){$Receipt[$Ext]=@{path=[IO.Path]::GetRelativePath($Pkg,$Raw).Replace('\','/');bytes=(Get-Item -LiteralPath $Raw).Length;sha256=(Hash $Raw)}}
        $KillRaw=$Prefix+'.tree_kill.'+$Ext+'.raw'
        if(Test-Path -LiteralPath $KillRaw){$Receipt.tree_kill[$Ext]=@{path=[IO.Path]::GetRelativePath($Pkg,$KillRaw).Replace('\','/');bytes=(Get-Item -LiteralPath $KillRaw).Length;sha256=(Hash $KillRaw)}}
    }
    WriteJson ($Prefix+'.json') $Receipt
    $Result.children+=,$Receipt
    if($Kind -eq 'preparation'){$Result.preparation_children++}else{$Result.hdl_children++}
    WriteJson $ResultPath $Result
    Write-Output ($Name+' '+$Receipt.status)
    if($Receipt.status -ne 'PASS'){throw ($Name+' '+$Receipt.status+'; fail-stop, all artifacts retained')}
}
try{
    $VectorRoot=Join-Path $Run 'vectors'
    Child 'prepare_vectors' 'preparation' $PY @('-I','-B',(Join-Path $Archived 'prepare_vectors.py'),$VectorRoot) $Archived 'B43_C_PREP_PASS profiles=4 oracle_imports=1 oracle_preparations=1'
    $Prep=Get-Content -LiteralPath (Join-Path $VectorRoot 'receipt.json') -Raw|ConvertFrom-Json
    if($Prep.oracle_imports -ne 1 -or $Prep.oracle_preparations -ne 1 -or $Prep.files.Count -ne 12){throw 'Preparation accounting mismatch'}
    $Result.oracle_imports=1;$Result.oracle_preparations=1
    foreach($File in $Prep.files){if((Hash (Join-Path $VectorRoot $File.path)) -ne $File.sha256){throw 'Prepared vector mismatch'}}
    $Result.vectors=$Prep.files
    Child 'lint_core' 'syntax' $IV @('-g2012','-Wall','-tnull','-s','causal_palette_diffusion','-f','files.f') $Archived ''
    Child 'lint_core_max' 'syntax' $IV @('-g2012','-Wall','-tnull','-s','causal_palette_diffusion','-Pcausal_palette_diffusion.WIDTH=4096','-Pcausal_palette_diffusion.HEIGHT=4096','-Pcausal_palette_diffusion.BITS=12','-Pcausal_palette_diffusion.TAG_W=32','-f','files.f') $Archived ''
    Child 'lint_actual_max' 'syntax' $IV @('-g2012','-Wall','-tnull','-s','rgb_palette_diffusion','-Prgb_palette_diffusion.WIDTH=4096','-Prgb_palette_diffusion.HEIGHT=4096','-Prgb_palette_diffusion.TAG_W=32','-f','example/files.f') $Archived ''
    foreach($P in $Plan.profiles){
        $Image=Join-Path $Build ($P.name+'.vvp')
        $List=if($P.wrap){'example/files.f'}else{'files.f'}
        $CompileArgs=@('-g2012','-Wall','-s','tb_causal_palette',('-Ptb_causal_palette.W='+$P.w),('-Ptb_causal_palette.H='+$P.h),('-Ptb_causal_palette.B='+$P.b),('-Ptb_causal_palette.T='+$P.t),('-Ptb_causal_palette.WRAP='+$P.wrap),'-o',$Image,'-f',$List,'sim/tb_causal_palette.sv')
        Child ('compile_'+$P.name) 'compile' $IV $CompileArgs $Archived ''
        Child ('sim_'+$P.name) 'simulation' $VVP @($Image) (Join-Path $VectorRoot $P.name) 'B43_C_PASS'
    }
    $Actual=@($Result.children|Where-Object kind -ne 'preparation'|ForEach-Object name)
    if(($Actual -join '|') -ne ($Plan.expected_hdl_children -join '|')){throw 'Child ledger differs from frozen plan'}
    foreach($File in $Seal.files){if((Hash (Join-Path $Repo $File.path)) -ne $File.sha256){throw 'Source changed during execution'}}
    $Result.status='PASS'
}catch{$Result.status='FAIL_STOP';$Result.failure=$_.Exception.Message}
WriteJson $ResultPath $Result
if($Result.status -ne 'PASS'){throw $Result.failure}
Write-Output ('B43_C_RUN_PASS results='+$ResultPath+' sha256='+(Hash $ResultPath))
