$ErrorActionPreference = 'Stop'
# ============================================================================
# program_wave2_ip.ps1 -- program a wave2 group bitstream and capture UART.
#   -Group <0..4>    8-unit group (G0=U0..7 ... G4=U32..39)
#   -Seconds <n>     UART capture length (default 8)
# Output capture: cores/system/extended_library/doc/board_uart_g<N>.txt
# ============================================================================
param(
    [Parameter(Mandatory=$true)][int]$Group,
    [double]$Seconds = 8,
    [int]$Interface = 2,
    [int]$Baud = 115200
)

. (Join-Path $PSScriptRoot 'env.ps1')

$masks = @('00000000FF','000000FF00','0000FF0000','00FF000000','FF00000000')
if ($Group -lt 0 -or $Group -gt 4) { throw 'Group must be 0..4' }
$mask = $masks[$Group]
$proj = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\system\extended_library'
$fs   = Join-Path $proj ("build_oss\wave2_m{0}.fs" -f $mask)
if (!(Test-Path $fs)) { throw "Bitstream not found: $fs -- build with -Mask $mask first" }

Write-Host "Programming Tang Primer 20K: group $Group (UNIT_EN=$mask)"
openFPGALoader -b tangprimer20k $fs
if ($LASTEXITCODE -ne 0) { throw 'openFPGALoader failed' }

$cap = Join-Path $proj ("doc\board_uart_g{0}.txt" -f $Group)
Write-Host "Capturing UART ($Seconds s, iface $Interface, $Baud baud) -> $cap"
python (Join-Path $env:SIPEED_TANG20K_ROOT 'host\ftdi_raw_uart_read.py') `
    --interface $Interface --baud $Baud --seconds $Seconds |
    Tee-Object $cap
