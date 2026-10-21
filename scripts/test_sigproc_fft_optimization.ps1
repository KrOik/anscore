param([Parameter(Mandatory=$true)][string]$OutputDir)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root=$env:SIPEED_TANG20K_ROOT
$project=Join-Path $root 'cores/signal_processing/transforms'
& $env:OSS_CAD_PYTHON "$project/tools/gen_fft_stress_vectors.py" --output $OutputDir
if($LASTEXITCODE -ne 0) {throw 'Vector generation failed'}
$out=(Resolve-Path $OutputDir).Path
$baseline=Join-Path $root 'artifacts/ip_optimization_20260924/fft64/baseline_fft64.v'
$text=[IO.File]::ReadAllText($baseline).Replace('module fft64 #(', 'module fft64_baseline #(')
[IO.File]::WriteAllText("$out/fft64_baseline.v",$text)
$sources=@("$project/sim/tb_fft64_stress.v","$project/src/fft64.v",
 "$out/fft64_baseline.v","$project/src/sig_sdp_ram.v",
 "$project/src/tw_rom_cos.v","$project/src/tw_rom_sin.v")
& iverilog -g2012 -s tb_fft64_stress -o "$out/test.vvp" @sources
if($LASTEXITCODE -ne 0) {throw 'Compilation failed'}
Push-Location $out
try {
 & vvp test.vvp | Tee-Object stress.log
 if($LASTEXITCODE -ne 0) {throw 'FFT stress failed'}
 if(-not (Select-String -Path stress.log -Pattern '^PASS FFT64 vectors=128')) {throw 'Missing PASS'}
 & iverilog -g2012 -s tb_fft64_rate_board -o board.vvp "$project/sim/tb_fft64_rate_board.v" "$project/src/fft64_rate_board.v" "$project/src/uart_tx.v" @($sources[1],$sources[3],$sources[4],$sources[5])
 if($LASTEXITCODE -ne 0) {throw 'Board bench compilation failed'}
 & vvp board.vvp | Tee-Object board.log
 if($LASTEXITCODE -ne 0 -or -not (Select-String board.log -Pattern '^PASS FFT27')) {throw 'Board bench failed'}
 New-Item -ItemType Directory sim | Out-Null
 Copy-Item "$project/sim/*.mem" sim
 Copy-Item "$project/*.mem" .
 $allSources=@('fft64','sig_sdp_ram','tw_rom_cos','tw_rom_sin','cic_dec8','hist256','otsu_thresh','sig_selftest','uart_tx','top' | ForEach-Object {"$project/src/$_.v"})
 foreach($bench in @('tb_sig_selftest','tb_top_uart_report')) {
  & iverilog -g2012 -s $bench -o "$bench.vvp" "$project/sim/$bench.v" "$project/sim/gowin_bsram_sim.v" @allSources
  if($LASTEXITCODE -ne 0) {throw "$bench compile failed"}
  & vvp "$bench.vvp" | Tee-Object "$bench.log"
  if($LASTEXITCODE -ne 0 -or (Select-String "$bench.log" -Pattern '\bFAIL\b|TIMEOUT|ERROR:') -or -not (Select-String "$bench.log" -Pattern 'PASS')) {throw "$bench failed"}
 }
} finally {Pop-Location}
