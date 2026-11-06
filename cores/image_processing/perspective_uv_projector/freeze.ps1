param([switch]$Freeze,[switch]$Amendment01)
$ErrorActionPreference='Stop'
if(-not $Freeze){throw 'Metadata-only -Freeze required; no model, Python, HDL, synthesis or Git execution'}
$Pkg=$PSScriptRoot
$Repo=[IO.Path]::GetFullPath((Join-Path $Pkg '../../..'))
$Prefix='cores/image_processing/perspective_uv_projector'
$PlanPath=Join-Path $Pkg 'PRECHECK_PLAN.json'
$SealPath=Join-Path $Pkg 'SOURCE_SEAL.json'
function Hash([string]$path){return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
$Initial=[ordered]@{
    'run_checks.py'='88f400bb9ad67836565b362e87c32d4b7028293403950a5025eea3242643b6c4'
    'freeze.ps1'='319bda3898ec063f319c14bc205eda6d44b07e1e25b78aa01eff18be087f5a43'
    'PRECHECK_PLAN.json'='20adcb88a6a236b6022682951bf36e722412a70eb4768b22b4271bb5acd07f69'
    'SOURCE_SEAL.json'='8ddba858424d3ef0d9a7fb5313f496715015c49ce571550933be497f36d22b21'
}
if($Amendment01){
    # Root explicitly authorized source-only cleanup/invariant repairs; no execution occurred.
    foreach($name in $Initial.Keys){if((Hash (Join-Path $Pkg "planning/$name.initial")) -cne $Initial[$name]){throw "Initial preservation mismatch: $name"}}
    if((Hash $PlanPath) -cne $Initial['PRECHECK_PLAN.json'] -or (Hash $SealPath) -cne $Initial['SOURCE_SEAL.json']){throw 'Amendment01 can replace only the preserved original plan/seal'}
}elseif((Test-Path -LiteralPath $PlanPath) -or (Test-Path -LiteralPath $SealPath)){throw 'Initial freeze already exists; no automatic replacement'}
function WriteJson([string]$path,$value){
    $json=($value|ConvertTo-Json -Depth 18).Replace("`r`n","`n")+"`n"
    $raw=[Text.UTF8Encoding]::new($false).GetBytes($json)
    $mode=if($Amendment01){[IO.FileMode]::Create}else{[IO.FileMode]::CreateNew}
    $stream=[IO.File]::Open($path,$mode,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($raw,0,$raw.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
$Files=@('.gitattributes','.gitignore','ARCHITECTURE.md','README.md','STATUS.md','SOURCES.md','LICENSE','manifest.json','references.json','files.f','example/files.f','example/perspective_indexed_triangle.sv','rtl/perspective_uv_projector.sv','sim/tb_perspective_uv.sv','sim/tb_perspective_indexed.sv','reference_model.py','run_checks.py','freeze.ps1')
if($Amendment01){foreach($name in $Initial.Keys){$Files+="planning/$name.initial"}}
$Sources=[ordered]@{}
foreach($name in $Files){$Sources["$Prefix/$name"]=Hash (Join-Path $Pkg $name)}
foreach($name in @('cores/image_processing/triangle_rgb_raster/rtl/triangle_rgb_raster.sv','cores/image_processing/indexed_texture_sampler/rtl/indexed_texture_sampler.sv')){$Sources[$name]=Hash (Join-Path $Repo $name)}
$Suite=Join-Path $Repo 'tools/oss-cad-suite/oss-cad-suite'
$Bin=Join-Path $Suite 'bin';$Lib=Join-Path $Suite 'lib';$Ivl=Join-Path $Lib 'ivl'
$Python='C:\Program Files\Python312\python.exe'
$Taskkill=Join-Path $env:SystemRoot 'System32/taskkill.exe'
$ToolPaths=@((Join-Path $Bin 'iverilog.exe'),(Join-Path $Bin 'vvp.exe'),$Python,$Taskkill,(Join-Path $Bin 'libvvp-1.dll'))
foreach($name in @('libgcc_s_seh-1.dll','libstdc++-6.dll','libreadline8.dll','libwinpthread-1.dll','libtermcap-0.dll')){$ToolPaths+=Join-Path $Lib $name}
foreach($name in @('ivl.exe','ivlpp.exe','null.conf','null.tgt','vvp.conf','vvp.tgt','system.vpi','v2005_math.vpi','v2009.vpi','va_math.vpi')){$ToolPaths+=Join-Path $Ivl $name}
foreach($name in @('python3.dll','python312.dll','vcruntime140.dll','vcruntime140_1.dll')){$ToolPaths+=Join-Path (Split-Path $Python -Parent) $name}
$Tools=[ordered]@{};foreach($name in $ToolPaths){$Tools[$name]=Hash $name}
$Profiles=@(
    [ordered]@{name='core_q1_t1';q=1;tag=1;wrap=0;width=8;height=7;tw=5;th=4;expected_counters=[ordered]@{configs=12;outputs=144;config_faults=3;resets=9};output_bound=144},
    [ordered]@{name='core_q16_t32';q=16;tag=32;wrap=0;width=8;height=7;tw=5;th=4;expected_counters=[ordered]@{configs=12;outputs=144;config_faults=3;resets=9};output_bound=144},
    [ordered]@{name='actual_8x7_tex5x4_q16_t8';q=16;tag=8;wrap=1;width=8;height=7;tw=5;th=4;expected_counters=[ordered]@{configs=9;config_faults=2;resets=7};output_bound=512},
    [ordered]@{name='actual_256x256_tex256x256_q16_t32';q=16;tag=32;wrap=1;width=256;height=256;tw=256;th=256;expected_counters=[ordered]@{configs=9;config_faults=2;resets=7};output_bound=512}
)
$Archive=Join-Path $Pkg "reports/<stamp>/source/$Prefix"
$Report=Join-Path $Pkg 'reports/<stamp>'
$Build=Join-Path $Pkg '.build/<stamp>'
$Children=@()
function Child([string]$name,[string]$kind,[string[]]$argv,[string]$cwd,$marker){return [ordered]@{name=$name;kind=$kind;argv=$argv;cwd=$cwd;marker=$marker;execution_deadline_seconds=20;tree_kill_seconds=5;drain_seconds=2}}
foreach($p in $Profiles){
    $argv=@($Python,'-I','-B',(Join-Path $Archive 'reference_model.py'))
    foreach($key in @('q','tag','wrap','width','height','tw','th')){$argv+=@("--$key",[string]$p[$key])}
    $argv+=@('--output',(Join-Path $Report $p.name))
    $Children+=Child "prepare_$($p.name)" 'PREPARATION' $argv $Archive 'B45_C_PREP_PASS '
}
$Iverilog=Join-Path $Bin 'iverilog.exe';$Vvp=Join-Path $Bin 'vvp.exe'
$Children+=Child 'syntax_default' 'HDL_SYNTAX' @($Iverilog,'-g2012','-Wall','-tnull','-s','perspective_uv_projector','-f','files.f') $Archive $null
$Children+=Child 'syntax_actual_maximum' 'HDL_SYNTAX' @($Iverilog,'-g2012','-Wall','-tnull','-s','perspective_indexed_triangle','-Pperspective_indexed_triangle.WIDTH=256','-Pperspective_indexed_triangle.HEIGHT=256','-Pperspective_indexed_triangle.TEX_WIDTH=256','-Pperspective_indexed_triangle.TEX_HEIGHT=256','-Pperspective_indexed_triangle.Q_W=16','-Pperspective_indexed_triangle.TAG_W=32','-f','example/files.f') $Archive $null
foreach($p in $Profiles){
    $image=Join-Path $Build "$($p.name).vvp"
    if($p.wrap){
        $top='tb_perspective_indexed';$testbench='sim/tb_perspective_indexed.sv';$list='example/files.f'
        $parameters=@("-P$top.W=$($p.width)","-P$top.H=$($p.height)","-P$top.TW=$($p.tw)","-P$top.TH=$($p.th)")
    }else{$top='tb_perspective_uv';$testbench='sim/tb_perspective_uv.sv';$list='files.f';$parameters=@()}
    $argv=@($Iverilog,'-g2012','-Wall','-s',$top,"-P$top.Q=$($p.q)","-P$top.T=$($p.tag)")+$parameters+@('-o',$image,'-f',$list,$testbench)
    $Children+=Child "compile_$($p.name)" 'HDL_COMPILE' $argv $Archive $null
    $Children+=Child "sim_$($p.name)" 'HDL_SIMULATION' @($Vvp,$image) (Join-Path $Report $p.name) 'B45_C_PASS '
}
$Plan=[ordered]@{
    schema='anscore-b45-c-finite-plan-v1';baseline='a0602fb2dac20db7c524297371a19f5f580980df';status='SOURCE_REVIEW_PENDING_NOT_EXECUTED'
    source_only_amendment=$(if($Amendment01){1}else{0});preserved_initial_sha256=$(if($Amendment01){$Initial}else{[ordered]@{}})
    required_review_proof='REVIEW_CURRENT.json';required_review_status='NO_BLOCKER_ROOT';execution_gate='B45_PERSPECTIVE_UV_ONCE_01'
    authorization='Complete independent root full-source NO_BLOCKER review and separate explicit unique root execution gate before model/HDL execution'
    automatic_retry=$false;fail_stop=$true;source_sha256=$Sources;tools=$Tools;path_prefix=@($Bin,$Lib);taskkill=$Taskkill
    profiles=$Profiles;children=$Children;expected_preparation_children=4;expected_hdl_children=10;successful_simulations_if_pass=4
    oracle_definition_loads_if_pass=4;numerical_preparations_if_pass=4;runner_oracle_imports=0;planning_model_calls=0
    execution_deadline_seconds=20;tree_kill_seconds=5;drain_seconds=2
    durable_process_evidence='Flush/fsync JSON and raw bytes; persist target/helper PID, exit, raw SHA and timing before marker/image/preparation parsing'
    cleanup_order='All helper/persist exceptions still take nonwaiting helper/target kills; at most one helper <=5s with elapsed recheck, then one shared <=2s target exit and reader drain observation; final helper poll without another wait'
    evidence_invariants='Before every child pin current and archived plan/seal/review, source/tool bytes, vectors/preparation receipts/images, and every prior child record/raw file hash and byte length'
    finite_scope='Two syntax + four compile/simulation pairs; four direct archived preparation children. Maximum actual profile uses sparse <=6x6 and 3x3 triangles, not full-screen workload.'
    counter_policy='Fixed config/fault/reset counts; exact output total generated once after gate and bound <=512; TB separately checks every config count, every fragment and final total.'
    excluded='No model imports in runner, planning model/AST/HDL calls, synthesis, PnR, STA, board, PPA, cleanup, staging or Git mutation'
    image_retention='Retain every compiled image at its original .build path on success or failure; no copy/delete of binary images'
}
WriteJson $PlanPath $Plan
$Sealed=[ordered]@{};foreach($name in $Sources.Keys){$Sealed[$name]=$Sources[$name]};$Sealed["$Prefix/PRECHECK_PLAN.json"]=Hash $PlanPath
WriteJson $SealPath ([ordered]@{schema='anscore-b45-c-source-seal-v1';baseline=$Plan.baseline;status='SOURCE_ONLY_NOT_RUN';source_only_amendment=$(if($Amendment01){1}else{0});preserved_initial_sha256=$(if($Amendment01){$Initial}else{[ordered]@{}});source_sha256=$Sealed;tools=$Tools;plan_sha256=(Hash $PlanPath);planning_model_calls=0;runner_calls=0;hdl_calls=0;metadata_freeze_calls=$(if($Amendment01){2}else{1})})
[ordered]@{status='SEALED_SOURCE_ONLY_NOT_EXECUTED';plan_sha256=(Hash $PlanPath);seal_sha256=(Hash $SealPath);sources=$Sealed.Count;tools=$Tools.Count;preparations=4;hdl_children=10;simulations=4;model_calls=0;hdl_calls=0}|ConvertTo-Json
