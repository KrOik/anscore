param([switch]$Freeze,[switch]$Amendment01)
$ErrorActionPreference='Stop'
if(-not $Freeze){throw 'Metadata-only -Freeze required; this script never executes a model or HDL tool'}
$Pkg=$PSScriptRoot
$Repo=[IO.Path]::GetFullPath((Join-Path $Pkg '../../..'))
$Prefix='cores/image_processing/tetrahedral_rgb_grade'
$PlanPath=Join-Path $Pkg 'PRECHECK_PLAN.json'
$SealPath=Join-Path $Pkg 'SOURCE_SEAL.json'
function Hash([string]$path){return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
function WriteJson([string]$path,$value){$json=($value|ConvertTo-Json -Depth 15).Replace("`r`n","`n")+"`n";$raw=[Text.UTF8Encoding]::new($false).GetBytes($json);$stream=[IO.File]::Open($path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($raw,0,$raw.Length);$stream.Flush($true)}finally{$stream.Dispose()}}
$Initial=[ordered]@{'PRECHECK_PLAN.json'='b3c86a39b588e0a31545cae5d7ee632bccd8884b88fc5f78b1a7563ca816b985';'SOURCE_SEAL.json'='ddaeb6fb249ba951a5421dea2085cbe697b8637539eccccd3f1c28b5ceed2044';'run_checks.py'='402179f524f0fb4c9c450d1d0296a4dba93a32e0f593fdcc89895ae2df9378cf';'freeze.ps1'='21d1e5cdd6feda4130ed31465b961b50508702ebfd8fee59df257d9f1d3c06c8'}
if(-not $Amendment01){throw 'The initial source-only freeze is preserved; only explicitly authorized -Amendment01 metadata revision is available'}
foreach($name in $Initial.Keys){if((Hash (Join-Path $Pkg "planning/$name.initial")) -cne $Initial[$name]){throw "Initial preservation mismatch: $name"}}
if((Hash $PlanPath) -cne $Initial['PRECHECK_PLAN.json'] -or (Hash $SealPath) -cne $Initial['SOURCE_SEAL.json']){throw 'Amendment01 can replace only the preserved initial plan/seal; no automatic retry'}
$Files=@('.gitattributes','.gitignore','ARCHITECTURE.md','README.md','STATUS.md','SOURCES.md','LICENSE','manifest.json','references.json','files.f','example/files.f','example/graded_luma_preview.sv','rtl/tetrahedral_rgb_grade.sv','sim/tb_tetrahedral_grade.sv','reference_model.py','run_checks.py','freeze.ps1','planning/PRECHECK_PLAN.json.initial','planning/SOURCE_SEAL.json.initial','planning/run_checks.py.initial','planning/freeze.ps1.initial')
$Sources=[ordered]@{}
foreach($name in $Files){$Sources["$Prefix/$name"]=Hash (Join-Path $Pkg $name)}
$Gray='cores/system/extended_library/src/isp_rgb2gray.v'
$Sources[$Gray]=Hash (Join-Path $Repo $Gray)
$Suite=Join-Path $Repo 'tools/oss-cad-suite/oss-cad-suite'
$Bin=Join-Path $Suite 'bin';$Lib=Join-Path $Suite 'lib'
$Python='C:\Program Files\Python312\python.exe'
$Taskkill=Join-Path $env:SystemRoot 'System32/taskkill.exe'
$ToolPaths=@((Join-Path $Bin 'iverilog.exe'),(Join-Path $Bin 'vvp.exe'),$Python,$Taskkill,(Join-Path $Bin 'libvvp-1.dll'))
foreach($name in @('libgcc_s_seh-1.dll','libstdc++-6.dll','libreadline8.dll','libwinpthread-1.dll','libtermcap-0.dll')){$ToolPaths+=Join-Path $Lib $name}
$Tools=[ordered]@{};foreach($name in $ToolPaths){$Tools[$name]=Hash $name}
$Profiles=@(
[ordered]@{name='tiny_1x1_b8_g1_t1';width=1;height=1;bits=8;grid=1;tag=1;wrap=0},
[ordered]@{name='core_5x3_b10_g2_t8';width=5;height=3;bits=10;grid=2;tag=8;wrap=0},
[ordered]@{name='core_9x4_b12_g4_t32';width=9;height=4;bits=12;grid=4;tag=32;wrap=0},
[ordered]@{name='actual_7x3_b8_g3_t8';width=7;height=3;bits=8;grid=3;tag=8;wrap=1})
foreach($p in $Profiles){$n=$p.width*$p.height;$frames=13+$p.wrap;$extra=[int]($n -gt 1);$p.expected_counters=[ordered]@{frames=$frames;faults=1;config_faults=2;invalids=10+$p.wrap;resets=9+$p.wrap;outputs=$frames*$n+$extra;early=$frames*($n-1)+$extra}}
$Report=Join-Path $Pkg 'reports/<stamp>'
$Build=Join-Path $Pkg '.build/<stamp>'
$Archive=Join-Path $Report "source/$Prefix"
$Children=@()
function Child([string]$name,[string]$kind,[string[]]$argv,[string]$cwd,$marker){return [ordered]@{name=$name;kind=$kind;argv=$argv;cwd=$cwd;marker=$marker;execution_deadline_seconds=20;tree_kill_seconds=5;drain_seconds=2}}
foreach($p in $Profiles){
 $argv=@($Python,'-I','-B',(Join-Path $Archive 'reference_model.py'))
 foreach($key in @('width','height','bits','grid','tag','wrap')){$argv+=@("--$key",[string]$p[$key])}
 $argv+=@('--output',(Join-Path $Report $p.name))
 $Children+=Child "prepare_$($p.name)" 'PREPARATION' $argv $Archive 'B44_C_PREP_PASS '
}
$Iverilog=Join-Path $Bin 'iverilog.exe';$Vvp=Join-Path $Bin 'vvp.exe'
$Children+=Child 'syntax_default' 'HDL_SYNTAX' @($Iverilog,'-g2012','-Wall','-tnull','-s','tetrahedral_rgb_grade','-f','files.f') $Archive $null
$Children+=Child 'syntax_maximum' 'HDL_SYNTAX' @($Iverilog,'-g2012','-Wall','-tnull','-s','tetrahedral_rgb_grade','-Ptetrahedral_rgb_grade.WIDTH=4096','-Ptetrahedral_rgb_grade.HEIGHT=4096','-Ptetrahedral_rgb_grade.BITS=12','-Ptetrahedral_rgb_grade.GRID_LOG2=4','-Ptetrahedral_rgb_grade.TAG_W=32','-f','files.f') $Archive $null
$Children+=Child 'syntax_actual_maximum' 'HDL_SYNTAX' @($Iverilog,'-g2012','-Wall','-tnull','-s','graded_luma_preview','-Pgraded_luma_preview.WIDTH=4096','-Pgraded_luma_preview.HEIGHT=4096','-Pgraded_luma_preview.GRID_LOG2=4','-Pgraded_luma_preview.TAG_W=32','-f','example/files.f') $Archive $null
foreach($p in $Profiles){
 $image=Join-Path $Build "$($p.name).vvp"
 $argv=@($Iverilog,'-g2012','-Wall','-s','tb_tetrahedral_grade',"-Ptb_tetrahedral_grade.W=$($p.width)","-Ptb_tetrahedral_grade.H=$($p.height)","-Ptb_tetrahedral_grade.B=$($p.bits)","-Ptb_tetrahedral_grade.G=$($p.grid)","-Ptb_tetrahedral_grade.T=$($p.tag)","-Ptb_tetrahedral_grade.WRAP=$($p.wrap)",'-o',$image,'-f','example/files.f','sim/tb_tetrahedral_grade.sv')
 $Children+=Child "compile_$($p.name)" 'HDL_COMPILE' $argv $Archive $null
 $Children+=Child "sim_$($p.name)" 'HDL_SIMULATION' @($Vvp,$image) (Join-Path $Report $p.name) 'B44_C_PASS '
}
$Plan=[ordered]@{schema='anscore-b44-c-finite-plan-v1';baseline='09de72c578b3099d4e867c739118faa7607f663d';status='SOURCE_REVIEW_PENDING_NOT_EXECUTED';source_only_amendment=1;preserved_initial_sha256=$Initial;required_review_proof='REVIEW_CURRENT.json';required_review_status='NO_BLOCKER_ROOT';execution_gate='B44_TETRAHEDRAL_ONCE_01';authorization='Complete independent root source NO_BLOCKER review and explicit root unique execution gate required before any model or HDL execution';automatic_retry=$false;fail_stop=$true;source_sha256=$Sources;tools=$Tools;path_prefix=@($Bin,$Lib);taskkill=$Taskkill;profiles=$Profiles;children=$Children;expected_preparation_children=4;expected_hdl_children=11;successful_simulations_if_pass=4;oracle_definition_loads_if_pass=4;numerical_preparations_if_pass=4;runner_oracle_imports=0;planning_model_calls=0;execution_deadline_seconds=20;tree_kill_seconds=5;drain_seconds=2;durable_process_evidence='flush/fsync JSON and raw bytes; persist exit, survivor PID, raw SHA and timing before marker/image metadata parsing';cleanup_order='At most one taskkill tree helper within 5s, then nonwaiting target.kill fallback, then one shared 2s target-exit/reader drain deadline';scope='Finite source syntax and exact simulation only; no inherited model/runner/auditor imports or execution, synthesis/PnR/STA/board/PPA, cleanup/staging/commit';image_retention='All exact compiled images retained at original .build paths on success or failure; no copying/deleting binary images'}
WriteJson $PlanPath $Plan
$Sealed=[ordered]@{};foreach($name in $Sources.Keys){$Sealed[$name]=$Sources[$name]};$Sealed["$Prefix/PRECHECK_PLAN.json"]=Hash $PlanPath
WriteJson $SealPath ([ordered]@{schema='anscore-b44-c-source-seal-v1';baseline=$Plan.baseline;status='SOURCE_ONLY_NOT_RUN';source_only_amendment=1;preserved_initial_sha256=$Initial;source_sha256=$Sealed;tools=$Tools;plan_sha256=(Hash $PlanPath);planning_model_calls=0;runner_calls=0;hdl_calls=0;metadata_freeze_calls=2})
[ordered]@{status='SEALED_SOURCE_ONLY_NOT_EXECUTED';plan_sha256=(Hash $PlanPath);seal_sha256=(Hash $SealPath);sources=$Sealed.Count;tools=$Tools.Count;preparations=4;hdl_children=11;simulations=4;model_calls=0;hdl_calls=0}|ConvertTo-Json
