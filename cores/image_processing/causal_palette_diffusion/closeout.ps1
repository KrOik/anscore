# SPDX-License-Identifier: Apache-2.0
# Evidence-only closeout. No process launch, HDL, model/runner imports or cleanup.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Pkg=$PSScriptRoot;$Repo=[IO.Path]::GetFullPath((Join-Path $Pkg '../../..'))
function Hash([string]$P){(Get-FileHash -LiteralPath $P -Algorithm SHA256).Hash.ToLowerInvariant()}
function Rel([string]$P){[IO.Path]::GetRelativePath($Repo,$P).Replace('\','/')}
function WriteJson([string]$P,$V){if(Test-Path -LiteralPath $P){throw ('No overwrite: '+$P)};[IO.File]::WriteAllText($P,($V|ConvertTo-Json -Depth 50)+"`n",[Text.UTF8Encoding]::new($false))}
function Verify([string]$P,[string]$Expected){if((Hash $P) -ne $Expected){throw ('Hash mismatch: '+$P)}}
$Original=Join-Path $Pkg 'reports/20261106T0933574171958Z'
$OriginalReceipt=Join-Path $Original 'results.json'
$RepairPlanPath=Join-Path $Pkg 'repair01/REPAIR01_PLAN.json'
$RepairPlan=Get-Content -LiteralPath $RepairPlanPath -Raw|ConvertFrom-Json
$RepairReceipt=Join-Path $RepairPlan.report_directory 'results.json'
Verify $OriginalReceipt '9ae774ad19e3a6f3471f83824d2c0d4c865559a88ce1321e95ab5d725c537a0f'
Verify $RepairReceipt 'ebfd1104aa132b575215e0847e48532b2be546fad5217aa041b2a4dc76c7a2d6'
Verify $RepairPlanPath '2f6b1c495c3ca0a99f3b6caff8184a4f5556da5c4e8cd25bdbd1e7dcaecc5d7e'
$Old=Get-Content -LiteralPath $OriginalReceipt -Raw|ConvertFrom-Json
$New=Get-Content -LiteralPath $RepairReceipt -Raw|ConvertFrom-Json
$Seal=Get-Content -LiteralPath (Join-Path $Pkg 'SOURCE_SEAL.json') -Raw|ConvertFrom-Json
if($Old.hdl_children -ne 5 -or $New.hdl_children -ne 7 -or $New.status -ne 'PASS' -or $New.oracle_imports -ne 0 -or $New.preparation_children -ne 0){throw 'Child accounting mismatch'}
$Children=@($Old.children|Where-Object kind -ne preparation)+@($New.children)
$Pass=@($Children|Where-Object status -eq PASS);$Fail=@($Children|Where-Object status -ne PASS)
$Sims=@($Children|Where-Object kind -eq simulation);$SuccessfulSims=@($Sims|Where-Object status -eq PASS)
if($Children.Count -ne 12 -or $Pass.Count -ne 11 -or $Fail.Count -ne 1 -or $SuccessfulSims.Count -ne 4){throw 'Combined HDL ledger mismatch'}
if($Fail[0].name -ne 'sim_core_1x1_d8' -or $Fail[0].exit_code -ne -1073741515 -or $Fail[0].stdout.bytes -ne 0 -or $Fail[0].stderr.bytes -ne 0){throw 'Expected loader failure differs'}
$Current=@{};$Archives=@{};$Mapping=@()
foreach($File in $Seal.files){
    $Path=Join-Path $Repo $File.path;$Archive=Join-Path $Original ('source/'+$File.path)
    Verify $Path $File.sha256;Verify $Archive $File.sha256
    $Current[$File.path]=$File.sha256;$Archives[(Rel $Archive)]=$File.sha256
    $Mapping+=@{current=$File.path;checked_archive=(Rel $Archive);sha256=$File.sha256;raw_bytes_equal=$true}
}
foreach($File in $RepairPlan.frozen_inputs){Verify (Join-Path $Repo $File.path) $File.sha256}
foreach($File in $New.archived_inputs){
    Verify (Join-Path $RepairPlan.report_directory $File.archive) $File.sha256
    $Archives[(Rel (Join-Path $RepairPlan.report_directory $File.archive))]=$File.sha256
}
foreach($File in $RepairPlan.frozen_inputs|Where-Object {$_.path -like '*/repair01/*' -and $_.archive}){
    $Archive=Join-Path $RepairPlan.report_directory ('frozen_inputs/'+$File.path)
    $Current[$File.path]=$File.sha256
    $Mapping+=@{current=$File.path;checked_archive=(Rel $Archive);sha256=$File.sha256;raw_bytes_equal=$true}
}
$Tools=@();foreach($Tool in $RepairPlan.tools){Verify $Tool.path $Tool.sha256;$Tools+=@{path=$Tool.path;sha256=$Tool.sha256;bytes=$Tool.bytes}}
$Raw=@{};$ChildReceipts=@{}
foreach($Pair in @(@{receipt=$Old;directory=$Original},@{receipt=$New;directory=$RepairPlan.report_directory})){
    foreach($Child in $Pair.receipt.children){
        foreach($Stream in @('stdout','stderr')){$P=Join-Path $Pkg $Child.$Stream.path;Verify $P $Child.$Stream.sha256;$Raw[(Rel $P)]=$Child.$Stream.sha256}
        if(!$Child.drained -or $Child.timed_out -or $null -ne $Child.tree_kill){throw 'Unexpected timeout/drain/termination helper'}
        $P=Join-Path $Pair.directory ($Child.name+'.json');$ChildReceipts[(Rel $P)]=(Hash $P)
    }
}
if($Raw.Count -ne 26){throw 'Expected26raw streams'}
$Vectors=@{}
foreach($Vector in $Old.vectors){$P=Join-Path $Original ('vectors/'+$Vector.path);Verify $P $Vector.sha256;$Vectors[(Rel $P)]=$Vector.sha256}
if($Vectors.Count -ne 12){throw 'Expected12literal vector files'}
$VerifiedImages=@{};$ImageRows=@()
foreach($Sim in $SuccessfulSims){$Image=$Sim.execution_image;$P=Join-Path $Pkg $Image.path;Verify $P $Image.sha256;$VerifiedImages[(Rel $P)]=$Image.sha256;$ImageRows+=@{path=(Rel $P);sha256=$Image.sha256;successful_simulation=$Sim.name}}
if($VerifiedImages.Count -ne 4){throw 'Expected4unique successful images'}
$FailedImage=Join-Path $Pkg '.build/20261106T0933574171958Z/core_1x1_d8.vvp'
Verify $FailedImage '53618ab8de683e7fe669b5a5e8d729c1289e4e3a5d594015cafe02cab335cfc7'
if(!$VerifiedImages.ContainsKey((Rel $FailedImage))){throw 'Loader-failed shared image absent from successful simulations'}
$FailedImages=@{};$FailedImages[(Rel $FailedImage)]=(Hash $FailedImage)
$Counts=@{frames=0;faults=0;invalids=0;resets=0;outputs=0;early=0;holds=0;gaps=0}
foreach($Sim in $SuccessfulSims){foreach($Key in @($Counts.Keys)){$Counts[$Key]+=[int]$Sim.counters.$Key};if($Sim.stderr.bytes -ne 0){throw 'Simulationstderr not empty'}}
if($Counts.outputs -ne 6166 -or $Counts.frames -ne 76 -or $Counts.early -ne 66 -or $Counts.resets -ne 36){throw 'Finite coverage total mismatch'}
$ProofPath=Join-Path $Pkg 'repair01/REVIEW_CURRENT.json'
Verify $ProofPath $New.review_sha256
Verify (Join-Path $RepairPlan.report_directory 'REVIEW_CURRENT.json') $New.review_sha256
Verify (Join-Path $RepairPlan.report_directory 'REPAIR01_PLAN.json') (Hash $RepairPlanPath)
$ReceiptRows=@(@{path=(Rel $OriginalReceipt);sha256=(Hash $OriginalReceipt);status='FAIL_STOP';hdl_children=5;hdl_pass=4;hdl_fail=1;preparations=1},@{path=(Rel $RepairReceipt);sha256=(Hash $RepairReceipt);status='PASS';hdl_children=7;hdl_pass=7;hdl_fail=0;preparations=0})
$Qualifier=@{
    schema='anscore-b43-causal-palette-qualification-v1';status='PASS_WITH_RETAINED_LOADER_FAILURE';baseline='98176a8f970354ebd6191d0370662ab35ff53664';receipts=$ReceiptRows;
    effective_finite_checks=11;successful_simulations=4;current_qualification_pass_children=11;current_qualification_successful_simulations=4;total_hdl_child_executions=12;total_pass_children=11;total_fail_children=1;historical_hdl_failures=1;total_simulation_executions=5;
    planning_python_calls=0;oracle_import_attempts=1;preparation_attempts=1;oracle_completed_preparations=1;repair_oracle_imports=0;repair_preparations=0;metadata_freeze_powershell_calls=5;closeout_powershell_calls=1;closeout_python_calls=0;
    counters=$Counts;core_exact_outputs=3870;actual_composition_exact_outputs=2296;maximum_dimensions='SYNTAX_ONLY_4096x4096';
    source_mapping=$Mapping;current_inputs=$Current;source_archive=$Archives;raw_logs=$Raw;child_receipts=$ChildReceipts;vectors=$Vectors;tools=$Tools;
    original_plan=@{path=(Rel (Join-Path $Pkg 'PRECHECK_PLAN.json'));sha256=(Hash (Join-Path $Pkg 'PRECHECK_PLAN.json'))};source_seal=@{path=(Rel (Join-Path $Pkg 'SOURCE_SEAL.json'));sha256=(Hash (Join-Path $Pkg 'SOURCE_SEAL.json'))};repair_plan=@{path=(Rel $RepairPlanPath);sha256=(Hash $RepairPlanPath)};repair_review=@{path=(Rel $ProofPath);sha256=(Hash $ProofPath)};
    verified_compiled_image_sha256=$VerifiedImages;failed_vvps_to_retain=$FailedImages;shared_failure_success_image=(Rel $FailedImage);retained_images=$ImageRows;compiled_binary_cleanup_count=0;
    loader_failure=@{status='WINDOWS_DLL_NOT_FOUND_0xC0000135_BEFORE_PROGRAM_ENTRY';exit_code=-1073741515;stdout_bytes=0;stderr_bytes=0;hdl_output_observed=$false;image=(Rel $FailedImage);image_sha256=(Hash $FailedImage);original_environment='Inherited PATH was not captured in original receipt; postfailure read-only PATH inspection found no OSS suite entries';repair='Only new standalone runner childPATH prepends suite/bin+suite/lib; originalRTL/model/TB/runner/plan/seal unchanged';runtime_hashes_frozen=$true};
    repaired_argv=$RepairPlan.checks;original_argv=@($Old.children|ForEach-Object {@{name=$_.name;argv=$_.argv;cwd=$_.cwd}});repair_environment=$RepairPlan.environment;
    reset_scope='36 live reset probes with successful complete recovery; finite simulation, not exhaustive state/phase coverage';
    diagnostics='Only unchanged RGB2gray inherited-timescale warning in actual compile; all simulation stderr empty';automatic_retry=$false;timeout_count=0;cleanup_count=0;synthesis='NOT_RUN';pnr='NOT_RUN';sta='NOT_RUN';board='NOT_RUN';ppa='NOT_RUN';hardware='HW_UNVERIFIED'
}
$QualificationPath=Join-Path $Pkg 'QUALIFICATION.json';WriteJson $QualificationPath $Qualifier
$Bridge=@{
    schema='anscore-b43-worker-c-delivery-v1';name='causal_palette_diffusion';package_root=(Rel $Pkg);baseline='98176a8f970354ebd6191d0370662ab35ff53664';new_capability='Causal raster two-level runtime palette error diffusion with two signed error rows and no input/result frame; actual unchanged RGB888 grayscale composition';status=@('LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED');
    receipt=(Rel $RepairReceipt);receipt_sha256=(Hash $RepairReceipt);receipts=$ReceiptRows;plan=(Rel $RepairPlanPath);plan_sha256=(Hash $RepairPlanPath);original_plan=(Rel (Join-Path $Pkg 'PRECHECK_PLAN.json'));original_plan_sha256=(Hash (Join-Path $Pkg 'PRECHECK_PLAN.json'));qualification=(Rel $QualificationPath);qualification_sha256=(Hash $QualificationPath);
    effective_finite_checks=11;successful_simulations=4;current_qualification_pass_children=11;current_qualification_successful_simulations=4;historical_hdl_failures=1;total_hdl_child_executions=12;total_simulation_executions=5;total_pass_children=11;total_fail_children=1;
    prior_evidence=@{receipts=@($ReceiptRows[0]);failed_images=$FailedImages;historical_hdl_failures=1};prior_failures=@($Qualifier.loader_failure);repairs=@(@{name='REPAIR01_DLL_ENVIRONMENT_ONLY';receipt=(Rel $RepairReceipt);receipt_sha256=(Hash $RepairReceipt);plan=(Rel $RepairPlanPath);plan_sha256=(Hash $RepairPlanPath);hdl_children=7;oracle_imports=0;preparations=0;source_changed=$false;retained_shared_image=(Rel $FailedImage)});
    planning_python_calls=0;oracle_import_attempts=1;preparation_attempts=1;closeout_python_calls=0;closeout_powershell_calls=1;metadata_freeze_powershell_calls=5;
    source_mapping=$Mapping;current_source_sha256=$Current;source_archive=$Archives;raw_logs=$Raw;vectors=$Vectors;tools=$Tools;verified_compiled_image_sha256=$VerifiedImages;failed_vvps_to_retain=$FailedImages;shared_failure_success_image=(Rel $FailedImage);counters=$Counts;review_proof_sha256=(Hash $ProofPath);closeout_source_sha256=(Hash $PSCommandPath);raw_bytes_preserved=$true;automatic_retry=$false;cleanup_count=0;
    frozen_documents_unchanged=$true;manifest_unchanged=$true;state_metadata='STATUS.json is the current evidence status; frozen README/STATUS.md describe pre-execution candidate state';scope='Finite syntax and exact functional simulation only; no synthesis/PnR/STA/board/PPA'
}
$BridgePath=Join-Path $Pkg 'B43_DELIVERY.json';WriteJson $BridgePath $Bridge
WriteJson (Join-Path $Pkg 'STATUS.json') @{schema='b43-c-current-status-v1';status=@('LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED');delivery=(Rel $BridgePath);delivery_sha256=(Hash $BridgePath);qualification=(Rel $QualificationPath);qualification_sha256=(Hash $QualificationPath);retained_loader_failure=1;successful_simulations=4;exact_outputs=6166;all_original_source_bytes_unchanged=$true;manifest_unchanged=$true}
Write-Output ('B43_C_CLOSEOUT_PASS qualification_sha256='+(Hash $QualificationPath)+' delivery_sha256='+(Hash $BridgePath)+' status_sha256='+(Hash (Join-Path $Pkg 'STATUS.json')))
