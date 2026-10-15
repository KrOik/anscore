$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$projectDir = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acquisition\micarray_doa'

if (!(Get-Command gw_sh -ErrorAction SilentlyContinue)) {
    throw 'gw_sh not found. Install Gowin EDA and add its bin directory to PATH.'
}

Push-Location $projectDir
try {
    gw_sh run.tcl
} finally {
    Pop-Location
}

