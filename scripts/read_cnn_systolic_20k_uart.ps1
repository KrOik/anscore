param(
    [int]$Interface = 2,
    [int]$Baud = 115200,
    [double]$Seconds = 5
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$scriptPath = Join-Path $env:SIPEED_TANG20K_ROOT 'host\ftdi_raw_uart_read.py'
python $scriptPath --interface $Interface --baud $Baud --seconds $Seconds
