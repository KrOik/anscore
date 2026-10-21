$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root = [string]$env:SIPEED_TANG20K_ROOT
$project = Join-Path $root 'cores\acquisition\ads131m08'
$sim = Join-Path $project 'sim'
$rtl = (Join-Path $project 'rtl\ads131m08_sample_fifo.v').Replace('\', '/')
$tb = (Join-Path $sim 'tb_ads131m08_fifo.v').Replace('\', '/')
$vvp = (Join-Path $sim 'tb_fifo.vvp').Replace('\', '/')
iverilog -g2012 -o $vvp -s tb_ads131m08_fifo $rtl $tb
if ($LASTEXITCODE -ne 0) { throw 'FIFO boundary compile failed' }
vvp $vvp
if ($LASTEXITCODE -ne 0) { throw 'FIFO boundary simulation failed' }
Write-Host 'ADS131M08 FIFO BOUNDARY PASS'
