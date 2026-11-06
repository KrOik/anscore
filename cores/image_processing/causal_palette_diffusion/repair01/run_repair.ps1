# SPDX-License-Identifier: Apache-2.0
param([switch]$Freeze,[switch]$Execute)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Repair=$PSScriptRoot
$Pkg=[IO.Path]::GetFullPath((Join-Path $Repair '..'))
$Repo=[IO.Path]::GetFullPath((Join-Path $Pkg '../../..'))
$Original=Join-Path $Pkg 'reports/20261106T0933574171958Z'
$PlanPath=Join-Path $Repair 'REPAIR01_PLAN.json'
$Suite=Join-Path $Repo 'tools/oss-cad-suite/oss-cad-suite'
$IV=Join-Path $Suite 'bin/iverilog.exe';$VVP=Join-Path $Suite 'bin/vvp.exe'
$TreeKill=Join-Path $env:SystemRoot 'System32/taskkill.exe'
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function WriteJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 40)+"`n",[Text.UTF8Encoding]::new($false))}
function StartCaptured([string]$Exe,[string[]]$Argv,[string]$Working,[string]$Prefix){
    $Info=[Diagnostics.ProcessStartInfo]::new()
    $Info.FileName=$Exe;$Info.WorkingDirectory=$Working;$Info.UseShellExecute=$false
    $Info.CreateNoWindow=$true;$Info.RedirectStandardOutput=$true;$Info.RedirectStandardError=$true
    $Info.Environment['PYTHONDONTWRITEBYTECODE']='1'
    $Info.Environment['PATH']=$Plan.environment.PATH
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
function Invariant {
    foreach($File in $Plan.frozen_inputs){if((Hash (Join-Path $Repo $File.path)) -ne $File.sha256){throw ('Frozen input changed: '+$File.path)}}
    foreach($Tool in $Plan.tools){if((Hash $Tool.path) -ne $Tool.sha256){throw ('Tool/runtime changed: '+$Tool.path)}}
    if((Hash $PlanPath) -ne $Result.plan_sha256){throw 'Repair plan changed'}
    if((Hash (Join-Path $Repair 'REVIEW_CURRENT.json')) -ne $Result.review_sha256){throw 'Current review/root proof changed'}
    foreach($Pair in @(@{name='REPAIR01_PLAN.json';sha256=$Result.plan_sha256},@{name='REVIEW_CURRENT.json';sha256=$Result.review_sha256})){
        $ArchivedProof=Join-Path $Run $Pair.name
        if((Test-Path -LiteralPath $ArchivedProof) -and (Hash $ArchivedProof) -ne $Pair.sha256){throw 'Archived repair plan/review proof changed'}
    }
    foreach($Image in $Result.images){if((Hash (Join-Path $Pkg $Image.path)) -ne $Image.sha256){throw 'Retained compiled image changed'}}
    foreach($Mapping in $Result.archived_inputs){if((Hash (Join-Path $Run $Mapping.archive)) -ne $Mapping.sha256){throw 'Repair archive changed'}}
    foreach($Receipt in $Result.children){
        foreach($Field in @('stdout','stderr')){
            if($Receipt.ContainsKey($Field) -and (Hash (Join-Path $Pkg $Receipt[$Field].path)) -ne $Receipt[$Field].sha256){throw 'Completed raw log changed'}
        }
    }
}
function Child($Spec){
    $Name=$Spec.name;$Prefix=Join-Path $Run $Name
    $Receipt=@{name=$Name;kind=$Spec.kind;argv=$Spec.argv;cwd=$Spec.cwd;status='STARTING';deadline_seconds=20;tree_kill_seconds=5;drain_seconds=2;started_utc=[DateTime]::UtcNow.ToString('o');timed_out=$false;tree_kill=$null;exit_code=$null}
    $Result.active_child=$Name;WriteJson $ResultPath $Result
    WriteJson ($Prefix+'.json') $Receipt
    $Watch=[Diagnostics.Stopwatch]::StartNew()
    $Cap=$null;$Kill=$null;$Exited=$false;$Drained=$false
    try{
        $Cap=StartCaptured $Spec.argv[0] @($Spec.argv|Select-Object -Skip 1) $Spec.cwd $Prefix
        if($null -ne $Cap.start_exception){throw $Cap.start_exception}
        if(!$Cap.process.WaitForExit(20000)){$Receipt.timed_out=$true}
    }catch{$Receipt.status='HARNESS_FAILURE';$Receipt.exception=$_.Exception.Message}
    finally{
        if($null -ne $Cap -and $Cap.started){
            try{
                if(!$Cap.process.HasExited){
                    $Receipt.tree_kill=@{argv=@($TreeKill,'/PID',[string]$Cap.process.Id,'/T','/F');finished=$false;exit_code=$null;exception=$null}
                    $Kill=StartCaptured $TreeKill @('/PID',[string]$Cap.process.Id,'/T','/F') $Spec.cwd ($Prefix+'.tree_kill')
                    if($null -ne $Kill.start_exception){throw $Kill.start_exception}
                    $Killed=$Kill.process.WaitForExit(5000)
                    $Receipt.tree_kill.finished=$Killed
                    if($Killed){$Receipt.tree_kill.exit_code=$Kill.process.ExitCode}
                }
            }catch{$Receipt.status='HARNESS_FAILURE';$Receipt.kill_exception=$_.Exception.Message}
        }
        if($null -ne $Kill -and $Kill.started){try{if(!$Kill.process.HasExited){$Kill.process.Kill()}}catch{$Receipt.status='HARNESS_FAILURE';$Receipt.helper_kill_exception=$_.Exception.Message}}
        if($null -ne $Cap -and $Cap.started){try{if(!$Cap.process.HasExited){$Receipt.fallback_tree_kill_requested=$true;$Cap.process.Kill($true)}}catch{$Receipt.status='HARNESS_FAILURE';$Receipt.fallback_kill_exception=$_.Exception.Message}}
        $Drained=DrainAll @($Cap,$Kill);$Receipt.drained=$Drained
        if($null -ne $Cap){
            if($Cap.started){try{$Exited=$Cap.process.HasExited;if($Exited){$Receipt.exit_code=$Cap.process.ExitCode}}catch{$Exited=$false}}
            try{$Cap.process.Dispose()}catch{}
        }
        if($null -ne $Kill){try{$Kill.process.Dispose()}catch{}}
    }
    if($Receipt.status -eq 'STARTING'){$Receipt.status=if($Receipt.timed_out){'TIMEOUT'}elseif(!$Exited -or !$Drained -or $Receipt.exit_code -ne 0){'FAIL'}else{'PROCESS_PASS_PENDING_MARKER'}}
    $Receipt.elapsed_seconds=$Watch.Elapsed.TotalSeconds
    foreach($Ext in @('stdout','stderr')){
        $Raw=$Prefix+'.'+$Ext+'.raw'
        if(Test-Path -LiteralPath $Raw){$Receipt[$Ext]=@{path=[IO.Path]::GetRelativePath($Pkg,$Raw).Replace('\','/');bytes=(Get-Item -LiteralPath $Raw).Length;sha256=(Hash $Raw)}}
        $KillRaw=$Prefix+'.tree_kill.'+$Ext+'.raw'
        if(Test-Path -LiteralPath $KillRaw){$Receipt.tree_kill[$Ext]=@{path=[IO.Path]::GetRelativePath($Pkg,$KillRaw).Replace('\','/');bytes=(Get-Item -LiteralPath $KillRaw).Length;sha256=(Hash $KillRaw)}}
    }
    if($Spec.kind -eq 'compile'){
        $Index=[Array]::IndexOf([string[]]$Spec.argv,'-o');$Image=$Spec.argv[$Index+1]
        if(Test-Path -LiteralPath $Image){$Receipt.artifact=@{path=[IO.Path]::GetRelativePath($Pkg,$Image).Replace('\','/');sha256=(Hash $Image);bytes=(Get-Item -LiteralPath $Image).Length};$Result.images+=,$Receipt.artifact}
    }else{
        $Image=$Spec.argv[1]
        $Receipt.execution_image=@{path=[IO.Path]::GetRelativePath($Pkg,$Image).Replace('\','/');sha256=(Hash $Image);bytes=(Get-Item -LiteralPath $Image).Length}
    }
    # Completed-child/raw/image evidence is durable before any marker/counter
    # decoding. The same object is subsequently updated, never replaced/deleted.
    $Result.children+=,$Receipt;$Result.hdl_children++;$Result.active_child=$null
    WriteJson ($Prefix+'.json') $Receipt;WriteJson $ResultPath $Result
    if($Receipt.status -eq 'PROCESS_PASS_PENDING_MARKER'){
        try{
            $Stdout=[IO.File]::ReadAllText($Prefix+'.stdout.raw')
            if($Spec.kind -eq 'simulation'){
                $Match=[regex]::Match($Stdout,'B43_C_PASS frames=19 faults=3 invalids=2 resets=9 outputs=(\d+) early=(\d+) holds=(\d+) gaps=(\d+)')
                if(!$Match.Success){throw 'Missing exact pass/counter marker'}
                $Receipt.counters=@{frames=19;faults=3;invalids=2;resets=9;outputs=[int]$Match.Groups[1].Value;early=[int]$Match.Groups[2].Value;holds=[int]$Match.Groups[3].Value;gaps=[int]$Match.Groups[4].Value}
                if($Receipt.counters.outputs -ne $Spec.expected_outputs -or $Receipt.counters.early -ne $Spec.expected_early -or $Receipt.counters.holds -lt 1){throw 'Exact output/early/hold counts differ'}
            }
            $Receipt.status='PASS'
        }catch{$Receipt.status='FAIL_MARKER_OR_COUNTERS';$Receipt.exception=$_.Exception.Message}
        WriteJson ($Prefix+'.json') $Receipt;WriteJson $ResultPath $Result
    }
    Write-Output ($Name+' '+$Receipt.status)
    if($Receipt.status -ne 'PASS'){throw ($Name+' '+$Receipt.status+'; fail-stop, no retry')}
}
if($Freeze -eq $Execute){throw 'Choose exactly one of -Freeze or -Execute'}
if($Freeze){
    if(Test-Path -LiteralPath $PlanPath){throw 'Repair plan already exists'}
    $Old=Get-Content -LiteralPath (Join-Path $Original 'results.json') -Raw|ConvertFrom-Json
    if((Hash (Join-Path $Original 'results.json')) -ne '9ae774ad19e3a6f3471f83824d2c0d4c865559a88ce1321e95ab5d725c537a0f' -or $Old.hdl_children -ne 5 -or $Old.oracle_imports -ne 1){throw 'Original failure ledger differs'}
    $Seal=Get-Content -LiteralPath (Join-Path $Pkg 'SOURCE_SEAL.json') -Raw|ConvertFrom-Json
    $Paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($File in $Seal.files){$null=$Paths.Add((Join-Path $Repo $File.path))}
    foreach($File in Get-ChildItem -LiteralPath $Original -Recurse -File){$null=$Paths.Add($File.FullName)}
    foreach($Rel in @('SOURCE_SEAL.json','TOOL_INVENTORY.json','PRECHECK_PLAN.json','EXECUTION_LOCK.json','.build/20261106T0933574171958Z/core_1x1_d8.vvp')){$null=$Paths.Add((Join-Path $Pkg $Rel))}
    foreach($File in Get-ChildItem -LiteralPath (Join-Path $Pkg 'review_history') -File){$null=$Paths.Add($File.FullName)}
    foreach($Rel in @('run_repair.ps1','README.md','INITIAL_REVIEW.json','REVIEW_PENDING.json')){$null=$Paths.Add((Join-Path $Repair $Rel))}
    $Inputs=@()
    foreach($Path in @($Paths|Sort-Object)){$Inputs+=@{path=[IO.Path]::GetRelativePath($Repo,$Path).Replace('\','/');sha256=(Hash $Path);bytes=(Get-Item -LiteralPath $Path).Length;archive=![IO.Path]::GetExtension($Path).Equals('.vvp',[StringComparison]::OrdinalIgnoreCase)}}
    $ToolPaths=@($IV,$VVP,$TreeKill,'C:/Program Files/Python312/python.exe',(Join-Path $Suite 'bin/libvvp-1.dll'))
    foreach($Name in @('libgcc_s_seh-1.dll','libstdc++-6.dll','libreadline8.dll','libwinpthread-1.dll','libtermcap-0.dll')){$ToolPaths+=Join-Path $Suite ('lib/'+$Name)}
    $Tools=@();foreach($Path in $ToolPaths){$Tools+=@{path=$Path;sha256=(Hash $Path);bytes=(Get-Item -LiteralPath $Path).Length}}
    $Id='repair01_'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
    $Build=Join-Path $Pkg ('.build/'+$Id);$Run=Join-Path $Pkg ('reports/'+$Id)
    $Archived=Join-Path $Original 'source/cores/image_processing/causal_palette_diffusion'
    $OldPlan=Get-Content -LiteralPath (Join-Path $Pkg 'PRECHECK_PLAN.json') -Raw|ConvertFrom-Json
    $Checks=@()
    foreach($P in $OldPlan.profiles){
        $Pixels=$P.w*$P.h;$Image=if($P.name -eq 'core_1x1_d8'){Join-Path $Pkg '.build/20261106T0933574171958Z/core_1x1_d8.vvp'}else{Join-Path $Build ($P.name+'.vvp')}
        if($P.name -ne 'core_1x1_d8'){
            $List=if($P.wrap){'example/files.f'}else{'files.f'}
            $Argv=@($IV,'-g2012','-Wall','-s','tb_causal_palette',('-Ptb_causal_palette.W='+$P.w),('-Ptb_causal_palette.H='+$P.h),('-Ptb_causal_palette.B='+$P.b),('-Ptb_causal_palette.T='+$P.t),('-Ptb_causal_palette.WRAP='+$P.wrap),'-o',$Image,'-f',$List,'sim/tb_causal_palette.sv')
            $Checks+=@{name='compile_'+$P.name;kind='compile';argv=$Argv;cwd=$Archived;deadline_seconds=20;tree_kill_seconds=5;drain_seconds=2}
        }
        $Checks+=@{name='sim_'+$P.name;kind='simulation';argv=@($VVP,$Image);cwd=(Join-Path $Original ('vectors/'+$P.name));expected_outputs=(19*$Pixels+3*[int][Math]::Floor($Pixels/2));expected_early=$(if($Pixels -gt 1){22}else{0});deadline_seconds=20;tree_kill_seconds=5;drain_seconds=2}
    }
    WriteJson $PlanPath @{schema='b43-c-repair01-plan-v1';status='SOURCE_REVIEW_PENDING_NOT_RUN';baseline='98176a8f970354ebd6191d0370662ab35ff53664';original_result_sha256=(Hash (Join-Path $Original 'results.json'));original_seal_sha256=(Hash (Join-Path $Pkg 'SOURCE_SEAL.json'));original_plan_sha256=(Hash (Join-Path $Pkg 'PRECHECK_PLAN.json'));run_id=$Id;report_directory=$Run;build_directory=$Build;frozen_inputs=$Inputs;tools=$Tools;environment=@{PATH=((Join-Path $Suite 'bin')+';'+(Join-Path $Suite 'lib')+';'+$env:PATH);PYTHONDONTWRITEBYTECODE='1';other_values='inherit'};checks=$Checks;expected_hdl_children=7;preparation_children=0;oracle_imports=0;oracle_preparations=0;automatic_retry=$false;fail_stop=$true;review_current='Separate REVIEW_CURRENT.json must bind this immutable plan hash after B review and root authorization'}
    Write-Output ('B43_C_REPAIR01_FROZEN plan_sha256='+(Hash $PlanPath)+' frozen_inputs='+$Inputs.Count+' tools='+$Tools.Count)
    exit 0
}
$Plan=Get-Content -LiteralPath $PlanPath -Raw|ConvertFrom-Json
$Review=Get-Content -LiteralPath (Join-Path $Repair 'REVIEW_CURRENT.json') -Raw|ConvertFrom-Json
if($Review.status -ne 'NO_BLOCKER_B_AND_ROOT' -or $Review.plan_sha256 -ne (Hash $PlanPath)){throw 'Repair review/root proof missing or differs'}
$Lock=Join-Path $Repair 'EXECUTION_LOCK.json'
if(Test-Path -LiteralPath $Lock){throw 'Repair already attempted; no retry'}
$Run=$Plan.report_directory;$Build=$Plan.build_directory;$ResultPath=Join-Path $Run 'results.json'
$Result=@{schema='b43-c-repair01-results-v1';status='INITIALIZING';plan_sha256=(Hash $PlanPath);review_sha256=(Hash (Join-Path $Repair 'REVIEW_CURRENT.json'));oracle_imports=0;oracle_preparations=0;preparation_children=0;hdl_children=0;children=@();images=@();archived_inputs=@();active_child=$null;original_result_sha256=$Plan.original_result_sha256;original_failure_preserved=$true;automatic_retry=$false;failure=$null}
Invariant
if(Test-Path -LiteralPath $Run){throw 'Repair report directory already exists'}
if(Test-Path -LiteralPath $Build){throw 'Repair build directory already exists'}
[IO.Directory]::CreateDirectory($Run)|Out-Null;[IO.Directory]::CreateDirectory($Build)|Out-Null
WriteJson $Lock @{plan_sha256=(Hash $PlanPath);run_id=$Plan.run_id;status='STARTED_NO_RETRY'}
WriteJson $ResultPath $Result
try{
    foreach($File in $Plan.frozen_inputs){
        if(!$File.archive){continue}
        $Relative='frozen_inputs/'+$File.path;$Dest=Join-Path $Run $Relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Dest))|Out-Null
        [IO.File]::Copy((Join-Path $Repo $File.path),$Dest,$false)
        $Result.archived_inputs+=@{path=$File.path;archive=$Relative;sha256=$File.sha256}
    }
    foreach($Path in @($PlanPath,(Join-Path $Repair 'REVIEW_CURRENT.json'))){[IO.File]::Copy($Path,(Join-Path $Run ([IO.Path]::GetFileName($Path))),$false)}
    WriteJson $ResultPath $Result
    foreach($Spec in $Plan.checks){Invariant;Child $Spec;Invariant}
    if($Result.hdl_children -ne 7 -or (($Result.children|ForEach-Object name) -join '|') -ne (($Plan.checks|ForEach-Object name) -join '|')){throw 'Repair child ledger differs'}
    Invariant;$Result.status='PASS'
}catch{$Result.status='FAIL_STOP';$Result.failure=$_.Exception.Message}
WriteJson $ResultPath $Result
if($Result.status -ne 'PASS'){throw $Result.failure}
Write-Output ('B43_C_REPAIR01_PASS results='+$ResultPath+' sha256='+(Hash $ResultPath))
