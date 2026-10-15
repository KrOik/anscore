$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\crypto\rsa_udp'
$sim = Join-Path $project 'sim'
New-Item -ItemType Directory -Force -Path $sim | Out-Null

iverilog -g2012 `
    -o (Join-Path $sim 'tb_rsa_modexp.vvp') `
    (Join-Path $project 'src\rsa_modmul.v') `
    (Join-Path $project 'src\rsa_modexp.v') `
    (Join-Path $project 'sim\tb_rsa_modexp.v')
if ($LASTEXITCODE -ne 0) { throw "iverilog tb_rsa_modexp failed" }
vvp (Join-Path $sim 'tb_rsa_modexp.vvp')
if ($LASTEXITCODE -ne 0) { throw "vvp tb_rsa_modexp failed" }

iverilog -g2012 `
    -o (Join-Path $sim 'tb_rsa_udp_service.vvp') `
    (Join-Path $project 'src\rsa_modmul.v') `
    (Join-Path $project 'src\rsa_modexp.v') `
    (Join-Path $project 'src\rsa_udp_service.sv') `
    (Join-Path $project 'sim\tb_rsa_udp_service.sv')
if ($LASTEXITCODE -ne 0) { throw "iverilog tb_rsa_udp_service failed" }
vvp (Join-Path $sim 'tb_rsa_udp_service.vvp')
if ($LASTEXITCODE -ne 0) { throw "vvp tb_rsa_udp_service failed" }
