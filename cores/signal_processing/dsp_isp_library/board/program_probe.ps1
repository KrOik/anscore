param([Parameter(Mandatory=$true)][string]$Image)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../../scripts/env.ps1"
& openFPGALoader -b tangprimer20k --freq 1000000 --detect
if($LASTEXITCODE -ne 0){throw 'JTAG detection failed'}
& openFPGALoader -b tangprimer20k --freq 1000000 $Image
if($LASTEXITCODE -ne 0){throw 'SRAM programming failed'}
