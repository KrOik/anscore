$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root = [string]$env:SIPEED_TANG20K_ROOT
$project = Join-Path $root 'cores\acquisition\ads131m08'
$rtl = Join-Path $project 'rtl'
$sources = Get-ChildItem $rtl -Filter '*.v' | Sort-Object Name | ForEach-Object { $_.FullName.Replace('\', '/') }
$sources += (Join-Path $project 'src\ads131m08_pads_top.v').Replace('\', '/')
$sources += (Join-Path $project 'src\ads131m08_pads_top_20k.v').Replace('\', '/')

Write-Host '=== iverilog lint: standalone IP ==='
iverilog -g2012 -tnull -s ads131m08_multi_ip @sources
if ($LASTEXITCODE -ne 0) { throw 'ADS131M08 standalone IP lint failed' }
Write-Host '=== iverilog lint: 20K wrapper ==='
iverilog -g2012 -tnull -s ads131m08_pads_top_20k @sources
if ($LASTEXITCODE -ne 0) { throw 'ADS131M08 20K wrapper lint failed' }
Write-Host 'ADS131M08 LINT PASS'
