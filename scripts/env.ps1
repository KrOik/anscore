$ErrorActionPreference = 'Stop'

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$OssCadRoot = Join-Path $ProjectRoot 'tools\oss-cad-suite\oss-cad-suite'

if (Test-Path $OssCadRoot) {
    $env:PATH = "$(Join-Path $OssCadRoot 'bin');$(Join-Path $OssCadRoot 'lib');$env:PATH"
    $env:OSS_CAD_PYTHON = Join-Path $OssCadRoot 'lib\python3.exe'
}

$env:SIPEED_TANG20K_ROOT = $ProjectRoot

Write-Host "SIPEED_TANG20K_ROOT=$env:SIPEED_TANG20K_ROOT"
if (Test-Path $OssCadRoot) {
    Write-Host "OSS CAD Suite=$OssCadRoot"
} else {
    Write-Warning "OSS CAD Suite not found at $OssCadRoot"
}
