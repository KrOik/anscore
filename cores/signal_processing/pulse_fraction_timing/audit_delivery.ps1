# SPDX-License-Identifier: Apache-2.0
# Independent post-run byte/receipt audit; no Python, HDL or model execution.
$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $packageRoot '../../..'))
$packageRelative = 'cores/signal_processing/pulse_fraction_timing'
$priorRelative = 'reports/20261106T063315_715768Z/results.json'
$receiptRelative = 'repairs/repair01/reports/20261106T063818_810437Z/results.json'
$priorHome = Split-Path -Parent (Join-Path $packageRoot $priorRelative)
$receiptHome = Split-Path -Parent (Join-Path $packageRoot $receiptRelative)
$prior = Get-Content -Raw -LiteralPath (Join-Path $packageRoot $priorRelative) | ConvertFrom-Json
$receipt = Get-Content -Raw -LiteralPath (Join-Path $packageRoot $receiptRelative) | ConvertFrom-Json
$repairPlan = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'repairs/repair01/REPAIR_PLAN.json') | ConvertFrom-Json
$checks = [System.Collections.Generic.List[object]]::new()
function Digest([string]$path) {(Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()}
function Assert-Audit([bool]$ok,[string]$name) {
 $checks.Add([ordered]@{name=$name;pass=$ok})
 if(-not $ok) {throw ('Audit failed: '+$name)}
}
function Repo-Relative([string]$path) {[System.IO.Path]::GetRelativePath($repoRoot,[System.IO.Path]::GetFullPath($path)).Replace('\','/')}
function Write-Json([string]$name,$data) {[System.IO.File]::WriteAllText((Join-Path $packageRoot $name),(($data | ConvertTo-Json -Depth 12)+"`n"),[System.Text.UTF8Encoding]::new($false))}
Assert-Audit ((Digest (Join-Path $packageRoot $priorRelative)) -eq '986c6b46fe28e168824d8c47fe3ba771b206b0d0eeaf58d196472faab219d0ba') 'prior immutable receipt'
Assert-Audit ((Digest (Join-Path $packageRoot $receiptRelative)) -eq 'a8368f07e19df1073b8dd3ac5334a6137913ed340fc647004ab5a071e8607afe') 'repair immutable receipt'
Assert-Audit ($prior.status -eq 'FAIL' -and $receipt.status -eq 'PASS') 'historical failure retained with repair PASS'
Assert-Audit ($prior.preparation_attempts -eq 4 -and $prior.preparation_completed_calls -eq 4 -and $receipt.oracle_imports -eq 0 -and $receipt.preparation_attempts -eq 0) 'four initial preparations; no repair oracle/preparation'
$differences = @()
$currentSources = [ordered]@{}
$sourceArchive = [ordered]@{}
$sourceMapping = [System.Collections.Generic.List[object]]::new()
$priorArchive = [ordered]@{}
foreach($property in $prior.source_sha256.PSObject.Properties) {
 $path = Join-Path $packageRoot $property.Name
 $archive = Join-Path $priorHome ('sources/'+$property.Name.Replace('../','parent/'))
 Assert-Audit ((Digest $archive) -eq $property.Value) ('prior archive '+$property.Name)
 $priorArchive[(Repo-Relative $archive)] = $property.Value
 if((Digest $path) -ne $property.Value) {$differences += $property.Name}
}
Assert-Audit ($differences.Count -eq 1 -and $differences[0] -eq 'example/files.f') 'only original-current exception is example/files.f'
foreach($property in $receipt.source_sha256.PSObject.Properties) {
 $path = Join-Path $packageRoot $property.Name
 $archive = Join-Path $receiptHome ('sources/'+$property.Name.Replace('../','parent/'))
 Assert-Audit ((Digest $path) -eq $property.Value) ('current source '+$property.Name)
 Assert-Audit ((Digest $archive) -eq $property.Value) ('repair archive '+$property.Name)
 $currentSources[(Repo-Relative $path)] = $property.Value
 $sourceArchive[(Repo-Relative $archive)] = $property.Value
 $sourceMapping.Add([ordered]@{current=(Repo-Relative $path);archive=(Repo-Relative $archive);sha256=$property.Value;relation='BYTE_IDENTICAL'})
}
foreach($pair in @(@{seal='PRECHECK_SEAL.json';home=$priorHome},@{seal='repairs/repair01/REPAIR_SEAL.json';home=$receiptHome})) {
 $seal = Get-Content -Raw -LiteralPath (Join-Path $pair.home ('sources/'+$pair.seal)) | ConvertFrom-Json
 foreach($property in $seal.sha256.PSObject.Properties) {
  Assert-Audit ((Digest (Join-Path $pair.home ('sources/'+$property.Name.Replace('../','parent/')))) -eq $property.Value) ('archived seal '+$pair.seal+' '+$property.Name)
 }
}
$vectors = [ordered]@{}
for($i=0;$i -lt 4;$i++) {
 $path = Join-Path $priorHome ('vectors'+$i+'.txt')
 $expected = $prior.profiles[$i].vectors_sha256
 Assert-Audit ((Digest $path) -eq $expected) ('vector '+$i)
 Assert-Audit ($receipt.reused_vectors.('reports/20261106T063315_715768Z/vectors'+$i+'.txt') -eq $expected) ('reused vector '+$i)
 $vectors[(Repo-Relative $path)] = $expected
}
$raw = [ordered]@{}
foreach($pair in @(@{record=$prior;home=$priorHome},@{record=$receipt;home=$receiptHome})) {
 foreach($child in $pair.record.checks) {
  Assert-Audit ($child.timeout_seconds -eq 20 -and $child.cleanup.Count -eq 0) ('20s/no timeout cleanup '+$child.name+' '+$pair.record.utc)
  Assert-Audit ($child.cwd -eq $packageRoot) ('cwd '+$child.name+' '+$pair.record.utc)
  foreach($channel in @('stdout','stderr')) {
   $path = Join-Path $pair.home ($child.name+'.'+$channel+'.txt')
   $expected = $child.($channel+'_sha256')
   Assert-Audit ((Digest $path) -eq $expected) ('raw '+$child.name+' '+$channel+' '+$pair.record.utc)
   $raw[(Repo-Relative $path)] = $expected
  }
 }
}
Assert-Audit ($raw.Count -eq 22) '22 raw streams'
Assert-Audit (($prior.checks.name -join ',') -eq 'syntax_default,syntax_example' -and $prior.checks[0].status -eq 'PASS' -and $prior.checks[1].status -eq 'FAIL') 'prior strict fail-stop sequence'
for($i=0;$i -lt $receipt.checks.Count;$i++) {
 $child=$receipt.checks[$i];$planned=$repairPlan.checks[$i]
 $expectedArgv=@($planned.argv | ForEach-Object {$_.Replace('<stamp>',$receipt.utc)})
 Assert-Audit (($child.argv -join "`n") -eq ($expectedArgv -join "`n") -and $child.name -eq $planned.name -and $child.status -eq 'PASS') ('repair argv/status/order '+$i)
 if($planned.marker) {
  Assert-Audit ($child.marker -eq $planned.marker) ('marker '+$child.name)
  foreach($property in $planned.expected_counters.PSObject.Properties) {Assert-Audit ($child.observed.($property.Name) -eq $property.Value) ('coverage '+$child.name+' '+$property.Name)}
  $stdout=[System.IO.File]::ReadAllText((Join-Path $receiptHome ($child.name+'.stdout.txt')))
  Assert-Audit (($stdout.Split("`n") | Where-Object {$_.StartsWith($planned.marker)}).Count -eq 1 -and $stdout.Contains('$finish')) ('unique completion '+$child.name)
 }
}
Assert-Audit ($receipt.checks.Count -eq 9 -and $receipt.suite_complete -and $receipt.archive_complete) 'complete nine-child repair'
$failure=$prior.checks[1]
Assert-Audit ($failure.argv -contains '-tnull' -and -not ($failure.argv -contains '-o')) 'failed child syntax-only no image output'
$failedArgv=@('D:\anscore\tools\oss-cad-suite\oss-cad-suite\bin\iverilog.exe','-g2012','-Wall','-tnull','-s','trigger_pulse256','-f','example/files.f')
Assert-Audit (($failure.argv -join "`n") -eq ($failedArgv -join "`n")) 'original failing argv'
$tools=[ordered]@{}
foreach($property in $receipt.tools.PSObject.Properties) {Assert-Audit ((Digest $property.Name) -eq $property.Value -and $prior.tools.($property.Name) -eq $property.Value) ('tool '+$property.Name);$tools[$property.Name]=$property.Value}
$images=[ordered]@{}
foreach($artifact in $receipt.artifacts) {
 $path=Join-Path $packageRoot $artifact.path
 Assert-Audit ((Digest $path) -eq $artifact.sha256 -and (Get-Item -LiteralPath $path).Length -eq $artifact.bytes) ('image '+$artifact.path)
 $images[(Repo-Relative $path)]=$artifact.sha256
}
Assert-Audit ($images.Count -eq 4) 'four successful images retained'
$dependencies=[ordered]@{}
foreach($path in @('cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv','cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v','cores/system/stream_bus_library/rtl/sys_trigger_window.v')) {
 $baseline=git -C $repoRoot rev-parse ('a68ca46815777c15c638c42a03899c83385bf052:'+$path)
 $actual=git -C $repoRoot hash-object --no-filters $path
 Assert-Audit ($baseline -eq $actual) ('immutable raw dependency '+$path)
 $dependencies[$path]=[ordered]@{baseline_blob=$baseline;current_raw_blob=$actual;sha256=(Digest (Join-Path $repoRoot $path));unchanged=$true}
}
$totals=[ordered]@{records=0;commands=0;samples=0;resets=0;faults=0;held_cycles=0;ii_checks=0}
$profiles=@()
foreach($child in $receipt.checks) {if($child.observed) {$profiles+= $child.observed;foreach($key in @($totals.Keys)) {$totals[$key]+=$child.observed.$key}}}
$failureArchive=[ordered]@{schema='anscore-b40-pulse-fraction-timing-failure-archive-v1';kind='NO_IMAGE_SYNTAX_CHILD_FAILURE';receipt=($packageRelative+'/'+$priorRelative);receipt_sha256=(Digest (Join-Path $packageRoot $priorRelative));failed_child=$failure;image=$null;reason='Icarus -tnull syntax child had no -o argument; recursive example/files.f failed before any image compilation. No failed VVP exists or is fabricated.';source_archive=$priorArchive;vectors=$vectors;raw_streams=[ordered]@{stdout=($packageRelative+'/reports/20261106T063315_715768Z/syntax_example.stdout.txt');stderr=($packageRelative+'/reports/20261106T063315_715768Z/syntax_example.stderr.txt')};current_source_exceptions=@('example/files.f');automatic_retry=$false}
Write-Json 'FAILURE_ARCHIVE.json' $failureArchive
$qualification=[ordered]@{schema='anscore-b40-pulse-fraction-timing-independent-audit-v1';status='PASS';method='Independent PowerShell byte/hash/argv/cwd/marker/count audit; no oracle/HDL/model execution';audit_script_sha256=(Digest $PSCommandPath);audit_assertions=$checks.Count;assertions=$checks.ToArray();prior_receipt_sha256=(Digest (Join-Path $packageRoot $priorRelative));repair_receipt_sha256=(Digest (Join-Path $packageRoot $receiptRelative));prior_archived_inputs=16;current_inputs=19;current_archived_inputs=19;vectors=4;raw_streams=22;tools=2;successful_images=4;historical_passed_children=10;historical_failed_children=1;successful_simulations=4;failure_kind='NO_IMAGE_SYNTAX_CHILD_FAILURE';only_prior_current_source_exception='example/files.f';model_preparations=4;repair_model_preparations=0;totals=$totals;profiles=$profiles;legacy_dependencies=$dependencies;hardware='HW_UNVERIFIED'}
Write-Json 'QUALIFICATION.json' $qualification
$delivery=[ordered]@{schema='anscore-b40-worker-b-pulse-fraction-timing-delivery-v1';package_root=$packageRelative;name='pulse_fraction_timing';top='pulse_fraction_timing';example_top='trigger_pulse256';baseline='a68ca46815777c15c638c42a03899c83385bf052';new_capability='Exact relative-height nearest-lobe left/right interpolated timing and width from sampled pulses, with actual pre/post-trigger capture composition';status=@('LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED');maturity=@('LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED');receipt=($packageRelative+'/'+$receiptRelative);receipt_sha256=(Digest (Join-Path $packageRoot $receiptRelative));plan=($packageRelative+'/repairs/repair01/REPAIR_PLAN.json');plan_sha256=(Digest (Join-Path $packageRoot 'repairs/repair01/REPAIR_PLAN.json'));seal_sha256=(Digest (Join-Path $packageRoot 'repairs/repair01/REPAIR_SEAL.json'));qualification=($packageRelative+'/QUALIFICATION.json');qualification_sha256=(Digest (Join-Path $packageRoot 'QUALIFICATION.json'));failure_archive=($packageRelative+'/FAILURE_ARCHIVE.json');failure_archive_sha256=(Digest (Join-Path $packageRoot 'FAILURE_ARCHIVE.json'));prior_evidence=[ordered]@{receipt=($packageRelative+'/'+$priorRelative);receipt_sha256=(Digest (Join-Path $packageRoot $priorRelative));plan=($packageRelative+'/PRECHECK_PLAN.json');plan_sha256=(Digest (Join-Path $packageRoot 'PRECHECK_PLAN.json'));passed_children=1;failed_children=1;successful_simulations=0;current_source_exceptions=@('example/files.f');failure_kind='NO_IMAGE_SYNTAX_CHILD_FAILURE'};effective_finite_checks=10;successful_simulations=4;historical_hdl_children=11;historical_passed_children=10;historical_hdl_failures=1;repair_passed_children=9;automatic_retry=$false;numerical_preparation_calls=4;repair_numerical_preparation_calls=0;current_executable_sources=$currentSources;source_archive=$sourceArchive;source_mapping=$sourceMapping.ToArray();numerical_vectors=$vectors;raw_streams=$raw;tools=$tools;successful_vvp_images=$images;failed_vvps_to_retain=@();failure_kind='NO_IMAGE_SYNTAX_CHILD_FAILURE';legacy_dependencies=$dependencies;counts=$totals;profiles=$profiles;source_entrypoints=@('rtl/pulse_fraction_timing.sv','example/trigger_pulse256.sv','files.f','example/files.f');authoritative_status='STATUS.md';precheck_documents_frozen=$true;synthesis='NOT_RUN';pnr='NOT_RUN';sta='NOT_RUN';board='NOT_RUN';hardware='HW_UNVERIFIED';worker_git_mutations='No staging, commit or cleanup'}
Write-Json 'B40_DELIVERY.json' $delivery
Write-Output ([pscustomobject]@{assertions=$checks.Count;status='PASS';qualification_sha256=(Digest (Join-Path $packageRoot 'QUALIFICATION.json'));delivery_sha256=(Digest (Join-Path $packageRoot 'B40_DELIVERY.json'));totals=$totals} | ConvertTo-Json -Depth 3 -Compress)
