param([Parameter(Mandatory=$true)][string]$OutputDir)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../../scripts/env.ps1"
if(Test-Path -LiteralPath $OutputDir){throw 'Use a fresh output directory'}
$out=(New-Item -ItemType Directory $OutputDir).FullName
$src=@("$PSScriptRoot/uart_injection_probe.v","$env:SIPEED_TANG20K_ROOT/cores/communication/primitives/src/uart_rx.v","$env:SIPEED_TANG20K_ROOT/cores/communication/primitives/src/uart_tx.v")
foreach($f in $src){Copy-Item $f $out}
Copy-Item "$PSScriptRoot/uart_injection_probe.cst" $out
Get-FileHash $src | ConvertTo-Json | Set-Content "$out/source_hashes.json"
Push-Location $out
try {
 & iverilog -g2012 -s tb_uart_injection_probe -o sim.vvp "$PSScriptRoot/tb_uart_injection_probe.sv" uart_injection_probe.v uart_rx.v uart_tx.v 2>&1 | Set-Content compile.log
 if($LASTEXITCODE -ne 0){throw 'Probe compile failed'}
 & vvp sim.vvp 2>&1 | Tee-Object simulation.log
 if($LASTEXITCODE -ne 0){throw 'Probe simulation failed'}
 'read_verilog -sv uart_injection_probe.v uart_rx.v uart_tx.v','synth_gowin -noalu -family gw2a -top uart_injection_probe -json top.json','stat' | Set-Content build.ys
 & yosys -Q -l yosys.log build.ys > synth_console.log 2>&1
 if($LASTEXITCODE -ne 0){throw 'Synthesis failed'}
 $net=Get-Content top.json -Raw | ConvertFrom-Json -AsHashtable
 $types=@($net.modules.uart_injection_probe.cells.Values | ForEach-Object {$_.type})
 $lut=@($types | Where-Object {$_ -match '^LUT[1-4]$|^ALU$'}).Count
 $dsp=@($types | Where-Object {$_ -match '^(MULT|PADD|ALU54)'}).Count
 if($lut -gt 15000 -or $dsp -gt 4){throw 'Synthesis budget failed'}
 & nextpnr-himbaechel --json top.json --write pnr.json --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt cst=uart_injection_probe.cst --freq 27 --seed 1 --log nextpnr.log > pnr_console.log 2>&1
 if($LASTEXITCODE -ne 0){throw 'P&R failed'}
 $pnr=Get-Content nextpnr.log -Raw
 $match=[regex]::Match($pnr,'\bLUT4:\s+(\d+)')
 if(!$match.Success -or [int]$match.Groups[1].Value -gt 15000){throw 'Routed LUT gate failed'}
 & $env:OSS_CAD_PYTHON "$env:SIPEED_TANG20K_ROOT/tools/oss-cad-suite/oss-cad-suite/bin/gowin_pack-script.py" -d GW2A-18 -o probe.fs pnr.json > pack.log 2>&1
 if($LASTEXITCODE -ne 0){throw 'Pack failed'}
 @{synthesis_LUT=$lut;DSP=$dsp;routed_LUT4=[int]$match.Groups[1].Value;target_MHz=27} | ConvertTo-Json | Set-Content resources.json
 Write-Host "PASS UART probe build LUT=$lut DSP=$dsp"
} finally {Pop-Location}
